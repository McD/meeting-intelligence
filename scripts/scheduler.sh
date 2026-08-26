#!/bin/bash
# Runs every 15 minutes via launchd.
# version: 2026-08-25 — notify_macos() added as a second surface alongside notify_slack(). Every notify_slack call now fires a macOS Notification Center alert before the SLACK_WEBHOOK guard, so failures are visible even while Slack is disabled (guest account, ~/.slack_webhook.disabled). notify_slack_once gains a two-part streak escalation: the 3rd suppressed call inside the 4h dedup window fires ONE bonus re-notify per window (gated by .notify_escalated_${key}), and every real fire (Path 4 or escalation) increments a cumulative .notify_count_${key} so the "[repeat ×N]" prefix conveys outage duration rather than always reading "×3". Escalation must NOT refresh the dedup marker — the original attempt at this feature did, which reintroduced the 2026-06-15 flood shape (~32 pings/day under a sustained outage); the adversarial review caught it before commit. Addresses the 2026-08-19 → 08-25 outage where 342 consecutive "OAuth session expired" cycles fired silently against a disabled Slack surface — 6 days of no briefings/follow-ups that Mark only noticed when a specific follow-up (Carl McD 1:1) didn't land. State stored per-key in .notify_dedup_/.notify_streak_/.notify_escalated_/.notify_count_${key}; all four cleared together on successful cycle, gws-oauth recovery, and venv recovery (with the same venv-broken/auto-expiry-failed exclusion the pre-existing dedup logic used). Previous: 2026-06-26 — run_with_watchdog now distinguishes host-sleep-induced deadline expiry from real stalls. Each poll iteration measures (actual wall duration) vs (wait_budget); excesses beyond a 30s jitter allowance are attributed to host sleep. On deadline expiry, if >50% of the timeout was sleep, exit 125 (skip, no Slack) instead of 124 (real timeout, Slack ping). Also raised CLAUDE_TIMEOUT_SECONDS 600→900 since legitimate briefing+follow-up cycles routinely landed 420-600s against the prior cap. Together these address the 30-timeouts-in-40h flood the user surfaced on 2026-06-26: the overnight cluster (06-25 19:19 → 06-26 08:50, 13 consecutive) was the laptop sleeping, and the daytime ones had no headroom. Previous: 2026-06-12 — run_with_watchdog now uses a wall-clock deadline (time.time(), aka gettimeofday) instead of a single subprocess.wait(timeout=...) call. The 2026-06-01 version claimed wall-clock semantics but the implementation relied on Python's monotonic clock, which on macOS is mach_absolute_time() and pauses during system sleep — a 1200s budget could outlast the laptop sleeping for hours. On 2026-06-12 a 06:12 cycle ran 2h53m before being killed manually; subsequent launchd cycles (06:27 onward) were silently skipped because launchd serializes scheduler.sh instances, killing that morning's briefing window. New design polls subprocess.wait() in ≤10s bursts and re-checks the wall-clock deadline each iteration, so a hung child is killed within ~10s of wake. Previous: 2026-06-06 — Tightened run_claude prompt at line 440 from "Run these in sequence" → "Run ONLY these slash commands…then stop". Headless opus-4-7 was reading the original prompt's plural framing as license to also invoke unrequested commands; on 2026-06-06 Saturday at 02:40 BST it finished a Saturday `/follow-up all` (no-op) and volunteered `/digest`, sending the user an off-day actions tracker. The new wording is explicit that only the listed commands run and the turn ends after them. Earlier: 2026-06-01 — Removed gtimeout invocation entirely. Replaced with a bash-native `run_with_watchdog` function using only Apple-signed system binaries (bash builtins + /bin/sleep + /bin/kill). Sidesteps a macOS Sequoia TCC bug where kTCCServiceSystemPolicyAppData consent for adhoc-signed Homebrew CLI binaries (gtimeout) writes auth_value=5 instead of 2 on Allow, causing every 15-min cycle to re-prompt the user. Wall-clock semantics instead of gtimeout's awake-time; the lockfile + 15-min cadence already protect against runaway cycles, so the laptop-sleeps-mid-cycle edge case is bounded. Previous: 2026-05-28d — CLAUDE_TIMEOUT_SECONDS raised from 600 to 1200. Earlier: 2026-05-28b — detects `timeout`/`gtimeout` at script start; install.sh installed coreutils as Step 4 (no longer required). 2026-05-28 — notify_slack curl gets --max-time/--connect-timeout; run_claude wrapped in timeout 600; CLAUDE_VERSION_FILE deferred until after a successful run. Phase 3 — adds NEED_DIGEST gate.

BRIEFING_DIR="$HOME/Briefings"
LOCK_FILE="$BRIEFING_DIR/.scheduler.lock"
GWS_AUTH_FAILED_FILE="$BRIEFING_DIR/.gws_auth_failed"
CLAUDE_VERSION_FILE="$BRIEFING_DIR/.claude_version"
SLACK_WEBHOOK=$(cat ~/.slack_webhook 2>/dev/null)
CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")
GWS=$(command -v gws 2>/dev/null || echo "/opt/homebrew/bin/gws")

# Watchdog: kills the entire process tree after $1 seconds. Implemented as a
# Python one-liner via /usr/bin/python3 (Apple-signed Xcode CLT binary, not a
# Homebrew CLI tool) so nothing in the audit chain is the kind of adhoc-signed
# binary that triggers macOS Sequoia's kTCCServiceSystemPolicyAppData
# stuck-state bug (Allow writes auth_value=5 instead of 2, every cycle
# re-prompts).
#
# Bash-only versions of this with SIGTERM-then-SIGKILL don't work: bash
# command substitution `$(cmd)` blocks until ALL descendants close the captured
# stdout pipe, and killing only the immediate child leaves grandchildren
# (sleep, child shells) orphaned but still holding the pipe open, so $(...)
# hangs. Python's `start_new_session=True` + `os.killpg` kills the entire
# process group cleanly, including grandchildren. Exit code 124 on timeout
# preserves the existing "rc==124 means timeout" convention used below.
#
# Wall-clock semantics — the deadline uses time.time() (gettimeofday), which
# continues advancing during system sleep. A single subprocess.wait(timeout=...)
# call would NOT give wall-clock semantics: Python's wait() uses time.monotonic()
# internally, which on macOS resolves to mach_absolute_time() and pauses during
# sleep. So we poll wait() in ≤10s bursts and re-check the deadline each
# iteration; on wake-up from sleep, the next iteration sees the deadline is past
# and kills the child within ~10s. /usr/bin/python3 is part of macOS Xcode
# Command Line Tools; install.sh's Step 3 (Claude Code) already requires brew
# which requires xcode-select, so python3 is present on every supported install.
run_with_watchdog() {
    local timeout=$1
    shift
    /usr/bin/python3 - "$timeout" "$@" <<'PYEOF'
import subprocess, signal, sys, os, time
timeout = int(sys.argv[1])
cmd = sys.argv[2:]
p = subprocess.Popen(cmd, start_new_session=True)
start_wall = time.time()
deadline = start_wall + timeout

# Sleep accounting. p.wait(timeout=...) uses Python's monotonic clock, which on
# macOS pauses during system sleep. So a 10s wait spans laptop-sleep cleanly,
# but the wall-clock deadline (time.time()) keeps advancing through sleep. If
# the host sleeps for an hour mid-cycle, the next iteration sees the deadline
# is past and kills a child that has only had a few minutes of awake-time —
# which used to fire a :hourglass: Slack alert as if Claude had stalled. We
# now measure the gap between each iteration's requested wait budget and the
# actual wall-clock duration of that wait; large gaps are attributed to host
# sleep. On timeout, if a majority of the budget was sleep, exit 125 instead
# of 124 so the caller can log a skip without notifying Slack.
sleep_jumps = 0.0

def kill_group():
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

while True:
    iter_start = time.time()
    remaining = deadline - iter_start
    if remaining <= 0:
        kill_group()
        sys.exit(125 if sleep_jumps > timeout * 0.5 else 124)
    try:
        wait_budget = min(remaining, 10)
        rc = p.wait(timeout=wait_budget)
        sys.exit(rc)
    except subprocess.TimeoutExpired:
        # 30s jitter allowance covers normal OS scheduling. Anything beyond
        # that on a 10s wait is the laptop sleeping (or a wedged CPU, which
        # we can't distinguish — but the failure mode of misattributing a
        # wedge as sleep is "one fewer Slack ping", not data loss).
        actual = time.time() - iter_start
        if actual > wait_budget + 30:
            sleep_jumps += actual - wait_budget
        continue
PYEOF
}

# Weekly health summary: parse scheduler.log for the last 7 days and Slack-notify.
# Called once per week during the Monday cleanup window (see below).
generate_health_summary() {
    local log="$BRIEFING_DIR/scheduler.log"
    [ -f "$log" ] || return 0
    [ -n "$SLACK_WEBHOOK" ] || return 0

    local summary
    summary=$(/usr/bin/python3 - "$log" <<'PYEOF'
import re, sys
from datetime import datetime, timedelta

log_path = sys.argv[1]
since = datetime.now() - timedelta(days=7)

skipped = ran = done = t_timeout = t_auth = t_perm = t_other = t_escalation = 0

with open(log_path, errors='replace') as f:
    for line in f:
        m = re.match(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\]', line)
        if not m:
            continue
        try:
            ts = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M')
        except ValueError:
            continue
        if ts < since:
            continue
        # Order matters: streak-escalation lines are ERROR-adjacent but must not
        # double-count as t_other. Check escalation before the generic ERROR bucket.
        if 'streak escalation' in line:
            t_escalation += 1
        elif 'skipped Claude' in line:
            skipped += 1
        elif line.rstrip().endswith('Done.'):
            done += 1
        elif 'Running:' in line:
            ran += 1
        elif 'timed out' in line:
            t_timeout += 1
        elif 'auth failure' in line or 'OAuth token' in line:
            t_auth += 1
        elif 'permission prompt' in line:
            t_perm += 1
        elif 'ERROR:' in line:
            t_other += 1

total = skipped + ran
failures = t_timeout + t_auth + t_perm + t_other

lines = [":bar_chart: *Scheduler health (last 7 days)*"]
lines.append(f"  {total} cycles — {skipped} skipped, {ran} ran Claude")
failure_detail = ", ".join(filter(None, [
    f"{t_timeout} timeout" if t_timeout else "",
    f"{t_auth} auth" if t_auth else "",
    f"{t_perm} permission" if t_perm else "",
    f"{t_other} other" if t_other else "",
]))
lines.append(f"  {done} successful, {failures} failed" + (f" ({failure_detail})" if failures else ""))
# Surface streak escalations separately — they are notification events (evidence
# that a real sustained outage is being flagged), not distinct failure cycles.
# Undercounting them in the pre-fix parser was the review's Important #6.
if t_escalation:
    lines.append(f"  {t_escalation} streak escalation(s) fired inside dedup windows")
print("\\n".join(lines))
PYEOF
    )

    [ -n "$summary" ] && notify_slack "$summary"
}

umask 077
mkdir -p "$BRIEFING_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] $1" >> "$BRIEFING_DIR/scheduler.log"; }

# macOS Notification Center surface. Fires alongside every notify_slack call so
# failures remain visible even when Slack is disabled (current state — see the
# note on notify_slack below). No network dependency, no auth dependency — works
# even when both Claude Code and gws OAuth are dead, which is precisely the
# window in which we most need to notify.
#
# CAVEAT (2026-08-25): AppleScript's `display notification` cannot declare a
# `critical` interruption level (only the UNUserNotifications API can), so
# Do Not Disturb / Focus modes silently suppress banners. Notifications are
# still queued in Notification Center and visible when the menu-bar clock is
# clicked — but they will NOT ping while a Focus mode is active. Discovered
# when smoke tests fired with rc=0 but produced no audible/visual banner;
# `Assertions.json` confirmed DND was on. If you rely on push while focused,
# add a phone channel (ntfy.sh) — planned but not shipped.
#
# Errors swallowed: a failed notification must never break a cycle.
notify_macos() {
    local title="$1" body="$2"
    # Collapse newlines to spaces — AppleScript -e string literals must not span lines,
    # and macOS notification banners are single-line anyway. Keeps a future caller with
    # a heredoc body from silently producing no banner.
    body="${body//$'\n'/ }"; body="${body//$'\r'/ }"
    # Escape backslashes then double quotes for AppleScript string literals.
    title="${title//\\/\\\\}"; title="${title//\"/\\\"}"
    body="${body//\\/\\\\}";   body="${body//\"/\\\"}"
    # Capture stderr so a denied notification permission (macOS never granted Script
    # Editor / osascript the Notification-Center entitlement), a missing Aqua session
    # (launchd cycle during logout), or an AppleScript syntax error surfaces in the
    # log instead of being swallowed. stdout still discarded — banners don't reply.
    local err
    err=$(/usr/bin/osascript -e "display notification \"$body\" with title \"$title\"" 2>&1 >/dev/null) || true
    [ -n "$err" ] && log "WARN: notify_macos — ${err//$'\n'/ | }"
}

# NOTE (2026-08-05): Slack delivery is currently disabled — Mark lost workspace
# admin permissions (guest account) and can no longer regenerate an incoming
# webhook. `~/.slack_webhook` has been renamed to `~/.slack_webhook.disabled`,
# which makes this function short-circuit at the [ -n "$SLACK_WEBHOOK" ] check
# below, so every notify path is a clean no-op. Email is now the sole
# notification surface. Code kept intact for the day a webhook is available
# again (guest-permission restoration, or a different endpoint like ntfy /
# Telegram — just rewrite ~/.slack_webhook to the new URL and, if the payload
# shape changes, tweak the curl body below).
notify_slack() {
    notify_macos "Meeting-Intelligence" "$1"
    [ -n "$SLACK_WEBHOOK" ] || return 0
    # --max-time/--connect-timeout: Slack stalls must not hold .scheduler.lock.
    # Delivery is fire-and-forget; nothing downstream depends on the response.
    # Capture HTTP status + body so a dead webhook (invalid_token, no_service)
    # is loud in scheduler.log instead of failing silently — 2026-08-05 auth
    # outage delivered 0 alerts to Slack because the webhook had been revoked
    # since March and the old `-s ... >/dev/null 2>&1` swallowed the 400s.
    local payload http_code body curl_rc
    payload=$(/usr/bin/python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" "$1")
    http_code=$(curl -sS --connect-timeout 5 --max-time 10 \
        -o /tmp/.notify_slack_body.$$ -w '%{http_code}' \
        -X POST "$SLACK_WEBHOOK" \
        -H 'Content-type: application/json' \
        -d "$payload" 2>&1)
    curl_rc=$?
    body=$(cat /tmp/.notify_slack_body.$$ 2>/dev/null); rm -f /tmp/.notify_slack_body.$$
    if [ "$curl_rc" -ne 0 ]; then
        log "WARN: notify_slack curl failed (rc=$curl_rc): $http_code"
    elif [ "$http_code" != "200" ]; then
        log "WARN: notify_slack HTTP $http_code — body: ${body:-<empty>}. Webhook may be revoked; regenerate in Slack app config and rewrite ~/.slack_webhook."
    fi
}

# Cause-class deduped Slack notification. First failure of a kind pings; repeats
# of the same kind within NOTIFY_DEDUP_WINDOW are suppressed (logged only). Markers
# are cleared on a successful claude cycle so the next failure re-pings. Added
# 2026-06-15 after a 48h opus-4-7 LLM-stall window produced ~39 :hourglass: pings.
NOTIFY_DEDUP_WINDOW=14400  # 4h
NOTIFY_STREAK_THRESHOLD=3  # Nth suppressed call inside the window forces at most ONE bonus re-notify per dedup window.
notify_slack_once() {
    local key="$1" msg="$2"
    local marker="$BRIEFING_DIR/.notify_dedup_${key}"
    local streak_file="$BRIEFING_DIR/.notify_streak_${key}"
    local escalated_marker="$BRIEFING_DIR/.notify_escalated_${key}"
    local count_file="$BRIEFING_DIR/.notify_count_${key}"
    local count
    if [ -f "$marker" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$marker") ))
        if [ "$age" -lt "$NOTIFY_DEDUP_WINDOW" ]; then
            local streak=$(( $(cat "$streak_file" 2>/dev/null || echo 0) + 1 ))
            echo "$streak" > "$streak_file"
            # Already escalated inside this 4h window — stay silent until the marker
            # expires and Path 4 (fresh fire) runs. This is the load-bearing guard
            # against the 2026-06-15 flood pattern: escalation must NOT refresh the
            # dedup marker, or the window never elapses and every Nth cycle re-fires
            # forever (~32 pings/day under a sustained outage).
            if [ -f "$escalated_marker" ]; then
                log "Notification suppressed (key=$key, streak=$streak, escalation already fired this window)."
                return 0
            fi
            if [ "$streak" -lt "$NOTIFY_STREAK_THRESHOLD" ]; then
                log "Notification suppressed (key=$key, last fired ${age}s ago, window ${NOTIFY_DEDUP_WINDOW}s, streak=$streak/$NOTIFY_STREAK_THRESHOLD)."
                return 0
            fi
            # Streak escalation: one bonus notification per dedup window. Marks the
            # escalated_marker so subsequent suppressed cycles inside the window
            # short-circuit above; does NOT touch the dedup marker so the 4h window
            # elapses on its original schedule.
            touch "$escalated_marker"
            count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
            echo "$count" > "$count_file"
            log "Notification streak escalation (key=$key, streak=$streak, total=$count) — forcing re-notify inside dedup window."
            notify_slack "[repeat ×${count}] $msg"
            return 0
        fi
        # 4h window has elapsed — this is a fresh Path 4 fire, so clear the
        # per-window escalation marker before touching the new dedup marker.
        rm -f "$escalated_marker"
    fi
    touch "$marker"
    rm -f "$streak_file"
    # count is the CUMULATIVE notify count for the current outage — Path 4 fires
    # and escalations both increment it, and it only clears on success sweep or on
    # explicit recovery. The label lets Mark distinguish a fresh blip from a
    # 6-day catastrophe: "[repeat ×72] :key: ..." reads very differently from
    # ":key: ..." with no prefix.
    count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    echo "$count" > "$count_file"
    if [ "$count" -gt 1 ]; then
        notify_slack "[repeat ×${count}] $msg"
    else
        notify_slack "$msg"
    fi
}

if [ -f "$BRIEFING_DIR/scheduler.log" ] && [ "$(wc -c < "$BRIEFING_DIR/scheduler.log")" -gt 512000 ]; then
    tail -500 "$BRIEFING_DIR/scheduler.log" > "$BRIEFING_DIR/scheduler.log.tmp"
    mv "$BRIEFING_DIR/scheduler.log.tmp" "$BRIEFING_DIR/scheduler.log"
fi

if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
    if [ "$lock_age" -lt 1800 ] && kill -0 "$pid" 2>/dev/null; then
        log "Already running (PID $pid), skipping."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
# Single quotes: $LOCK_FILE expands at trap-firing time, not trap-definition.
trap 'rm -f "$LOCK_FILE"' EXIT

# ── Venv preflight ─────────────────────────────────────────────────────────
# Catch a broken ~/.briefings/venv every cycle (import is ~50ms), not just on
# the weekly branch. Without this, a Homebrew Python upgrade that orphans the
# venv's python3 symlink stays invisible for up to a week until auto-expiry
# fails (silent for 2 weeks in the 2026-07-15 incident before this preflight
# was added). Design notes:
#   * Wrapped in run_with_watchdog 15 so a module-level side-effect in
#     briefings_mcp (sqlite connect against a locked DB, DNS lookup) can't
#     freeze the scheduler indefinitely — 15s is 300x the normal import time.
#   * PREFLIGHT_STDERR uses a PID-scoped file in $BRIEFING_DIR rather than
#     mktemp, so an unwritable TMPDIR can't false-alarm the check itself.
#   * PREFLIGHT_FAILED signal is consumed by the weekly-branch failure alert
#     below to avoid a duplicate Slack ping when both fire on the same
#     Monday cycle for the same root cause.
#   * The venv-broken marker is preserved through the post-Claude cleanup
#     sweep at the end of this script (a successful `claude -p` run doesn't
#     imply the venv is fixed — briefings use claude -p directly, NOT the
#     venv Python — so clearing venv-broken there would refire every cycle
#     and flood Slack; see 2026-06-15 incident, 39 pings/48h). Recovery is
#     signaled by a clean preflight (elif branch below).
#   * Full stderr goes to scheduler.log line-by-line so tracebacks aren't
#     truncated at 300 chars; Slack alert gets the first 300 chars as a
#     snippet plus a "see scheduler.log for full" pointer.
PREFLIGHT_FAILED=0
PREFLIGHT_STDERR="$BRIEFING_DIR/.preflight_stderr.$$"
if ! run_with_watchdog 15 ~/.briefings/venv/bin/python3 -c "import briefings_mcp" 2>"$PREFLIGHT_STDERR"; then
    PREFLIGHT_FAILED=1
    log "ERROR: venv preflight failed — ~/.briefings/venv/bin/python3 cannot import briefings_mcp. Full stderr follows:"
    if [ -s "$PREFLIGHT_STDERR" ]; then
        while IFS= read -r stderr_line; do
            log "  stderr | $stderr_line"
        done < "$PREFLIGHT_STDERR"
        err_snippet=$(tr '\n' ' ' < "$PREFLIGHT_STDERR" | cut -c1-300)
    else
        log "  stderr | <empty — likely missing interpreter or venv not created>"
        err_snippet="<empty — likely missing interpreter or venv not created>"
    fi
    notify_slack_once venv-broken ":broken_heart: Briefings runtime venv is broken — \`~/.briefings/venv/bin/python3 -c 'import briefings_mcp'\` fails. Impact: weekly auto-expiry, digest (Mon/Thu 10am), and the MCP server ALL use the venv. Briefings and follow-ups still run (they invoke \`claude -p\` directly). Full stderr in \`~/Briefings/scheduler.log\`; snippet: \`${err_snippet}\`. Recovery: \`brew install python@3.13 && rm -rf ~/.briefings/venv && /opt/homebrew/opt/python@3.13/bin/python3.13 -m venv ~/.briefings/venv && ~/.briefings/venv/bin/pip install -e <your meeting-intelligence clone>\`."
elif [ -f "$BRIEFING_DIR/.notify_dedup_venv-broken" ]; then
    # Preflight passed AND we had previously alerted about a broken venv →
    # the fix stuck. Clear the persistent marker and send a healthy-again
    # ping so the user knows things resumed (silent recovery erodes trust
    # in the original alert). No dedup on the recovery ping — it fires at
    # most once per broken/fixed cycle.
    rm -f "$BRIEFING_DIR/.notify_dedup_venv-broken" \
          "$BRIEFING_DIR/.notify_streak_venv-broken" \
          "$BRIEFING_DIR/.notify_escalated_venv-broken" \
          "$BRIEFING_DIR/.notify_count_venv-broken"
    log "Venv preflight recovered — briefings_mcp imports OK; clearing venv-broken dedup markers."
    notify_slack ":sparkles: Briefings venv is healthy again — weekly auto-expiry, digest, and MCP will resume on schedule."
fi
rm -f "$PREFLIGHT_STDERR"

# Monday, once per day — keep ~/Briefings/ from growing unbounded and send the
# weekly health summary to Slack. Sentinel file prevents multi-fire on every
# cycle before 09:00 (the old `< 09:16` window ran up to 38 times per Monday).
# Runs after lockfile acquisition to prevent two concurrent Monday cycles from
# both mutating the ledger via auto-expiry.
WEEKLY_SENTINEL="$BRIEFING_DIR/.last_weekly_summary"
if [ "$(date +%u)" = "1" ] && [ "$(date +%Y-%m-%d)" != "$(cat "$WEEKLY_SENTINEL" 2>/dev/null)" ]; then
    find "$BRIEFING_DIR" -name "*.md" -mtime +30 -delete
    find "$BRIEFING_DIR" -name "*-audit.jsonl" -mtime +30 -delete
    log "Cleaned up files older than 30 days."

    # Auto-expire stale open commitments from the ledger.
    # Rule: no-due-date items open >30 days, OR any item open >60 days.
    # These are almost always done-and-forgotten or abandoned; keeping them
    # floods the digest and erodes trust in what surfaces there.
    #
    # Two-pass Python design: pass 1 identifies drop candidates without any
    # mutations (schema drift / KeyError here leaves the ledger untouched);
    # pass 2 mutates atomically-per-entry (ledger.py:189-196 tmp+rename) and
    # catches its own exceptions to print the partial `dropped` list on
    # crash. The shell reads EXPIRED_JSON regardless of rc, so :broom-notify
    # fires with an accurate count even after a partial-mutation crash — the
    # user needs to know which items were pruned, not just that "something
    # failed" (2026-07-15 review: the old code claimed 'ledger not modified'
    # after mid-loop failures, which was false for entries dropped before
    # the crash).
    #
    # Stderr goes to a PID-scoped file in $BRIEFING_DIR (not mktemp) so a
    # TMPDIR issue can't make the block itself false-alarm. Full stderr is
    # logged line-by-line so tracebacks aren't truncated at 300 chars.
    EXPIRED_STDERR="$BRIEFING_DIR/.expiry_stderr.$$"
    EXPIRED_JSON=$(~/.briefings/venv/bin/python3 2>"$EXPIRED_STDERR" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone
from briefings_mcp import ledger

now = datetime.now(timezone.utc)

# Pass 1: identify drop candidates. Failures here happen before any mutation,
# so a crash leaves the ledger unmodified.
to_drop = []
for entry in ledger.iter_entries():
    if entry.get("type") != "commitment" or entry.get("state") not in ("open", "in-flight"):
        continue
    created = entry.get("created_at", "")
    try:
        normalised = created.replace("Z", "+00:00") if created.endswith("Z") else created
        age_days = (now - datetime.fromisoformat(normalised)).days
    except Exception:
        age_days = 0
    due = entry.get("due")
    if (not due and age_days > 30) or age_days > 60:
        to_drop.append((entry["id"], entry.get("summary", "")[:80]))

# Pass 2: mutate. On crash, print the partial list so the caller can still
# :broom-notify with an accurate count of what was persisted before failure.
dropped = []
try:
    for entry_id, summary in to_drop:
        ledger.update_commitment_state(entry_id, "dropped")
        dropped.append(summary)
except Exception as e:
    print(json.dumps(dropped))
    print(f"partial-crash after {len(dropped)}/{len(to_drop)} drops: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(1)

print(json.dumps(dropped))
PYEOF
    )
    EXPIRY_RC=$?

    # Parse count regardless of rc — Python prints partial state on crash.
    # `|| echo 0` guards against a totally empty EXPIRED_JSON (e.g. Python
    # never started because the venv is missing).
    EXPIRED_COUNT=$(/usr/bin/python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$EXPIRED_JSON" 2>/dev/null || echo 0)

    if [ "$EXPIRY_RC" -ne 0 ]; then
        log "ERROR: auto-expiry Python block failed (rc=$EXPIRY_RC) — ledger may be partially modified ($EXPIRED_COUNT drops persisted before crash). Full stderr follows:"
        if [ -s "$EXPIRED_STDERR" ]; then
            while IFS= read -r stderr_line; do
                log "  stderr | $stderr_line"
            done < "$EXPIRED_STDERR"
        else
            log "  stderr | <empty>"
        fi

        # :broom fires even on partial success — user needs to know what was
        # pruned so they can spot a legitimate drop that later looks like a
        # digest bug. Wording explicitly flags the partial-modification state.
        if [ "$EXPIRED_COUNT" -gt 0 ]; then
            notify_slack ":broom: Auto-pruned $EXPIRED_COUNT stale commitments BEFORE the auto-expiry Python block crashed (rc=$EXPIRY_RC). Ledger is partially modified. Check \`~/.briefings/decisions.jsonl\` state=dropped near this timestamp if you need to recover one."
        fi

        # Suppress the venv-broken-adjacent alert if the preflight already
        # fired this cycle — same root cause, avoids duplicate ping. Uses a
        # distinct dedup key so a genuine auto-expiry-only failure (e.g.
        # ledger schema drift with a healthy venv) still surfaces even when
        # a 4h-old venv-broken marker is on disk.
        if [ "$PREFLIGHT_FAILED" = "0" ]; then
            notify_slack_once auto-expiry-failed ":warning: Weekly auto-expiry crashed (rc=$EXPIRY_RC) — $EXPIRED_COUNT drops persisted before crash, ledger partially modified. Check \`~/Briefings/scheduler.log\` for full stderr. If venv is broken: \`brew install python@3.13 && rm -rf ~/.briefings/venv && /opt/homebrew/opt/python@3.13/bin/python3.13 -m venv ~/.briefings/venv && ~/.briefings/venv/bin/pip install -e <your meeting-intelligence clone>\`."
        else
            log "auto-expiry-failed notification suppressed — preflight already alerted this cycle (same root cause)."
        fi
    elif [ "$EXPIRED_COUNT" -gt 0 ]; then
        log "Auto-expired $EXPIRED_COUNT stale commitments from ledger."
        notify_slack ":broom: Auto-pruned $EXPIRED_COUNT stale commitments (no-due items open >30 days, or any item >60 days). Check \`~/.briefings/decisions.jsonl\` state=dropped if you need to recover one."
    else
        log "Auto-expiry: no stale commitments found."
    fi

    rm -f "$EXPIRED_STDERR"

    generate_health_summary
    date +%Y-%m-%d > "$WEEKLY_SENTINEL"
fi

# Track Claude Code version changes so we can run TCC cleanup proactively on update.
# Flagging the change up front gives the user context if briefings start failing.
#
# The CLAUDE_VERSION_FILE is NOT written here — it is written only after a successful
# Claude invocation later in this script. Writing it eagerly would mean a single missed
# App Management prompt (e.g. while the user is asleep) silences the version-change Slack
# alert on every subsequent cycle even though briefings are still failing. Deferring the
# write means the alert re-fires on every cycle until at least one Claude run succeeds.
CURRENT_CLAUDE_VERSION=$("$CLAUDE" --version 2>/dev/null | head -1 || echo "unknown")
LAST_CLAUDE_VERSION=$(cat "$CLAUDE_VERSION_FILE" 2>/dev/null || echo "")
if [ -n "$LAST_CLAUDE_VERSION" ] && [ "$CURRENT_CLAUDE_VERSION" != "$LAST_CLAUDE_VERSION" ]; then
    log "Claude Code version changed: $LAST_CLAUDE_VERSION → $CURRENT_CLAUDE_VERSION"
    # Proactively fix any auth_value=5 TCC rows introduced by the new versioned binary.
    # On macOS Sequoia, clicking Allow on the per-version App Management prompt writes
    # auth_value=5 (re-prompt-always) instead of auth_value=2 (allowed). The unstick
    # helper UPDATEs 5→2 for live binary paths so the scheduler cycle can proceed
    # without a re-prompt loop. Run before the Claude invocation below.
    UNSTICK="$HOME/.local/bin/claude-tcc-unstick"
    if [ -x "$UNSTICK" ]; then
        log "Version bump: running TCC cleanup for new binary."
        "$UNSTICK" 2>&1 | tee -a "$BRIEFING_DIR/scheduler.log" || true
    fi
    notify_slack ":sparkles: Claude Code updated (\`$LAST_CLAUDE_VERSION\` → \`$CURRENT_CLAUDE_VERSION\`). Running TCC cleanup automatically. A one-time macOS permission prompt may still appear — click Allow if it does, then TCC cleanup will keep it stable. If briefings fail after the update, check \`~/Briefings/scheduler.log\`."
fi

# === Pre-flight gate ===
# One gws call surfaces both auth state and calendar contents. Fails open: if the
# fetch fails for any non-auth reason, invoke Claude anyway so we never miss work.

TIME_MIN=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)
TIME_MAX=$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)
CAL_EVENTS=$("$GWS" calendar events list --params "{\"calendarId\":\"primary\",\"timeMin\":\"$TIME_MIN\",\"timeMax\":\"$TIME_MAX\",\"singleEvents\":true,\"orderBy\":\"startTime\"}" 2>&1)

if echo "$CAL_EVENTS" | grep -q "invalid_grant\|Token has been expired or revoked\|OAuth token has expired"; then
    log "ERROR: gws auth check failed — token needs refresh."
    touch "$GWS_AUTH_FAILED_FILE"
    notify_slack_once gws-oauth ":key: Briefings paused — gws OAuth token expired. Run \`gws auth login\` in your terminal to re-authenticate."
    exit 1
fi

if [ -f "$GWS_AUTH_FAILED_FILE" ]; then
    rm -f "$GWS_AUTH_FAILED_FILE"
    rm -f "$BRIEFING_DIR/.notify_dedup_gws-oauth" \
          "$BRIEFING_DIR/.notify_streak_gws-oauth" \
          "$BRIEFING_DIR/.notify_escalated_gws-oauth" \
          "$BRIEFING_DIR/.notify_count_gws-oauth"
    notify_slack ":white_check_mark: Briefings resumed — gws OAuth token refreshed successfully."
fi

NEED_BRIEFING=0
NEED_FOLLOWUP=0
NEED_DIGEST=0

if echo "$CAL_EVENTS" | grep -q '"items"'; then
    GATE_OUTPUT=$(CAL_DATA="$CAL_EVENTS" python3 <<'PYEOF'
import os, sys, json
from datetime import datetime, timezone, timedelta

def parse_iso(s):
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        # strptime fallback for Python 3.9 which has a narrower fromisoformat
        for fmt in ('%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%dT%H:%M%z'):
            try:
                return datetime.strptime(s, fmt)
            except ValueError:
                continue
        raise

raw = os.environ.get('CAL_DATA', '')
# gws prints a "Using keyring backend" preamble before JSON; find first '{'
brace = raw.find('{')
try:
    data = json.loads(raw[brace:]) if brace >= 0 else {}
except Exception:
    print("BRIEFING=1")
    print("FOLLOWUP=1")
    sys.exit(0)

events = data.get('items', [])
now = datetime.now(timezone.utc)
plus2h   = now + timedelta(hours=2)
minus15m = now - timedelta(minutes=15)
minus2d  = now - timedelta(days=2)

briefing_dir = os.path.expanduser('~/Briefings')
existing = os.listdir(briefing_dir) if os.path.isdir(briefing_dir) else []

need_briefing = False
need_followup = False

for ev in events:
    attendees = ev.get('attendees', []) or []
    me = next((a for a in attendees if a.get('self')), None)
    if me and me.get('responseStatus') == 'declined':
        continue

    start_str = ev.get('start', {}).get('dateTime')
    end_str   = ev.get('end', {}).get('dateTime')
    if not start_str or not end_str:
        continue

    if ev.get('eventType') in ('workingLocation', 'outOfOffice', 'focusTime'):
        continue

    if len(attendees) < 2:
        continue

    try:
        start_dt = parse_iso(start_str)
        end_dt   = parse_iso(end_str)
    except Exception:
        continue

    prefix = start_dt.astimezone().strftime('%Y-%m-%d-%H%M')

    has_briefing = any(
        f.startswith(prefix + '-') and '-followup-' not in f and '-awaiting-' not in f
        for f in existing
    )
    has_followup_or_awaiting = any(
        f.startswith(prefix + '-followup-') or f.startswith(prefix + '-awaiting-')
        for f in existing
    )

    # Briefing window: starts in next 2h OR started in last 15min (joining late)
    if minus15m <= start_dt <= plus2h and not has_briefing:
        need_briefing = True

    # Follow-up window: ended in past, within last 2 days, no follow-up file yet
    if minus2d <= end_dt < now and not has_followup_or_awaiting:
        need_followup = True

# An awaiting file means a transcript reply may have arrived
if any('-awaiting-' in f and f.endswith('.md') for f in existing):
    need_followup = True

print(f"BRIEFING={1 if need_briefing else 0}")
print(f"FOLLOWUP={1 if need_followup else 0}")
PYEOF
)
    NEED_BRIEFING=$(echo "$GATE_OUTPUT" | grep '^BRIEFING=' | cut -d= -f2)
    NEED_FOLLOWUP=$(echo "$GATE_OUTPUT" | grep '^FOLLOWUP=' | cut -d= -f2)
    : "${NEED_BRIEFING:=0}"
    : "${NEED_FOLLOWUP:=0}"
else
    # Calendar fetch failed for a non-auth reason — fail open so we don't silently miss work
    log "WARN: calendar fetch failed, invoking Claude as fallback."
    NEED_BRIEFING=1
    NEED_FOLLOWUP=1
fi

# === Actions tracker digest gate (Phase 3) ===
# Mon and Thu at 10:00-10:14 local, exactly once per day (idempotent against today's digest file).
DOW=$(date +%u)   # 1=Mon, 4=Thu
HHMM=$(date +%H:%M)
TODAY=$(date +%Y-%m-%d)
if { [ "$DOW" = "1" ] || [ "$DOW" = "4" ]; } \
   && [[ "$HHMM" > "09:59" ]] && [[ "$HHMM" < "10:15" ]] \
   && [ ! -f "$BRIEFING_DIR/${TODAY}-1000-digest.md" ]; then
    NEED_DIGEST=1
fi

if [ "$NEED_BRIEFING" = "0" ] && [ "$NEED_FOLLOWUP" = "0" ] && [ "$NEED_DIGEST" = "0" ]; then
    log "Pre-flight: nothing to do, skipped Claude."
    exit 0
fi

# Bounded Claude invocation. 900s = 15 min. Raised from 600s on 2026-06-26 after a
# 40h sample showed legitimate briefing+follow-up cycles routinely landing 420-600s,
# leaving zero headroom against the previous 600s cap and producing a steady ~15
# false-positive :hourglass: pings per day. 900s tracks the p99 of awake-time
# /follow-up runtime with headroom for the combined briefing+follow-up case;
# overnight stalls are now handled separately by the watchdog's rc==125 sleep-skip
# branch, so the cap no longer needs to absorb sleep gaps. Previous 600s rationale
# from 2026-06-15 (kill faster so the next launchd tick retries on a fresh LLM)
# still applies — 900s preserves that within one 15-min cycle. On timeout (exit 124)
# the lock is released by the EXIT trap and the next launchd tick takes over.
CLAUDE_TIMEOUT_SECONDS=900

# Transient Anthropic SDK errors. Most overnight occurrences happen during macOS
# dark-wake transitions where the network briefly drops mid-request. Retry once
# within the cycle (30s back-off) so a single socket blip doesn't fire a Slack
# alert and wait 15 min for the next launchd tick to recover.
TRANSIENT_API_ERROR_RE='socket connection was closed unexpectedly|ECONNRESET|fetch failed|Connection error|network error'

run_claude() {
    local label="$1"
    local prompt="$2"
    log "Running: $label"
    local output rc attempt t
    for attempt in 1 2; do
        t=$([ "$attempt" = "1" ] && echo "$CLAUDE_TIMEOUT_SECONDS" || echo $(( CLAUDE_TIMEOUT_SECONDS / 2 )))
        output=$(run_with_watchdog "$t" "$CLAUDE" -p "$prompt" 2>&1)
        rc=$?
        if [ "$attempt" = "1" ] && [ "$rc" -ne 0 ] \
            && echo "$output" | grep -qE "$TRANSIENT_API_ERROR_RE"; then
            log "WARN: $label hit transient API error on attempt 1 — retrying in 30s."
            sleep 30
            continue
        fi
        break
    done
    if [ "$attempt" = "2" ] && [ "$rc" -eq 0 ]; then
        log "INFO: $label recovered on retry."
    fi
    echo "$output" >> "$BRIEFING_DIR/scheduler.log"
    if [ "$rc" -eq 124 ]; then
        log "ERROR: $label timed out after ${t}s (Claude killed)."
        notify_slack_once timeout ":hourglass: Briefings stalled — Claude Code did not return within ${t}s and was killed. Check \`~/Briefings/scheduler.log\` for the last output. Common causes: stuck MCP tool, hung gws subprocess, or LLM stall. Next cycle will retry."
    elif [ "$rc" -eq 125 ]; then
        # Watchdog deadline elapsed but >50% of the budget was attributed to host sleep.
        # No real stall — the laptop slept through the cycle. Log it, but do not Slack:
        # the next launchd tick on wake will retry naturally.
        log "INFO: $label skipped (host-sleep majority of ${t}s budget — no Slack ping)."
    elif [ "$rc" -ne 0 ] && echo "$output" | grep -qE "$TRANSIENT_API_ERROR_RE"; then
        log "ERROR: $label hit transient API errors on both attempts."
        notify_slack_once api-error ":satellite_antenna: Briefings hit two consecutive Anthropic API socket drops at $(date '+%Y-%m-%d %H:%M'). Usually transient — next 15-min cycle will retry. Check \`~/Briefings/scheduler.log\` if it persists."
    elif echo "$output" | grep -q "401\|authentication_error\|OAuth token has expired\|Please run /login"; then
        log "ERROR: $label auth failure."
        notify_slack_once claude-oauth ":key: Briefings paused — Claude Code session expired or logged out. Run \`claude\` interactively and complete /login."
    elif echo "$output" | grep -qiE "permission prompt|requires approval|allow this tool|not allowed|tool use was not approved"; then
        log "ERROR: $label permission prompt — Claude Code wants approval the scheduler cannot give."
        notify_slack_once permission ":lock: Briefings paused — Claude Code is asking for permission approval. Open a terminal, run \`claude\` once interactively, accept any prompts, then briefings will resume on the next 15-min cycle."
    elif [ "$rc" -ne 0 ]; then
        log "ERROR: $label exited with non-zero status ($rc)."
        notify_slack_once generic ":warning: $label failed at $(date '+%Y-%m-%d %H:%M'). Check ~/Briefings/scheduler.log — common causes: Claude Code permission prompt after an update, or transient Claude/network outage."
    fi
    return "$rc"
}

# Combined dispatch — Claude executes commands sequentially within a single invocation when
# multiple flags fire. Each command has its own internal checks and will skip cleanly if
# nothing applies, so over-firing is safe (just wastes a small amount of token budget).
COMMANDS=()
[ "$NEED_BRIEFING" = "1" ] && COMMANDS+=("/briefing all")
[ "$NEED_FOLLOWUP" = "1" ] && COMMANDS+=("/follow-up all")
[ "$NEED_DIGEST" = "1" ]   && COMMANDS+=("/digest")

CLAUDE_RAN_SUCCESSFULLY=0
if [ "${#COMMANDS[@]}" -gt 0 ]; then
    label=$(IFS='+'; echo "${COMMANDS[*]}" | sed 's| all||g; s|/||g')
    prompt=$(IFS=$'\n'; printf 'Run ONLY these slash commands, in this exact order, then stop:\n%s\n\nDo not invoke any other slash command, even if it appears that doing so would be helpful. Each listed command has its own internal checks and will skip cleanly if nothing applies. After the last listed command finishes, end your turn with a brief summary — do not continue with additional work.' "${COMMANDS[*]}")
    if run_claude "$label" "$prompt"; then
        CLAUDE_RAN_SUCCESSFULLY=1
    fi
fi

# Record the current Claude Code version only after a successful run. If the run failed
# (auth, timeout, permission prompt, transient outage), leave CLAUDE_VERSION_FILE stale so
# the version-change Slack alert at the top of the script re-fires on the next cycle.
if [ "$CLAUDE_RAN_SUCCESSFULLY" = "1" ]; then
    echo "$CURRENT_CLAUDE_VERSION" > "$CLAUDE_VERSION_FILE"
    # Reset notify_slack_once dedup markers so the next failure re-pings
    # instead of being suppressed by a stale marker from an earlier failure
    # window. EXCEPT: markers whose cause is orthogonal to Claude running.
    # A successful `claude -p` doesn't imply the venv is fixed (briefings
    # use claude -p directly, NOT the venv Python), so clearing venv-broken
    # here would refire on every subsequent cycle — reproducing the
    # 2026-06-15 39-pings-in-48h flood pattern. auto-expiry-failed is
    # likewise weekly-branch-only and cleared by its own next occurrence.
    # These markers are cleared by their own recovery paths (see venv
    # preflight recovery branch near the top of this script).
    # Clear all four notify-state file kinds on successful cycle: dedup marker,
    # streak counter, per-window escalation marker, cumulative count. venv-broken
    # and auto-expiry-failed are excluded from all four for the same reason the
    # original dedup exclusion existed — a successful claude cycle doesn't imply
    # those subsystems are healthy (see the 2026-07-15 flood-avoidance comment
    # on the venv preflight branch above).
    for marker in "$BRIEFING_DIR"/.notify_dedup_* "$BRIEFING_DIR"/.notify_streak_* "$BRIEFING_DIR"/.notify_escalated_* "$BRIEFING_DIR"/.notify_count_*; do
        [ -e "$marker" ] || continue
        case "$(basename "$marker")" in
            .notify_dedup_venv-broken|.notify_dedup_auto-expiry-failed) continue ;;
            .notify_streak_venv-broken|.notify_streak_auto-expiry-failed) continue ;;
            .notify_escalated_venv-broken|.notify_escalated_auto-expiry-failed) continue ;;
            .notify_count_venv-broken|.notify_count_auto-expiry-failed) continue ;;
            *) rm -f "$marker" ;;
        esac
    done
fi

log "Done."
