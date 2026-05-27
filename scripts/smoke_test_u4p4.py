#!/usr/bin/env python3
"""Smoke test for Phase 4: find_patterns + dedup-on-write + dedup_ledger.py.

Mirrors smoke_test_u3p3.py — PASS/FAIL lines, exit 0 on all-pass.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import ledger, query  # noqa: E402


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


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def make_commitment(
    summary: str,
    topics: list[str],
    attendees: list[str] = None,
    source_meeting: str = "u4p4-fixture",
    created_at: datetime | None = None,
    state: str = "open",
) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "created_at": iso(created_at or datetime.now(timezone.utc)),
        "type": "commitment",
        "summary": summary,
        "attendees": attendees or ["mark@screencloud.io"],
        "topics": topics,
        "source_meeting": source_meeting,
        "why": "",
        "why_notes": "",
        "owner": "You",
        "due": None,
        "state": state,
    }


# =============================================================================
# Part 1: find_patterns
# =============================================================================

print("\n# Part 1: find_patterns")

with tempfile.TemporaryDirectory(prefix="u4p4-find-") as raw:
    tmp = Path(raw)
    ledger.LEDGER_DIR = tmp
    ledger.LEDGER_PATH = tmp / "decisions.jsonl"

    # Seed: 5 pricing entries, 3 staffing, 1 random
    for i in range(5):
        ledger.append(make_commitment(f"pricing item {i}", ["pricing"]))
    for i in range(3):
        ledger.append(make_commitment(f"staffing item {i}", ["staffing"]))
    ledger.append(make_commitment("random item", ["one-off"]))

    # Happy path: default thresholds
    patterns = query.find_patterns(window_days=60, min_count=3, limit=3)
    by_topic = dict(patterns)
    check("pricing surfaces with count 5", by_topic.get("pricing") == 5,
          f"got {by_topic}")
    check("staffing surfaces with count 3", by_topic.get("staffing") == 3)
    check("one-off excluded (below threshold)", "one-off" not in by_topic)

    # Limit cap
    limited = query.find_patterns(window_days=60, min_count=1, limit=1)
    check("limit=1 caps at 1 result", len(limited) == 1)
    check("limit=1 returns the top by count", limited[0][0] == "pricing")

    # Empty window
    none = query.find_patterns(window_days=0)
    check("window_days=0 returns empty", none == [])

    # Attendee filter
    ledger.append(make_commitment(
        "Robert thing", ["pricing"], attendees=["robert@example.com"]
    ))
    by_robert = query.find_patterns(
        window_days=60, min_count=1, attendees=["robert@example.com"]
    )
    check("attendee filter scopes to Robert's pricing entry",
          dict(by_robert).get("pricing") == 1)

    # Types filter (decisions excluded when types=[commitment] — they always are here
    # because the fixture only has commitments. Sanity-check that explicit limiting works.
    # Count is 6 now: 5 original "pricing item N" + 1 Robert pricing item appended above.)
    by_type = query.find_patterns(window_days=60, min_count=3, types=["commitment"])
    check("types=commitment still finds pricing", dict(by_type).get("pricing") == 6)

    # Tie-break determinism — add another topic at exactly 3 to tie staffing
    for i in range(3):
        ledger.append(make_commitment(f"tied item {i}", ["aaa-topic"]))
    tied = query.find_patterns(window_days=60, min_count=3, limit=10)
    tied_dict = dict(tied)
    check("tied count 3 includes both staffing and aaa-topic",
          tied_dict.get("staffing") == 3 and tied_dict.get("aaa-topic") == 3)
    # Alphabetical tiebreak among count=3 → aaa-topic before staffing
    threes = [t for t, c in tied if c == 3]
    check("alphabetical tiebreak on ties", threes == sorted(threes))


# =============================================================================
# Part 2: dedup-on-write in ledger.append
# =============================================================================

print("\n# Part 2: dedup-on-write")

with tempfile.TemporaryDirectory(prefix="u4p4-dedup-") as raw:
    tmp = Path(raw)
    ledger.LEDGER_DIR = tmp
    ledger.LEDGER_PATH = tmp / "decisions.jsonl"

    c1 = make_commitment("Send pricing memo to Acme", ["pricing"])
    ledger.append(c1)
    check("first commitment writes", sum(1 for _ in ledger.iter_entries()) == 1)

    # Exact duplicate is silent-skipped
    c1_dup = make_commitment("Send pricing memo to Acme", ["pricing"])
    ledger.append(c1_dup)
    check("exact duplicate is skipped",
          sum(1 for _ in ledger.iter_entries()) == 1)

    # 60-char prefix match also skipped
    c1_prefix = make_commitment(
        "Send pricing memo to Acme Corporation by end of week", ["pricing"]
    )
    ledger.append(c1_prefix)
    check("60-char-prefix duplicate is skipped",
          sum(1 for _ in ledger.iter_entries()) == 1)

    # Different summary writes
    c2 = make_commitment("Schedule Q3 offsite", ["q3-plan"])
    ledger.append(c2)
    check("different summary writes", sum(1 for _ in ledger.iter_entries()) == 2)

    # Different source_meeting writes (same summary)
    c3 = make_commitment(
        "Send pricing memo to Acme", ["pricing"], source_meeting="different-meeting"
    )
    ledger.append(c3)
    check("same summary, different meeting writes",
          sum(1 for _ in ledger.iter_entries()) == 3)

    # Decisions are not deduped
    decision = {
        "id": str(uuid.uuid4()),
        "created_at": iso(datetime.now(timezone.utc)),
        "type": "decision",
        "summary": "We will ship Phase 4",
        "attendees": ["mark@screencloud.io"],
        "topics": ["roadmap"],
        "source_meeting": "u4p4-fixture",
        "why": "",
        "why_notes": "",
        "resolved": True,
    }
    ledger.append(decision)
    duplicate_decision = {**decision, "id": str(uuid.uuid4())}
    ledger.append(duplicate_decision)
    check("decisions are NOT deduped (both written)",
          sum(1 for _ in ledger.iter_entries()) == 5)


# =============================================================================
# Part 3: scripts/dedup_ledger.py (dry-run + apply)
# =============================================================================

print("\n# Part 3: dedup_ledger.py")

with tempfile.TemporaryDirectory(prefix="u4p4-cleanup-") as raw:
    tmp = Path(raw)
    fixture_path = tmp / "decisions.jsonl"

    # Hand-build a ledger with known duplicates (bypasses dedup-on-write).
    now = datetime.now(timezone.utc)
    entries = [
        make_commitment("Send pricing memo to Acme", ["pricing"],
                        created_at=now - timedelta(hours=3)),
        # Duplicate of the first — should be removed, earliest kept.
        make_commitment("Send pricing memo to Acme", ["pricing"],
                        created_at=now - timedelta(hours=2)),
        # Third copy with state=done — survives because state-rank wins over created_at.
        make_commitment("Send pricing memo to Acme", ["pricing"],
                        created_at=now - timedelta(hours=1), state="done"),
        # Unique entry.
        make_commitment("Schedule offsite", ["q3-plan"], created_at=now),
    ]
    with open(fixture_path, "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")

    script_path = REPO_ROOT / "scripts" / "dedup_ledger.py"

    # Dry-run: should report the duplicate cluster, not modify the file.
    result = subprocess.run(
        [sys.executable, str(script_path), "--path", str(fixture_path)],
        capture_output=True, text=True
    )
    check("dry-run exits 0", result.returncode == 0,
          f"stderr: {result.stderr}")
    check("dry-run reports 1 cluster", "1 duplicate cluster" in result.stdout)
    check("dry-run reports 2 entries to remove", "2 entries to remove" in result.stdout)
    check("dry-run does not modify the file",
          sum(1 for _ in open(fixture_path)) == 4)

    # Apply: should keep 2 entries (survivor + unique).
    result = subprocess.run(
        [sys.executable, str(script_path), "--apply", "--path", str(fixture_path)],
        capture_output=True, text=True
    )
    check("--apply exits 0", result.returncode == 0,
          f"stderr: {result.stderr}")
    check("--apply removed 2 entries", "Removed 2 entries" in result.stdout)

    kept = []
    with open(fixture_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            kept.append(json.loads(line))
    check("ledger now has 2 entries", len(kept) == 2)

    survivor_summaries = {k["summary"] for k in kept}
    check("survivor: 'Send pricing memo to Acme' kept",
          "Send pricing memo to Acme" in survivor_summaries)
    check("survivor: 'Schedule offsite' kept",
          "Schedule offsite" in survivor_summaries)

    pricing_survivor = next(k for k in kept if k["summary"] == "Send pricing memo to Acme")
    check("survivor of the cluster has state=done (state-rank tiebreak)",
          pricing_survivor["state"] == "done")


print()
total = PASS + FAIL
if FAIL == 0:
    print(f"=== {PASS}/{total} passed ===")
    sys.exit(0)
else:
    print(f"=== {PASS}/{total} passed, {FAIL} FAILED ===")
    sys.exit(1)
