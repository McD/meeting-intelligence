#!/bin/bash
# Runs via cron every 15 minutes.
# version: 2026-04-30 — combined briefing + follow-up into a single Claude call when both are needed.

BRIEFING_DIR="$HOME/Briefings"
LOCK_FILE="$BRIEFING_DIR/.scheduler.lock"
SLACK_WEBHOOK=$(cat ~/.slack_webhook 2>/dev/null)
CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")
GWS=/opt/homebrew/bin/gws

umask 077
mkdir -p "$BRIEFING_DIR"

# Log rotation: keep last 500 lines when log exceeds 500KB
if [ -f "$BRIEFING_DIR/scheduler.log" ] && [ "$(wc -c < "$BRIEFING_DIR/scheduler.log")" -gt 512000 ]; then
    tail -500 "$BRIEFING_DIR/scheduler.log" > "$BRIEFING_DIR/scheduler.log.tmp"
    mv "$BRIEFING_DIR/scheduler.log.tmp" "$BRIEFING_DIR/scheduler.log"
fi

# Weekly cleanup: delete briefings older than 30 days (runs on Mondays before 9:16am)
if [ "$(date +%u)" = "1" ] && [[ "$(date +%H:%M)" < "09:16" ]]; then
    find "$BRIEFING_DIR" -name "*.md" -mtime +30 -delete
    echo "[$(date '+%Y-%m-%d %H:%M')] Cleaned up files older than 30 days." >> "$BRIEFING_DIR/scheduler.log"
fi

# Prevent overlapping runs
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M')] Already running (PID $pid), skipping." >> "$BRIEFING_DIR/scheduler.log"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

# Pre-flight: verify gws OAuth token is valid before doing any work
GWS_AUTH_FAILED_FILE="$BRIEFING_DIR/.gws_auth_failed"
GWS_CHECK=$("$GWS" gmail users messages list --params '{"userId":"me","maxResults":1}' 2>&1)
if echo "$GWS_CHECK" | grep -q "401\|invalid_grant\|Token has been expired\|token expired\|OAuth token\|authentication"; then
    echo "[$(date '+%Y-%m-%d %H:%M')] ERROR: gws auth check failed — token needs refresh." >> "$BRIEFING_DIR/scheduler.log"
    touch "$GWS_AUTH_FAILED_FILE"
    if [ -n "$SLACK_WEBHOOK" ]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            -d "{\"text\": \":key: Briefings paused — gws OAuth token expired. Run \`gws auth login\` in your terminal to re-authenticate.\"}"
    fi
    exit 1
fi

# If we just recovered from an auth failure, notify Slack
if [ -f "$GWS_AUTH_FAILED_FILE" ]; then
    rm -f "$GWS_AUTH_FAILED_FILE"
    if [ -n "$SLACK_WEBHOOK" ]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-type: application/json' \
            -d "{\"text\": \":white_check_mark: Briefings resumed — gws OAuth token refreshed successfully.\"}"
    fi
fi

# === Pre-flight gate: only invoke Claude if there's actual work ===
# Asks gws Calendar directly: any meeting needing briefing? any ended meeting needing follow-up?
# Plus: any *-awaiting-*.md files (transcript replies to check)?
# Fails open: if calendar fetch fails, invoke Claude anyway so we never miss work.

# Calendar window: -2 days to +2 hours (covers both briefing and follow-up windows)
TIME_MIN=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)
TIME_MAX=$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)
CAL_EVENTS=$("$GWS" calendar events list --params "{\"calendarId\":\"primary\",\"timeMin\":\"$TIME_MIN\",\"timeMax\":\"$TIME_MAX\",\"singleEvents\":true,\"orderBy\":\"startTime\"}" 2>&1)

NEED_BRIEFING=0
NEED_FOLLOWUP=0

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
    # Skip events I declined
    attendees = ev.get('attendees', []) or []
    me = next((a for a in attendees if a.get('self')), None)
    if me and me.get('responseStatus') == 'declined':
        continue

    # Skip all-day events (no dateTime, only date)
    start_field = ev.get('start', {})
    end_field   = ev.get('end', {})
    start_str = start_field.get('dateTime')
    end_str   = end_field.get('dateTime')
    if not start_str or not end_str:
        continue

    # Skip working-location entries and similar non-meeting types
    if ev.get('eventType') in ('workingLocation', 'outOfOffice', 'focusTime'):
        continue

    # Skip solo blocks (need 2+ attendees)
    if len(attendees) < 2:
        continue

    try:
        start_dt = parse_iso(start_str)
        end_dt   = parse_iso(end_str)
    except Exception:
        continue

    # File slugs use local-time HHMM prefix
    local_start = start_dt.astimezone()
    prefix = local_start.strftime('%Y-%m-%d-%H%M')

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

# Awaiting files always need checking (transcript reply may have arrived)
if any('-awaiting-' in f and f.endswith('.md') for f in existing):
    need_followup = True

print(f"BRIEFING={1 if need_briefing else 0}")
print(f"FOLLOWUP={1 if need_followup else 0}")
PYEOF
)
    eval "$GATE_OUTPUT"
    NEED_BRIEFING=$BRIEFING
    NEED_FOLLOWUP=$FOLLOWUP
else
    # Calendar fetch failed — fail open so we don't silently miss work
    echo "[$(date '+%Y-%m-%d %H:%M')] WARN: calendar fetch failed, invoking Claude as fallback." >> "$BRIEFING_DIR/scheduler.log"
    NEED_BRIEFING=1
    NEED_FOLLOWUP=1
fi

# Belt-and-braces: any awaiting file at all forces follow-up (even if calendar parse missed it)
if ls "$BRIEFING_DIR"/*-awaiting-*.md >/dev/null 2>&1; then
    NEED_FOLLOWUP=1
fi

if [ "$NEED_BRIEFING" = "0" ] && [ "$NEED_FOLLOWUP" = "0" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M')] Pre-flight: nothing to do, skipped Claude." >> "$BRIEFING_DIR/scheduler.log"
    exit 0
fi

# === Invoke Claude only for the work that's actually needed ===
# When both are needed, run a single combined call (saves ~50% of Claude invocations
# during busy mornings). When only one is needed, single-purpose call.

run_claude() {
    local label="$1"
    local prompt="$2"
    echo "[$(date '+%Y-%m-%d %H:%M')] Running: $label" >> "$BRIEFING_DIR/scheduler.log"
    local output
    output=$("$CLAUDE" -p --dangerously-skip-permissions "$prompt" 2>&1)
    echo "$output" >> "$BRIEFING_DIR/scheduler.log"
    if echo "$output" | grep -q "401\|authentication_error\|OAuth token has expired"; then
        echo "[$(date '+%Y-%m-%d %H:%M')] ERROR: $label auth failure." >> "$BRIEFING_DIR/scheduler.log"
        if [ -n "$SLACK_WEBHOOK" ]; then
            curl -s -X POST "$SLACK_WEBHOOK" \
                -H 'Content-type: application/json' \
                -d "{\"text\": \":key: Briefings paused — OAuth token expired. Run: claude /briefing to refresh.\"}"
        fi
    elif ! echo "$output" | grep -q "."; then
        echo "[$(date '+%Y-%m-%d %H:%M')] ERROR: $label exited with failure." >> "$BRIEFING_DIR/scheduler.log"
        if [ -n "$SLACK_WEBHOOK" ]; then
            curl -s -X POST "$SLACK_WEBHOOK" \
                -H 'Content-type: application/json' \
                -d "{\"text\": \":warning: $label failed at $(date '+%Y-%m-%d %H:%M'). Check ~/Briefings/scheduler.log\"}"
        fi
    fi
}

if [ "$NEED_BRIEFING" = "1" ] && [ "$NEED_FOLLOWUP" = "1" ]; then
    run_claude "briefing+follow-up" "Run /briefing all, then run /follow-up all. Both commands have their own internal checks and will skip cleanly if nothing applies."
elif [ "$NEED_BRIEFING" = "1" ]; then
    run_claude "briefing" "Run /briefing all"
elif [ "$NEED_FOLLOWUP" = "1" ]; then
    run_claude "follow-up" "Run /follow-up all"
fi

echo "[$(date '+%Y-%m-%d %H:%M')] Done." >> "$BRIEFING_DIR/scheduler.log"
