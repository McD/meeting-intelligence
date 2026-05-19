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
for arg in "$@"; do
    case "$arg" in
        --with-email) WITH_EMAIL=1 ;;
        --help|-h)
            echo "Usage: $0 [--with-email]"
            echo "  --with-email   Also send a manual follow-up reply test"
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

# ── 8. Manual half: send a test follow-up email (gated by --with-email) ─────
if [ "$WITH_EMAIL" -eq 1 ]; then
    section "8. Manual: test follow-up email (U3 why-capture path)"

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
    section "8. Manual email test (skipped)"
    info "Re-run with --with-email to send a test follow-up to MY_EMAIL."
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
