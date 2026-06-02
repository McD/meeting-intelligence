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
echo "=== Task 3: Weekly health summary ==="
if grep -q "generate_health_summary" "$REPO/scripts/scheduler.sh"; then
    ok "scheduler.sh defines generate_health_summary"
else
    fail "scheduler.sh missing generate_health_summary"
fi
if grep -A5 'date +%u.*= "1"' "$REPO/scripts/scheduler.sh" | grep -q "generate_health_summary"; then
    ok "generate_health_summary called in Monday cleanup block"
else
    fail "generate_health_summary not called in Monday cleanup block"
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
