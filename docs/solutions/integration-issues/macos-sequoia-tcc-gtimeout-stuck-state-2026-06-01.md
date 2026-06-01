---
module: scheduler
date: 2026-06-01
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "macOS TCC App Management prompt for `gtimeout` fires every 15-minute scheduler cycle"
  - "User clicks Allow on the prompt; the next cycle re-prompts anyway"
  - "TCC.db `access` row for the binary reads `auth_value=5` instead of the expected `2`"
  - "Surgical row deletion plus `tccd` restart fixes it for 1-3 days, then the bug recurs"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - background_job
tags:
  - macos
  - sequoia
  - tcc
  - app-management
  - gtimeout
  - homebrew
  - scheduler
  - audit-chain
---

# macOS Sequoia TCC `auth_value=5` stuck-state for adhoc-signed Homebrew CLI binaries

## Problem

A `launchd`-driven scheduler invoked `gtimeout` (from Homebrew's `coreutils`) every 15 minutes to wrap a long-running `claude` command with a watchdog. Each cycle, macOS displayed an "App Management" consent prompt for `gtimeout` ("would like to access data from other apps"). Clicking **Allow** did not stop the prompt — the next cycle re-prompted, and so on, indefinitely.

Inspection of `~/Library/Application Support/com.apple.TCC/TCC.db` showed the offending row at `auth_value=5` (a Sequoia-specific "needs re-verification" placeholder) instead of the expected `auth_value=2` (allowed). Three unrelated apps on the same machine — 1Password, Microsoft AutoUpdate helper, Terminal.app — had the same `auth_value=5` state on the same TCC service (`kTCCServiceSystemPolicyAppData`), confirming this is a pattern that affects multiple binary classes that macOS doesn't fully categorize as "App Management subjects." `gtimeout`'s 15-minute invocation cadence is what made it user-visible — the other three didn't loop because their binaries don't run on a tight recurring schedule.

## Root cause

`kTCCServiceSystemPolicyAppData` (the TCC service backing the "App Management" capability in macOS Sequoia) expects subjects that are properly app-bundled and/or notarized. `gtimeout` is none of those:

- It's a CLI tool, not an `.app` bundle.
- Homebrew's `coreutils` bottle is **adhoc-signed** (`codesign -dvv` shows `Signature=adhoc`, `TeamIdentifier=not set`) — no Apple Developer ID, no notarization.
- macOS Sequoia's consent-storage path for App Management appears to write a placeholder (`auth_value=5`) when persisting consent for these non-bundled / non-notarized subjects, instead of the proper `auth_value=2`. Subsequent access checks read the placeholder as "not yet trusted" → re-prompt → user clicks Allow → placeholder rewritten → loop.

Surgical fixes (delete the row + restart `tccd`) do not hold because the underlying macOS storage bug rewrites the bad value the next time the user clicks Allow. The only durable fix is to remove the affected binary class from the TCC audit chain entirely.

## Investigation steps that did not work

- **Delete the stuck row + restart `tccd`.** Worked for 1-3 days; the loop returned on the next macOS-issued prompt because the underlying storage bug rewrites `auth_value=5` again on the next Allow click.
- **`launchctl kill SIGTERM gui/$UID/com.apple.tccd`.** Returned `Not privileged to signal service` — `tccd` is SIP-protected. `sudo killall tccd` works as a substitute.
- **Bash-only watchdog using `sleep` + `kill` for the timeout.** Failed for a different reason: bash command substitution `output=$(cmd)` blocks until **all** descendants of `cmd` close the captured stdout pipe. SIGTERM/SIGKILL on the immediate child orphans the grandchildren (the actual `sleep` that's eating time), and the orphans keep the pipe open. `$(...)` never returns. Verified by experiment: a 2-second-timeout against `bash -c 'sleep 20'` ran the full 20 seconds.
- **Perl `alarm() + exec`.** Failed because the target of `exec` was often `bash`, which ignores `SIGALRM` in non-interactive mode — the alarm fires but has no effect.

## Solution

Remove the adhoc-signed Homebrew CLI binary (`gtimeout`) from the TCC audit chain. Replace with `/usr/bin/python3` (Apple-signed, ships with Xcode Command Line Tools) using `subprocess.Popen(start_new_session=True)` + `os.killpg` on `TimeoutExpired`. The new-session flag puts the child in its own process group, and `killpg` kills the entire group on timeout — so grandchildren die too, no pipe-blocking, no orphans.

```bash
# In scripts/scheduler.sh — replaces the prior `if command -v gtimeout` block
run_with_watchdog() {
    local timeout=$1
    shift
    /usr/bin/python3 - "$timeout" "$@" <<'PYEOF'
import subprocess, signal, sys, os
timeout = int(sys.argv[1])
cmd = sys.argv[2:]
p = subprocess.Popen(cmd, start_new_session=True)
try:
    rc = p.wait(timeout=timeout)
    sys.exit(rc)
except subprocess.TimeoutExpired:
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
    except ProcessLookupError:
        pass
    sys.exit(124)
PYEOF
}

# Call site (was: `"$TIMEOUT_CMD" "$CLAUDE_TIMEOUT_SECONDS" claude ...`)
output=$(run_with_watchdog "$CLAUDE_TIMEOUT_SECONDS" "$CLAUDE" -p --dangerously-skip-permissions "$prompt" 2>&1)
```

`/usr/bin/python3` is Apple-signed (`codesign -dvv` shows `Identifier=com.apple.dt.xcode_select.tool-shim-public`). When TCC walks the audit chain for a scheduler-launched `claude` invocation now, it finds `python3` (system binary) and `claude` (which has its own stable TCC rows at `auth_value=2`). No adhoc-signed Homebrew binary in the chain → no Sequoia stuck-state bug.

Trade-off: `gtimeout` had awake-time semantics (pauses during macOS sleep); the Python `wait(timeout=...)` uses wall-clock time. For a scheduler with a 15-minute cadence and a 20-minute ceiling, the laptop-sleeps-mid-cycle case is rare and bounded by the existing scheduler lockfile, which cleans up any cycle that gets killed mid-flight.

One-time cleanup after deploying the code change:

```bash
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "DELETE FROM access WHERE client LIKE '%gtimeout%' AND auth_value = 5;"

sudo killall tccd
```

After this the stuck row is gone, the new scheduler never invokes `gtimeout` again, and the row never gets re-touched. The next scheduler cycle uses `python3`, which may prompt once for `kTCCServiceSystemPolicyAppData` (because `python3` is Apple-signed it persists at `auth_value=2` cleanly) and then stay quiet — matching the Sequoia ~30-day renewable-consent cycle for normal binaries.

## Prevention

For any tool that runs on a recurring schedule (`launchd`, `cron`, `systemd` user units) and needs to wrap user-data-accessing commands with a watchdog, timeout, or other shell glue: **prefer Apple-signed system binaries (`/usr/bin/python3`, `/usr/bin/perl`, `bash` builtins) over Homebrew-installed CLI tools in the audit chain.** The Homebrew binaries themselves are fine when invoked manually from Terminal (which inherits the user's TCC grants), but become the TCC audit-chain subject when their parent is `launchd` rather than an interactive shell — and Sequoia's consent storage doesn't handle that subject cleanly. Symptom that should trigger this pattern: a binary's TCC row sitting at `auth_value=5` after the user has clicked Allow.

The same applies to other adhoc-signed binaries (Microsoft's privileged helpers, custom CLI tools without Developer ID, etc.) for any TCC service — not just App Management. If the binary doesn't have a proper code-signing chain and Sequoia's storage layer doesn't fully recognize it as a TCC subject, expect the same stuck-state behavior.

Verification approach when shipping such a fix: run a synthetic timeout test against a tree of grandchild processes (e.g., `bash -c 'bash -c "sleep 20" & wait'`) to confirm the entire tree dies at the deadline, not just the immediate child. Bash-only watchdogs commonly fail this test even though they look correct on a single-process target.
