#!/bin/bash
# Smoke tests for scheduler improvements (2026-06-02).
# Run from repo root: bash scripts/smoke_test_improvements.sh
set -e
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Task 1: Injection defense sections ==="
for f in commands/briefing.md commands/follow-up.md commands/digest.md; do
    if grep -q "## Security" "$REPO/$f"; then
        ok "$f has ## Security section"
    else
        fail "$f missing ## Security section"
    fi
    if grep -q "untrusted" "$REPO/$f"; then
        ok "$f mentions untrusted content"
    else
        fail "$f missing 'untrusted' keyword"
    fi
    if grep -q "MY_EMAIL" "$REPO/$f" && grep -q "never send.*outside\|only.*MY_EMAIL\|attendee" "$REPO/$f"; then
        ok "$f has email-scope guard"
    else
        fail "$f missing email-scope guard"
    fi
done

echo ""
echo "=== Task 2: Version-bump TCC unstick ==="
if grep -q "claude-tcc-unstick" "$REPO/scripts/scheduler.sh"; then
    ok "scheduler.sh calls claude-tcc-unstick"
else
    fail "scheduler.sh does not call claude-tcc-unstick"
fi
if grep -q "Version bump: running TCC cleanup" "$REPO/scripts/scheduler.sh"; then
    ok "scheduler.sh logs TCC cleanup on version bump"
else
    fail "scheduler.sh missing TCC cleanup log message"
fi
# Verify old "Click Allow" prompt is gone from version-bump message
if grep -q "Click Allow when it appears" "$REPO/scripts/scheduler.sh"; then
    fail "scheduler.sh still has stale 'Click Allow' instruction"
else
    ok "scheduler.sh does not contain stale 'Click Allow' instruction"
fi

echo ""
echo "=== Task 3: Weekly health summary (email since 2026-10-20) ==="
if grep -q "^send_weekly_health()" "$REPO/scripts/scheduler.sh"; then
    ok "scheduler.sh defines send_weekly_health"
else
    fail "scheduler.sh missing send_weekly_health"
fi
# The Slack-only summary was silently dropped for months while Slack was off.
if sed -n '/^send_weekly_health()/,/^}/p' "$REPO/scripts/scheduler.sh" | grep -q 'send_email' \
   && ! sed -n '/^send_weekly_health()/,/^}/p' "$REPO/scripts/scheduler.sh" | grep -q 'SLACK_WEBHOOK'; then
    ok "weekly summary is emailed and does not depend on Slack"
else
    fail "weekly summary must go through send_email, not Slack"
fi
if grep -A1 'WEEKLY_EMAIL_SENTINEL" 2>/dev/null)" \]; then' "$REPO/scripts/scheduler.sh" | grep -q "send_weekly_health"; then
    ok "send_weekly_health runs under the Monday sentinel guard"
else
    fail "send_weekly_health not wired to the Monday guard"
fi

echo ""
echo "=== Task 4: Cycle plan gate + ATTENTION channel (2026-10-20) ==="
if grep -q "python3 -m briefings_mcp.cycle_plan --calendar-env CAL_DATA --apply" "$REPO/scripts/scheduler.sh"; then
    ok "pre-flight gate runs briefings_mcp.cycle_plan"
else
    fail "pre-flight gate does not run the cycle plan"
fi
if grep -q "any('-awaiting-' in f" "$REPO/scripts/scheduler.sh"; then
    fail "old gate still wakes Claude for every awaiting file"
else
    ok "old wake-on-any-awaiting-file rule is gone"
fi
if grep -q '\.notify_dedup_venv-broken|.notify_dedup_auto-expiry-failed|.notify_dedup_cycle-plan) continue' "$REPO/scripts/scheduler.sh"; then
    ok "cycle-plan alert marker survives the success sweep (no 15-min flood)"
else
    fail "cycle-plan alert marker would be cleared by every fallback Claude run"
fi
if grep -q 'notify_attention "\$label" "\$output"' "$REPO/scripts/scheduler.sh" && grep -q "starting with ATTENTION:" "$REPO/scripts/scheduler.sh"; then
    ok "headless output is scanned for ATTENTION lines and the prompt asks for them"
else
    fail "ATTENTION channel not wired"
fi

if grep -q 'in:sent after:YYYY/MM/DD <keywords> -to:me' "$REPO/commands/digest.md" && ! grep -q 'keywords> -subject:' "$REPO/commands/digest.md"; then
    ok "digest done-detection excludes all self-sent system mail with -to:me"
else
    fail "digest done-detection would read the tool's own emails back as done evidence"
fi

if grep -q 'do not raise ATTENTION about Slack' "$REPO/scripts/scheduler.sh"; then
    ok "headless prompt tells runs not to flag the deliberately disabled Slack"
else
    fail "headless runs will email an ATTENTION about Slack every week"
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
