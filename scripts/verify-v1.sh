#!/bin/bash
# meeting-intelligence — v1 smoke / verification harness
#
# Two halves:
#   * Automated (default): file-system + package-import + MCP-registration +
#     unit smoke tests (smoke_test_u3.py, smoke_test_u4.py, smoke_test_u4_boot.sh)
#     + an in-process MCP query roundtrip against a TEMP ledger so the real
#     ~/.briefings/decisions.jsonl is never mutated. Exits 0 on all-pass, 1
#     on any failure.
#   * Manual (--with-email): sends a real test follow-up to $MY_EMAIL with
#     reply-back instructions exercising U3's why-capture path. Skipped by
#     default so the script can be re-run cheaply.
#
# Format mirrors scripts/smoke_test_u3.py: PASS/FAIL per step, totals at end.
#
# Usage:
#   bash scripts/verify-v1.sh             # automated only
#   bash scripts/verify-v1.sh --with-email # also send a test follow-up

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
FAILED_STEPS=()

pass()    { echo -e "  [${GREEN}PASS${NC}] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { echo -e "  [${RED}FAIL${NC}] $1${2:+ — $2}"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_STEPS+=("$1"); }
section() { echo ""; echo -e "${BOLD}# $1${NC}"; }
info()    { echo -e "  ${BOLD}→${NC} $1"; }
warn()    { echo -e "  ${YELLOW}!${NC} $1"; }

WITH_EMAIL=0
WITH_BRIEFING=0
WITH_FOLLOWUP=0
for arg in "$@"; do
    case "$arg" in
        --with-email)    WITH_EMAIL=1 ;;
        --with-briefing) WITH_BRIEFING=1 ;;
        --with-followup) WITH_FOLLOWUP=1 ;;
        --help|-h)
            echo "Usage: $0 [--with-briefing] [--with-followup] [--with-email]"
            echo "  --with-briefing   Also force-regenerate the next briefing and assert SITREP shape"
            echo "  --with-followup   Also force-regenerate the latest follow-up and assert Phase 1 shape"
            echo "  --with-email      Also send a manual follow-up reply test"
            exit 0
            ;;
        *) warn "Unknown arg: $arg" ;;
    esac
done

VENV_DIR="$HOME/.briefings/venv"
RUNTIME_PY="$VENV_DIR/bin/python"
DEV_PY="$SCRIPT_DIR/.venv/bin/python"
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"

# ── 1. File-system layout ────────────────────────────────────────────────────
section "1. File-system layout"

if [ -d "$HOME/.briefings" ]; then
    mode=$(stat -f '%Lp' "$HOME/.briefings" 2>/dev/null || stat -c '%a' "$HOME/.briefings" 2>/dev/null)
    if [ "$mode" = "700" ]; then
        pass "~/.briefings directory exists with mode 700"
    else
        fail "~/.briefings mode" "expected 700, got $mode"
    fi
else
    fail "~/.briefings directory exists" "not found — run install.sh"
fi

if [ -f "$HOME/.briefings/decisions.jsonl" ]; then
    mode=$(stat -f '%Lp' "$HOME/.briefings/decisions.jsonl" 2>/dev/null || stat -c '%a' "$HOME/.briefings/decisions.jsonl" 2>/dev/null)
    if [ "$mode" = "600" ]; then
        pass "decisions.jsonl exists with mode 600"
    else
        fail "decisions.jsonl mode" "expected 600, got $mode"
    fi
else
    fail "decisions.jsonl exists" "not found — run install.sh"
fi

if [ -f "$HOME/.briefings_config" ]; then
    if grep -q '^LOOKBACK_DAYS=' "$HOME/.briefings_config"; then
        lb=$(grep '^LOOKBACK_DAYS=' "$HOME/.briefings_config" | cut -d= -f2)
        pass "~/.briefings_config has LOOKBACK_DAYS=$lb"
    else
        fail "LOOKBACK_DAYS in ~/.briefings_config" "missing"
    fi
else
    fail "~/.briefings_config exists" "not found"
fi

# ── 2. Runtime Python venv + package import ──────────────────────────────────
section "2. Runtime venv and package import"

if [ -x "$RUNTIME_PY" ]; then
    py_version=$("$RUNTIME_PY" --version 2>&1)
    pass "Runtime venv exists at $VENV_DIR ($py_version)"
else
    fail "Runtime venv" "$RUNTIME_PY missing — run install.sh"
fi

if [ -x "$RUNTIME_PY" ]; then
    if "$RUNTIME_PY" -c 'import briefings_mcp' 2>/dev/null; then
        pass "briefings_mcp importable from runtime venv"
    else
        fail "briefings_mcp import" "not installed in runtime venv"
    fi

    if "$RUNTIME_PY" -c 'import fastmcp' 2>/dev/null; then
        fm_version=$("$RUNTIME_PY" -c 'import fastmcp; print(fastmcp.__version__)' 2>/dev/null || echo "?")
        pass "fastmcp importable (version $fm_version)"
    else
        fail "fastmcp import" "not installed in runtime venv"
    fi
fi

# ── 3. MCP server registration ──────────────────────────────────────────────
section "3. MCP server registration"

if command -v claude >/dev/null 2>&1 || [ -x "$CLAUDE_BIN" ]; then
    if "$CLAUDE_BIN" mcp list 2>/dev/null | grep -qE '^briefings:'; then
        pass "claude mcp list shows briefings"
    else
        fail "MCP registration" "briefings not in 'claude mcp list' — run install.sh"
    fi
else
    fail "claude CLI" "not found at $CLAUDE_BIN"
fi

# ── 4. U3 smoke test (parser + ledger interaction) ──────────────────────────
section "4. U3 smoke test (why-capture parser)"

# Prefer the project .venv for tests since it's the dev environment; fall back
# to runtime venv if a user runs verify-v1 from a fresh clone.
TEST_PY=""
if [ -x "$DEV_PY" ]; then
    TEST_PY="$DEV_PY"
elif [ -x "$RUNTIME_PY" ]; then
    TEST_PY="$RUNTIME_PY"
fi

if [ -n "$TEST_PY" ]; then
    if "$TEST_PY" "$SCRIPT_DIR/scripts/smoke_test_u3.py" >/tmp/u3_smoke.out 2>&1; then
        pass "smoke_test_u3.py — all assertions pass"
    else
        fail "smoke_test_u3.py" "see /tmp/u3_smoke.out"
        tail -20 /tmp/u3_smoke.out | sed 's/^/      /'
    fi
else
    fail "smoke_test_u3.py" "no Python venv available"
fi

# ── 5. U4 smoke test (MCP query module in-process) ──────────────────────────
section "5. U4 smoke test (MCP query module)"

if [ -n "$TEST_PY" ]; then
    if "$TEST_PY" "$SCRIPT_DIR/scripts/smoke_test_u4.py" >/tmp/u4_smoke.out 2>&1; then
        pass "smoke_test_u4.py — all assertions pass"
    else
        fail "smoke_test_u4.py" "see /tmp/u4_smoke.out"
        tail -20 /tmp/u4_smoke.out | sed 's/^/      /'
    fi
else
    fail "smoke_test_u4.py" "no Python venv available"
fi

# ── 6. U4 stdio boot test (FastMCP JSON-RPC protocol cleanliness) ───────────
section "6. U4 stdio boot test (MCP protocol stays clean)"

# smoke_test_u4_boot.sh expects .venv/bin/python by convention. Skip with a
# warning if the dev venv isn't provisioned — a real user won't have it.
if [ -x "$DEV_PY" ]; then
    if bash "$SCRIPT_DIR/scripts/smoke_test_u4_boot.sh" >/tmp/u4_boot.out 2>&1; then
        pass "smoke_test_u4_boot.sh — stdio + tools/list clean"
    else
        fail "smoke_test_u4_boot.sh" "see /tmp/u4_boot.out"
        tail -20 /tmp/u4_boot.out | sed 's/^/      /'
    fi
else
    warn "Dev venv ($DEV_PY) missing — skipping stdio boot test."
    warn "  This is normal for a fresh user install; the test is dev-only."
fi

# ── 7. End-to-end MCP-query roundtrip against a fixture ledger ──────────────
section "7. MCP-query roundtrip against fixture ledger"

# Exercise the three MCP tools end-to-end without touching real ~/.briefings.
# Uses an isolated tmpdir so re-runs are deterministic.
if [ -n "$TEST_PY" ]; then
    if "$TEST_PY" - <<'PYEOF' >/tmp/u6_e2e.out 2>&1
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, ".")

from briefings_mcp import index as index_module
from briefings_mcp import ledger, query


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def make_entry(kind: str, summary: str, attendees: list, topics: list, **extra) -> dict:
    base = {
        "id": str(uuid.uuid4()),
        "created_at": now_iso(),
        "type": kind,
        "summary": summary,
        "attendees": attendees,
        "topics": topics,
        "source_meeting": "fixture",
        "why": "",
        "why_notes": "",
    }
    if kind == "commitment":
        base.setdefault("owner", attendees[0] if attendees else "mark@screencloud.io")
        base.setdefault("due", None)
        base.setdefault("state", "open")
    else:
        base.setdefault("resolved", False)
    base.update(extra)
    return base


with tempfile.TemporaryDirectory(prefix="v1-verify-") as raw:
    tmp = Path(raw)
    ledger.LEDGER_DIR = tmp
    ledger.LEDGER_PATH = tmp / "decisions.jsonl"
    index_module.DB_PATH = tmp / "decisions.db"
    index_module.reset_cache()

    e1 = make_entry("decision",   "v1 fixture decision",   ["alice@vendor.com"], ["v1-fixture", "pricing"])
    e2 = make_entry("commitment", "v1 fixture commitment", ["alice@vendor.com"], ["v1-fixture"], state="open")
    e3 = make_entry("commitment", "Other topic commitment", ["bob@vendor.com"],   ["unrelated"], state="done")
    for e in (e1, e2, e3):
        ledger.append(e)

    # Tool 1: search_decisions topic filter
    by_topic = query.search_decisions(topic="v1-fixture")
    assert len(by_topic) == 2, f"search_decisions topic=v1-fixture returned {len(by_topic)}, expected 2"

    # Tool 1: search_decisions type filter
    only_commit = query.search_decisions(topic="v1-fixture", type="commitment")
    assert len(only_commit) == 1, f"search_decisions type=commitment returned {len(only_commit)}, expected 1"

    # Tool 2: get_decision_by_id known + unknown
    fetched = query.get_decision_by_id(e1["id"])
    assert fetched is not None and fetched["id"] == e1["id"], "get_decision_by_id miss for known id"
    missing = query.get_decision_by_id(str(uuid.uuid4()))
    assert missing is None, "get_decision_by_id should return None for unknown id"

    # Tool 3: list_attendees count-desc ordering
    attendees = query.list_attendees()
    by_email = {a["attendee"]: a["entry_count"] for a in attendees}
    assert by_email.get("alice@vendor.com") == 2, f"alice expected 2 entries, got {by_email.get('alice@vendor.com')}"
    assert by_email.get("bob@vendor.com") == 1,   f"bob expected 1 entry, got {by_email.get('bob@vendor.com')}"
    for i in range(len(attendees) - 1):
        assert attendees[i]["entry_count"] >= attendees[i + 1]["entry_count"], "list_attendees not in entry_count desc order"

    print("ALL_OK")
PYEOF
    then
        if grep -q 'ALL_OK' /tmp/u6_e2e.out; then
            pass "Three MCP tools return expected results on fixture ledger"
        else
            fail "MCP-query roundtrip" "no ALL_OK marker in output"
            tail -10 /tmp/u6_e2e.out | sed 's/^/      /'
        fi
    else
        fail "MCP-query roundtrip" "Python error — see /tmp/u6_e2e.out"
        tail -20 /tmp/u6_e2e.out | sed 's/^/      /'
    fi
else
    fail "MCP-query roundtrip" "no Python venv available"
fi

# ── 8. Manual half: generate a real briefing and assert SITREP shape ────────
# Gated by --with-briefing because it requires a `claude -p` call (network +
# API spend + 1–3 minutes) and a calendar with an upcoming meeting in the
# next 2 hours. The automated half above can't cover this because briefings
# are Claude-generated.
if [ "$WITH_BRIEFING" -eq 1 ]; then
    section "8. Manual: regenerate next briefing and assert SITREP shape"

    if ! command -v claude >/dev/null 2>&1 && [ ! -x "$CLAUDE_BIN" ]; then
        fail "claude CLI" "not found at $CLAUDE_BIN — cannot run /briefing"
    else
        # Track the latest briefing file's mtime so we can detect whether
        # /briefing actually wrote something new.
        latest_before=""
        before_mtime=0
        if compgen -G "$HOME/Briefings/*.md" >/dev/null; then
            latest_before=$(ls -t "$HOME"/Briefings/*.md 2>/dev/null \
                | grep -vE 'followup|awaiting|scheduler' | head -1 || true)
            if [ -n "$latest_before" ] && [ -f "$latest_before" ]; then
                before_mtime=$(stat -f '%m' "$latest_before" 2>/dev/null \
                    || stat -c '%Y' "$latest_before" 2>/dev/null || echo 0)
            fi
        fi

        info "Running /briefing (this can take 1–3 minutes)..."
        # Force regenerate so the assertion exercises the CURRENT briefing
        # rendering rather than a possibly-stale on-disk file.
        claude_out=$("$CLAUDE_BIN" -p --dangerously-skip-permissions \
            "/briefing — force regenerate the next upcoming meeting's briefing, replacing the existing file if one exists. We need to validate the SITREP shape." \
            < /dev/null 2>&1) || true

        latest=$(ls -t "$HOME"/Briefings/*.md 2>/dev/null \
            | grep -vE 'followup|awaiting|scheduler' | head -1 || true)

        if [ -z "$latest" ] || [ ! -f "$latest" ]; then
            fail "/briefing produced no file" "no upcoming meeting on calendar, or claude refused"
            echo "$claude_out" | tail -8 | sed 's/^/      /'
        else
            current_mtime=$(stat -f '%m' "$latest" 2>/dev/null \
                || stat -c '%Y' "$latest" 2>/dev/null || echo 0)
            if [ "$current_mtime" -le "$before_mtime" ]; then
                warn "Latest briefing mtime unchanged — claude may have skipped regeneration."
                warn "  Asserting on existing file: $(basename "$latest")"
            else
                info "Fresh briefing written: $(basename "$latest")"
            fi

            # Verdict word set is closed (commands/briefing.md). Anything outside
            # this set is a regression that breaks the high-stakes filter in
            # commands/follow-up.md Step 4 which reads the verdict word back.
            verdict_re='^# (DECIDE-TODAY|DELEGATE|DEFER|DECLINE|PREP-HARD|LOW-STAKES|MOVE-ASYNC) — '
            if grep -qE "$verdict_re" "$latest"; then
                verdict=$(grep -E -m1 -o "$verdict_re" "$latest" 2>/dev/null \
                    | awk '{print $2}')
                pass "Verdict heading from closed set ($verdict)"
            else
                fail "Verdict heading" "no '# <VERDICT> — ' from closed set in $(basename "$latest")"
                head -3 "$latest" | sed 's/^/      /'
            fi

            # SITREP block + the three always-on labels.
            for spec in \
                "SITREP block:^## SITREP" \
                "Trap label:^\\*\\*Trap:\\*\\*" \
                "Delta label:^\\*\\*Delta:\\*\\*" \
                "Comment label:^\\*\\*Comment:\\*\\*"; do
                label="${spec%%:*}"
                pattern="${spec#*:}"
                if grep -qE "$pattern" "$latest"; then
                    pass "$label present"
                else
                    fail "$label missing" "$(basename "$latest")"
                fi
            done

            # Counterparty is conditional (external/mixed meetings only). Don't
            # fail on its absence; the meeting may be internal-only. Report
            # which case we hit so a regression like "Counterparty rendered for
            # an internal meeting" is visible.
            if grep -qE '^\*\*Counterparty:\*\*' "$latest"; then
                info "Counterparty section present (meeting is external/mixed)"
                # If thin-data, the literal honesty label should appear.
                if grep -qF 'Limited counterparty signal' "$latest"; then
                    info "  Includes thin-data honesty label."
                fi
            else
                info "Counterparty section absent (meeting is internal-only)"
            fi
        fi
    fi
else
    section "8. Manual briefing test (skipped)"
    info "Re-run with --with-briefing to regenerate the next briefing and assert SITREP shape."
fi

# ── 9. Manual half: send a test follow-up email (gated by --with-email) ─────
if [ "$WITH_EMAIL" -eq 1 ]; then
    section "9. Manual: test follow-up email (U3 why-capture path)"

    MY_EMAIL=$(grep '^MY_EMAIL=' "$HOME/.briefings_config" 2>/dev/null | cut -d= -f2)
    if [ -z "$MY_EMAIL" ]; then
        fail "MY_EMAIL in ~/.briefings_config" "missing"
    elif ! command -v gws >/dev/null 2>&1; then
        fail "gws CLI" "not found — install via 'npm install -g @googleworkspace/cli'"
    else
        info "Sending a fixture follow-up to $MY_EMAIL..."
        body=$(cat <<'BODY'
This is a verify-v1.sh test message. Reply with the following two lines to exercise the why-capture path on the next scheduler cycle:

1: testing the why-capture loop end-to-end
2: confirming reply parsing strips quoted text correctly

The scheduler runs every 15 minutes. After replying, watch ~/Briefings/scheduler.log for the parse to flow through.
BODY
)
        if gws gmail +send --to "$MY_EMAIL" --subject "[verify-v1] why-capture test" --body "$body" >/dev/null 2>&1; then
            pass "Test follow-up sent to $MY_EMAIL"
            info "Reply with '1: <reason>' and '2: <reason>' to trigger U3."
            info "Note: this only exercises the email-send path; the actual why-capture"
            info "      polling runs on the scheduler against awaiting-why state files,"
            info "      which are created by /follow-up — not by this test."
        else
            fail "gws gmail +send" "send failed"
        fi
    fi
else
    section "9. Manual email test (skipped)"
    info "Re-run with --with-email to send a test follow-up to MY_EMAIL."
fi

# ── 10. Manual half: regenerate latest follow-up and assert Phase 1 shape ──
# Gated by --with-followup because it requires a `claude -p` call (network +
# API spend + 1–3 minutes). Mirrors --with-briefing pattern: pick the most
# recent follow-up, force-regenerate the same meeting, then grep the output
# for mandatory and conditional Phase 1 sections.
if [ "$WITH_FOLLOWUP" -eq 1 ]; then
    section "10. Manual: regenerate latest follow-up and assert shape"

    if ! command -v claude >/dev/null 2>&1 && [ ! -x "$CLAUDE_BIN" ]; then
        fail "claude CLI" "not found at $CLAUDE_BIN — cannot run /follow-up"
    else
        # Pick the most recent follow-up file (skip awaiting/scheduler).
        latest_fu=""
        if compgen -G "$HOME/Briefings/*followup*.md" >/dev/null; then
            latest_fu=$(ls -t "$HOME"/Briefings/*followup*.md 2>/dev/null \
                | grep -vE 'awaiting|scheduler' | head -1 || true)
        fi

        if [ -z "$latest_fu" ] || [ ! -f "$latest_fu" ]; then
            fail "Latest follow-up file" "no follow-up files in ~/Briefings/ — nothing to regenerate"
        else
            # Parse "# Follow-up: <Title>" from line 1. Skip if title contains a
            # double-quote (would break the prompt arg quoting) — extremely rare.
            meeting_title=$(head -1 "$latest_fu" | sed -E 's/^# Follow-up:[[:space:]]*//')
            if [ -z "$meeting_title" ] || printf '%s' "$meeting_title" | grep -q '"'; then
                fail "Parse meeting title" "first line of $(basename "$latest_fu") missing '# Follow-up: ' prefix or contains a quote"
            else
                before_mtime=$(stat -f '%m' "$latest_fu" 2>/dev/null \
                    || stat -c '%Y' "$latest_fu" 2>/dev/null || echo 0)

                info "Force-regenerating /follow-up for: $meeting_title"
                info "  (this can take 1–3 minutes)"
                claude_out=$("$CLAUDE_BIN" -p --dangerously-skip-permissions \
                    "/follow-up $meeting_title --force" \
                    < /dev/null 2>&1) || true

                current_mtime=$(stat -f '%m' "$latest_fu" 2>/dev/null \
                    || stat -c '%Y' "$latest_fu" 2>/dev/null || echo 0)
                if [ "$current_mtime" -le "$before_mtime" ]; then
                    warn "Follow-up mtime unchanged — claude may have skipped regeneration."
                    warn "  Asserting on existing file: $(basename "$latest_fu")"
                else
                    info "Fresh follow-up written: $(basename "$latest_fu")"
                fi

                # Mandatory shape — these always appear (punchy top + Step 5
                # template requires them). Failure here means a real regression.
                for spec in \
                    "Title line:^# Follow-up:" \
                    "Summary section:^## Summary" \
                    "Action items section:^## Action items" \
                    "Key decisions section:^## Key decisions"; do
                    label="${spec%%:*}"
                    pattern="${spec#*:}"
                    if grep -qE "$pattern" "$latest_fu"; then
                        pass "$label present"
                    else
                        fail "$label missing" "$(basename "$latest_fu")"
                    fi
                done

                # Phase 1 conditional sections — each is genuinely conditional
                # (internal meetings skip Counterparty read; a fully-resolved
                # meeting has no Open questions; a transcript pasted inline has
                # no Source). Report presence/absence; don't fail individually.
                for spec in \
                    "Notable threads:^## Notable threads" \
                    "Open questions:^## Open questions" \
                    "Counterparty read:^## Counterparty read" \
                    "Source:^## Source"; do
                    label="${spec%%:*}"
                    pattern="${spec#*:}"
                    if grep -qE "$pattern" "$latest_fu"; then
                        info "$label present"
                    else
                        info "$label absent (may be expected — section is conditional)"
                    fi
                done

                # Backstop: at least one Phase 1 section should appear in any
                # real production follow-up. All four absent means extraction
                # regressed or the file is stale (no regeneration happened).
                if grep -qE '^## (Notable threads|Open questions|Counterparty read|Source)' "$latest_fu"; then
                    pass "At least one Phase 1 conditional section appears"
                else
                    fail "All Phase 1 sections absent" \
                        "Notable threads / Open questions / Counterparty read / Source all missing in $(basename "$latest_fu")"
                fi
            fi
        fi
    fi
else
    section "10. Manual follow-up test (skipped)"
    info "Re-run with --with-followup to regenerate the latest follow-up and assert Phase 1 shape."
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
total=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}=== $PASS_COUNT/$total passed ===${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}=== $PASS_COUNT/$total passed, $FAIL_COUNT FAILED ===${NC}"
    echo "Failed steps:"
    for s in "${FAILED_STEPS[@]}"; do
        echo "  - $s"
    done
    exit 1
fi
