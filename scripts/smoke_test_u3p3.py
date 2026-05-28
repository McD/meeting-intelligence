#!/usr/bin/env python3
"""Smoke test for Phase 3 U1: briefings_mcp.ledger.update_commitment_state.

Exercises happy paths (every valid state), no-match, type rejection (decision entries are
not mutable), invalid state rejection, missing-ledger handling, and byte-identical
preservation of untouched lines.

Mirrors the shape of scripts/smoke_test_u4.py (Phase 1 U4 MCP query module): print PASS/FAIL
lines, exit 0 on all-pass.
"""

from __future__ import annotations

import json
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

# Ensure repo-root is importable when run directly from anywhere.
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import ledger, schema  # noqa: E402


PASS = 0
FAIL = 0


def check(label: str, condition: bool, extra: str = "") -> None:
    global PASS, FAIL
    if condition:
        print(f"  [PASS] {label}")
        PASS += 1
    else:
        print(f"  [FAIL] {label}{(' — ' + extra) if extra else ''}")
        FAIL += 1


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_commitment(summary: str, state: str = "open") -> dict:
    return {
        "id": str(uuid.uuid4()),
        "created_at": now_iso(),
        "type": "commitment",
        "summary": summary,
        "attendees": ["you@example.com"],
        "topics": ["fixture"],
        "source_meeting": "u3p3-smoke",
        "why": "",
        "why_notes": "",
        "owner": "You",
        "due": None,
        "state": state,
    }


def make_decision(summary: str) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "created_at": now_iso(),
        "type": "decision",
        "summary": summary,
        "attendees": ["you@example.com"],
        "topics": ["fixture"],
        "source_meeting": "u3p3-smoke",
        "why": "",
        "why_notes": "",
        "resolved": True,
    }


def read_all_entries() -> list[dict]:
    return list(ledger.iter_entries())


def read_raw_lines() -> list[str]:
    with open(ledger.LEDGER_PATH, "r", encoding="utf-8") as f:
        return f.readlines()


with tempfile.TemporaryDirectory(prefix="u3p3-smoke-") as raw:
    tmp = Path(raw)
    ledger.LEDGER_DIR = tmp
    ledger.LEDGER_PATH = tmp / "decisions.jsonl"

    # Seed: 1 decision + 3 commitments
    d1 = make_decision("Decision: ship Phase 3")
    c1 = make_commitment("Send pricing memo to Acme")
    c2 = make_commitment("Draft state-of-industry doc")
    c3 = make_commitment("Schedule Q3 offsite")
    for e in (d1, c1, c2, c3):
        ledger.append(e)

    # --- Happy path: open → done ---
    raw_before = read_raw_lines()
    ok = ledger.update_commitment_state(c1["id"], "done")
    check("c1 open→done returns True", ok is True)

    entries = read_all_entries()
    c1_now = next(e for e in entries if e["id"] == c1["id"])
    check("c1 state is now 'done'", c1_now["state"] == "done", f"got {c1_now['state']!r}")

    # --- Untouched entries preserved byte-identical ---
    raw_after = read_raw_lines()
    # d1, c2, c3 are at indices 0, 2, 3 in the original; c1 at index 1 changed.
    check("d1 line unchanged", raw_before[0] == raw_after[0])
    check("c2 line unchanged", raw_before[2] == raw_after[2])
    check("c3 line unchanged", raw_before[3] == raw_after[3])

    # --- Happy path: all four valid states ---
    for state in ("open", "in-flight", "done", "dropped"):
        ok = ledger.update_commitment_state(c2["id"], state)
        check(f"c2 → {state} returns True", ok is True)
        c2_now = next(e for e in read_all_entries() if e["id"] == c2["id"])
        check(f"c2 state is now {state!r}", c2_now["state"] == state)

    # --- Edge: no match returns False, ledger untouched ---
    raw_before = read_raw_lines()
    ok = ledger.update_commitment_state(str(uuid.uuid4()), "done")
    check("non-existent id returns False", ok is False)
    raw_after = read_raw_lines()
    check("ledger byte-identical after no-match", raw_before == raw_after)

    # --- Edge: decision entries are not mutable ---
    try:
        ledger.update_commitment_state(d1["id"], "done")
        check("decision entry raises SchemaError", False, "no exception raised")
    except schema.SchemaError as exc:
        check("decision entry raises SchemaError", "commitment" in str(exc))

    # --- Error: invalid state rejected ---
    try:
        ledger.update_commitment_state(c3["id"], "rejected")
        check("invalid state raises SchemaError", False, "no exception raised")
    except schema.SchemaError as exc:
        check("invalid state raises SchemaError", "rejected" in str(exc))

    # c3 untouched after the rejected update attempt
    c3_now = next(e for e in read_all_entries() if e["id"] == c3["id"])
    check("c3 state still 'open' after rejected update", c3_now["state"] == "open")


# --- Error: missing ledger file raises FileNotFoundError ---
with tempfile.TemporaryDirectory(prefix="u3p3-smoke-missing-") as raw:
    tmp = Path(raw)
    ledger.LEDGER_DIR = tmp
    ledger.LEDGER_PATH = tmp / "decisions.jsonl"
    try:
        ledger.update_commitment_state("anything", "done")
        check("missing ledger raises FileNotFoundError", False, "no exception raised")
    except FileNotFoundError:
        check("missing ledger raises FileNotFoundError", True)


print()
total = PASS + FAIL
if FAIL == 0:
    print(f"=== {PASS}/{total} passed ===")
    sys.exit(0)
else:
    print(f"=== {PASS}/{total} passed, {FAIL} FAILED ===")
    sys.exit(1)
