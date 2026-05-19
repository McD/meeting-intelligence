"""U4 smoke test: exercises the MCP server's three tools end-to-end against a tmpdir ledger.

Run with: .venv/bin/python scripts/smoke_test_u4.py

Covers the plan's U4 test scenarios:
  * AE6 happy: topic filter, type filter
  * get_decision_by_id known + unknown
  * list_attendees ordering
  * Empty ledger
  * mtime-based invalidation
  * Corrupted SQLite cache → rebuild

Stdio-clean boot is verified separately by scripts/smoke_test_u4_boot.sh.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
import uuid
from datetime import date, datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import index as index_module
from briefings_mcp import ledger, query


def _redirect_ledger_to(tmpdir: Path) -> None:
    """Point ledger + index at an isolated tmpdir for testing. Real ~/.briefings is untouched."""
    ledger.LEDGER_DIR = tmpdir
    ledger.LEDGER_PATH = tmpdir / "decisions.jsonl"
    index_module.DB_PATH = tmpdir / "decisions.db"
    index_module.reset_cache()


def _now_iso(offset_days: int = 0) -> str:
    dt = datetime.now(timezone.utc)
    if offset_days:
        from datetime import timedelta
        dt = dt + timedelta(days=offset_days)
    return dt.isoformat()


def _make_decision(summary: str, attendees: list[str], topics: list[str], days_ago: int = 0) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "created_at": _now_iso(-days_ago),
        "type": "decision",
        "summary": summary,
        "attendees": attendees,
        "topics": topics,
        "source_meeting": f"meeting-{summary[:20]}",
        "why": "",
        "why_notes": "",
        "resolved": False,
    }


def _make_commitment(summary: str, attendees: list[str], topics: list[str], state: str, days_ago: int = 0) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "created_at": _now_iso(-days_ago),
        "type": "commitment",
        "summary": summary,
        "attendees": attendees,
        "topics": topics,
        "source_meeting": f"meeting-{summary[:20]}",
        "why": "",
        "why_notes": "",
        "owner": attendees[0] if attendees else "mark@screencloud.io",
        "due": _now_iso(7),
        "state": state,
    }


_results: list[tuple[str, bool, str]] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    _results.append((name, condition, detail))
    marker = "PASS" if condition else "FAIL"
    line = f"  [{marker}] {name}"
    if detail:
        line += f" — {detail}"
    print(line)


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        _redirect_ledger_to(tmpdir)

        section("Empty ledger")
        check("search returns [] on empty ledger", query.search_decisions() == [], "")
        check("list_attendees returns [] on empty ledger", query.list_attendees() == [], "")
        check("get_decision_by_id('missing') returns None", query.get_decision_by_id("missing") is None)

        section("AE6: append five pricing entries; topic + type filters")
        index_module.reset_cache()
        entries = [
            _make_decision("Acme pricing memo finalised", ["alice@acme.com", "mark@screencloud.io"], ["pricing", "acme"], days_ago=10),
            _make_decision("Acme tier pricing approved",  ["bob@acme.com",   "mark@screencloud.io"], ["pricing"],         days_ago=8),
            _make_commitment("Send pricing draft to Acme", ["mark@screencloud.io"],                  ["pricing"],         state="open",     days_ago=6),
            _make_commitment("Follow up on pricing call",  ["alice@acme.com"],                       ["pricing"],         state="in-flight", days_ago=4),
            _make_commitment("Close pricing thread",       ["alice@acme.com"],                       ["pricing", "close"], state="done",    days_ago=2),
        ]
        for e in entries:
            ledger.append(e)

        topic_hits = query.search_decisions(topic="pricing", date_from="2026-02-19")
        check("AE6: topic='pricing' returns 5", len(topic_hits) == 5, f"got {len(topic_hits)}")

        commitments = query.search_decisions(topic="pricing", type="commitment")
        check("AE6: type='commitment' narrows to 3", len(commitments) == 3, f"got {len(commitments)}")
        check("AE6: all returned commitments have type=commitment", all(c["type"] == "commitment" for c in commitments))

        section("get_decision_by_id")
        known = entries[2]
        fetched = query.get_decision_by_id(known["id"])
        check("known id round-trips", fetched is not None and fetched["id"] == known["id"], "")
        check("unknown id returns None", query.get_decision_by_id(str(uuid.uuid4())) is None)
        check("empty id returns None", query.get_decision_by_id("") is None)

        section("list_attendees ordering")
        attendees = query.list_attendees()
        emails = [a["attendee"] for a in attendees]
        counts = {a["attendee"]: a["entry_count"] for a in attendees}
        check("alice@acme.com appears", "alice@acme.com" in counts, f"counts={counts}")
        check("alice has 3 entries", counts.get("alice@acme.com") == 3, f"got {counts.get('alice@acme.com')}")
        check("mark has 3 entries", counts.get("mark@screencloud.io") == 3, f"got {counts.get('mark@screencloud.io')}")
        check(
            "ordering is by entry_count desc",
            all(attendees[i]["entry_count"] >= attendees[i + 1]["entry_count"] for i in range(len(attendees) - 1)),
        )

        section("State filter")
        open_only = query.search_decisions(state="open")
        check("state='open' returns 1 entry", len(open_only) == 1, f"got {len(open_only)}")
        check("state='done' returns 1 entry", len(query.search_decisions(state="done")) == 1)

        section("State + type filter (intersection)")
        check(
            "type=decision + state=open returns 0 (decisions have no state)",
            len(query.search_decisions(type="decision", state="open")) == 0,
        )

        section("Attendee substring filter")
        acme = query.search_decisions(attendee="acme.com")
        check("attendee substring 'acme.com' returns 4", len(acme) == 4, f"got {len(acme)}")

        section("Limit clamp")
        topped = query.search_decisions(limit=2)
        check("limit=2 returns at most 2", len(topped) <= 2, f"got {len(topped)}")

        section("mtime invalidation")
        first_count = len(query.search_decisions())
        # Ensure the new append produces a strictly greater mtime than the cached read.
        time.sleep(0.05)
        ledger.append(_make_decision("New pricing decision", ["carol@acme.com"], ["pricing"], days_ago=0))
        second_count = len(query.search_decisions())
        check("post-append result count increases", second_count == first_count + 1, f"{first_count} -> {second_count}")

        section("Corrupted SQLite cache rebuild")
        # Force a clean persist so DB_PATH exists.
        index_module.reset_cache()
        _ = query.search_decisions()
        db_path = index_module.DB_PATH
        check("DB cache file written", db_path.exists())
        # Corrupt the file: write garbage.
        db_path.write_bytes(b"this is not a sqlite database")
        index_module.reset_cache()
        # Bump JSONL mtime so the corrupt-disk path is exercised (jsonl_mtime > disk_mtime
        # would otherwise rebuild from JSONL before touching disk).
        os.utime(db_path, (db_path.stat().st_atime, db_path.stat().st_mtime + 60))
        # Now JSONL is older than corrupt DB → loader will try disk, hit corruption, fall
        # back to JSONL rebuild.
        recovered = query.search_decisions()
        check("recovered from corrupt cache", len(recovered) == second_count, f"recovered {len(recovered)}, expected {second_count}")

    print()
    failed = [r for r in _results if not r[1]]
    print(f"=== {len(_results) - len(failed)}/{len(_results)} passed ===")
    if failed:
        print("FAILED:")
        for name, _, detail in failed:
            print(f"  - {name}: {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
