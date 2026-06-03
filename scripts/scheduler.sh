#!/bin/bash
# Runs every 15 minutes via launchd.
# version: 2026-06-01 — Removed gtimeout invocation entirely. Replaced with a bash-native `run_with_watchdog` function using only Apple-signed system binaries (bash builtins + /bin/sleep + /bin/kill). Sidesteps a macOS Sequoia TCC bug where kTCCServiceSystemPolicyAppData consent for adhoc-signed Homebrew CLI binaries (gtimeout) writes auth_value=5 instead of 2 on Allow, causing every 15-min cycle to re-prompt the user. Wall-clock semantics instead of gtimeout's awake-time; the lockfile + 15-min cadence already protect against runaway cycles, so the laptop-sleeps-mid-cycle edge case is bounded. Previous: 2026-05-28d — CLAUDE_TIMEOUT_SECONDS raised from 600 to 1200. Earlier: 2026-05-28b — detects `timeout`/`gtimeout` at script start; install.sh installed coreutils as Step 4 (no longer required). 2026-05-28 — notify_slack curl gets --max-time/--connect-timeout; run_claude wrapped in timeout 600; CLAUDE_VERSION_FILE deferred until after a successful run. Phase 3 — adds NEED_DIGEST gate.

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
# Wall-clock semantics (not gtimeout's awake-time) — see version comment
# above for the trade-off. /usr/bin/python3 is part of macOS Xcode Command
# Line Tools; install.sh's Step 3 (Claude Code) already requires brew which
# requires xcode-select, so python3 is present on every supported install.
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

skipped = ran = done = t_timeout = t_auth = t_perm = t_other = 0

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
        if 'skipped Claude' in line:
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
print("\\n".join(lines))
PYEOF
    )

    [ -n "$summary" ] && notify_slack "$summary"
}

umask 077
mkdir -p "$BRIEFING_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] $1" >> "$BRIEFING_DIR/scheduler.log"; }
notify_slack() {
    [ -n "$SLACK_WEBHOOK" ] || return 0
    # --max-time/--connect-timeout: Slack stalls must not hold .scheduler.lock.
    # Delivery is fire-and-forget; nothing downstream depends on the response.
    local payload
    payload=$(/usr/bin/python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" "$1")
    curl -s --connect-timeout 5 --max-time 10 -X POST "$SLACK_WEBHOOK" \
        -H 'Content-type: application/json' \
        -d "$payload" >/dev/null 2>&1 || true
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
    EXPIRED_JSON=$(~/.briefings/venv/bin/python3 <<'PYEOF'
import json
from datetime import datetime, timezone
from briefings_mcp import ledger

now = datetime.now(timezone.utc)
dropped = []
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
        ledger.update_commitment_state(entry["id"], "dropped")
        dropped.append(entry.get("summary", "")[:80])

print(json.dumps(dropped))
PYEOF
    )
    EXPIRY_RC=$?
    if [ "$EXPIRY_RC" -ne 0 ]; then
        log "ERROR: auto-expiry Python block failed (rc=$EXPIRY_RC) — ledger not modified."
    fi
    EXPIRED_COUNT=$(/usr/bin/python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$EXPIRED_JSON" 2>/dev/null || echo 0)
    if [ "$EXPIRED_COUNT" -gt 0 ]; then
        log "Auto-expired $EXPIRED_COUNT stale commitments from ledger."
        notify_slack ":broom: Auto-pruned $EXPIRED_COUNT stale commitments (no-due items open >30 days, or any item >60 days). Check \`~/.briefings/decisions.jsonl\` state=dropped if you need to recover one."
    else
        log "Auto-expiry: no stale commitments found."
    fi

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
    notify_slack ":key: Briefings paused — gws OAuth token expired. Run \`gws auth login\` in your terminal to re-authenticate."
    exit 1
fi

if [ -f "$GWS_AUTH_FAILED_FILE" ]; then
    rm -f "$GWS_AUTH_FAILED_FILE"
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

# Bounded Claude invocation. 1200s = 20 min covers the slowest observed cycles with
# real safety margin. Wall-clock timer (the bash-native run_with_watchdog above);
# the laptop sleeping mid-cycle is rare for a 15-min cadence with 20-min ceiling, and
# the lockfile cleans up any cycle that gets killed by the watchdog. Tighter caps
# (was 600s briefly) false-positive on healthy but-slow /follow-up sweeps that send
# a transcript request mid-cycle. On timeout (exit 124) the lock is released by the
# EXIT trap and the next launchd tick takes over.
CLAUDE_TIMEOUT_SECONDS=1200

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
        notify_slack ":hourglass: Briefings stalled — Claude Code did not return within ${t}s and was killed. Check \`~/Briefings/scheduler.log\` for the last output. Common causes: stuck MCP tool, hung gws subprocess, or LLM stall. Next cycle will retry."
    elif [ "$rc" -ne 0 ] && echo "$output" | grep -qE "$TRANSIENT_API_ERROR_RE"; then
        log "ERROR: $label hit transient API errors on both attempts."
        notify_slack ":satellite_antenna: Briefings hit two consecutive Anthropic API socket drops at $(date '+%Y-%m-%d %H:%M'). Usually transient — next 15-min cycle will retry. Check \`~/Briefings/scheduler.log\` if it persists."
    elif echo "$output" | grep -q "401\|authentication_error\|OAuth token has expired"; then
        log "ERROR: $label auth failure."
        notify_slack ":key: Briefings paused — OAuth token expired. Run \`claude\` interactively to refresh."
    elif echo "$output" | grep -qi "permission\|requires approval\|allow this tool\|not allowed"; then
        log "ERROR: $label permission prompt — Claude Code wants approval the scheduler cannot give."
        notify_slack ":lock: Briefings paused — Claude Code is asking for permission approval. Open a terminal, run \`claude\` once interactively, accept any prompts, then briefings will resume on the next 15-min cycle."
    elif [ "$rc" -ne 0 ]; then
        log "ERROR: $label exited with non-zero status ($rc)."
        notify_slack ":warning: $label failed at $(date '+%Y-%m-%d %H:%M'). Check ~/Briefings/scheduler.log — common causes: Claude Code permission prompt after an update, or transient Claude/network outage."
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
    prompt=$(IFS=$'\n'; printf 'Run these in sequence:\n%s\n\nEach command has its own internal checks and will skip cleanly if nothing applies.' "${COMMANDS[*]}")
    if run_claude "$label" "$prompt"; then
        CLAUDE_RAN_SUCCESSFULLY=1
    fi
fi

# Record the current Claude Code version only after a successful run. If the run failed
# (auth, timeout, permission prompt, transient outage), leave CLAUDE_VERSION_FILE stale so
# the version-change Slack alert at the top of the script re-fires on the next cycle.
if [ "$CLAUDE_RAN_SUCCESSFULLY" = "1" ]; then
    echo "$CURRENT_CLAUDE_VERSION" > "$CLAUDE_VERSION_FILE"
fi

log "Done."
