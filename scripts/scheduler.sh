#!/bin/bash
# Runs every 15 minutes via launchd.
# version: 2026-05-27 Phase 3 — adds NEED_DIGEST gate for the twice-weekly actions tracker (Mon and Thu at 10am local). Previous: 2026-05-19 — extracted notify_slack/log helpers, dropped redundant gmail probe.

BRIEFING_DIR="$HOME/Briefings"
LOCK_FILE="$BRIEFING_DIR/.scheduler.lock"
GWS_AUTH_FAILED_FILE="$BRIEFING_DIR/.gws_auth_failed"
CLAUDE_VERSION_FILE="$BRIEFING_DIR/.claude_version"
SLACK_WEBHOOK=$(cat ~/.slack_webhook 2>/dev/null)
CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")
GWS=$(command -v gws 2>/dev/null || echo "/opt/homebrew/bin/gws")

umask 077
mkdir -p "$BRIEFING_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] $1" >> "$BRIEFING_DIR/scheduler.log"; }
notify_slack() {
    [ -n "$SLACK_WEBHOOK" ] || return 0
    curl -s -X POST "$SLACK_WEBHOOK" \
        -H 'Content-type: application/json' \
        -d "{\"text\": \"$1\"}"
}

if [ -f "$BRIEFING_DIR/scheduler.log" ] && [ "$(wc -c < "$BRIEFING_DIR/scheduler.log")" -gt 512000 ]; then
    tail -500 "$BRIEFING_DIR/scheduler.log" > "$BRIEFING_DIR/scheduler.log.tmp"
    mv "$BRIEFING_DIR/scheduler.log.tmp" "$BRIEFING_DIR/scheduler.log"
fi

# Mondays before 09:16 (one cycle window) — keep ~Briefings/ from growing unbounded.
if [ "$(date +%u)" = "1" ] && [[ "$(date +%H:%M)" < "09:16" ]]; then
    find "$BRIEFING_DIR" -name "*.md" -mtime +30 -delete
    log "Cleaned up files older than 30 days."
fi

if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        log "Already running (PID $pid), skipping."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
# Single quotes: $LOCK_FILE expands at trap-firing time, not trap-definition.
trap 'rm -f "$LOCK_FILE"' EXIT

# After some Claude Code updates, --dangerously-skip-permissions can be re-prompted,
# which the headless scheduler cannot answer. Flagging the version change up front means
# the user knows what to do if briefings start failing silently afterwards.
CURRENT_CLAUDE_VERSION=$("$CLAUDE" --version 2>/dev/null | head -1 || echo "unknown")
LAST_CLAUDE_VERSION=$(cat "$CLAUDE_VERSION_FILE" 2>/dev/null || echo "")
if [ -n "$LAST_CLAUDE_VERSION" ] && [ "$CURRENT_CLAUDE_VERSION" != "$LAST_CLAUDE_VERSION" ]; then
    log "Claude Code version changed: $LAST_CLAUDE_VERSION → $CURRENT_CLAUDE_VERSION"
    notify_slack ":sparkles: Claude Code updated (\`$LAST_CLAUDE_VERSION\` → \`$CURRENT_CLAUDE_VERSION\`). If briefings start failing, open a terminal and run \`claude\` once interactively to confirm any new permission prompts."
fi
echo "$CURRENT_CLAUDE_VERSION" > "$CLAUDE_VERSION_FILE"

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
    # Python 3.9 fromisoformat doesn't handle 'Z' — normalise to +00:00
    if s.endswith('Z'):
        s = s[:-1] + '+00:00'
    return datetime.fromisoformat(s)

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

if ls "$BRIEFING_DIR"/*-awaiting-*.md >/dev/null 2>&1; then
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

run_claude() {
    local label="$1"
    local prompt="$2"
    log "Running: $label"
    local output rc
    output=$("$CLAUDE" -p --dangerously-skip-permissions "$prompt" 2>&1)
    rc=$?
    echo "$output" >> "$BRIEFING_DIR/scheduler.log"
    if echo "$output" | grep -q "401\|authentication_error\|OAuth token has expired"; then
        log "ERROR: $label auth failure."
        notify_slack ":key: Briefings paused — OAuth token expired. Run \`claude\` interactively to refresh."
    elif echo "$output" | grep -qi "permission\|requires approval\|allow this tool\|not allowed"; then
        log "ERROR: $label permission prompt — Claude Code wants approval the scheduler cannot give."
        notify_slack ":lock: Briefings paused — Claude Code is asking for permission approval. Open a terminal, run \`claude\` once interactively, accept any prompts, then briefings will resume on the next 15-min cycle."
    elif [ "$rc" -ne 0 ]; then
        log "ERROR: $label exited with non-zero status ($rc)."
        notify_slack ":warning: $label failed at $(date '+%Y-%m-%d %H:%M'). Check ~/Briefings/scheduler.log — common causes: Claude Code permission prompt after an update, or transient Claude/network outage."
    fi
}

# Combined dispatch — Claude executes commands sequentially within a single invocation when
# multiple flags fire. Each command has its own internal checks and will skip cleanly if
# nothing applies, so over-firing is safe (just wastes a small amount of token budget).
COMMANDS=()
[ "$NEED_BRIEFING" = "1" ] && COMMANDS+=("/briefing all")
[ "$NEED_FOLLOWUP" = "1" ] && COMMANDS+=("/follow-up all")
[ "$NEED_DIGEST" = "1" ]   && COMMANDS+=("/digest")

if [ "${#COMMANDS[@]}" -gt 0 ]; then
    label=$(IFS='+'; echo "${COMMANDS[*]}" | sed 's| all||g; s|/||g')
    prompt=$(IFS=$'\n'; printf 'Run these in sequence:\n%s\n\nEach command has its own internal checks and will skip cleanly if nothing applies.' "${COMMANDS[*]}")
    run_claude "$label" "$prompt"
fi

log "Done."
