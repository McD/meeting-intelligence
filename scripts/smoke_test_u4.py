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
import threading
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
        "owner": attendees[0] if attendees else "you@example.com",
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
            _make_decision("Acme pricing memo finalised", ["alice@acme.com", "you@example.com"], ["pricing", "acme"], days_ago=10),
            _make_decision("Acme tier pricing approved",  ["bob@acme.com",   "you@example.com"], ["pricing"],         days_ago=8),
            _make_commitment("Send pricing draft to Acme", ["you@example.com"],                  ["pricing"],         state="open",     days_ago=6),
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
        check("owner has 3 entries", counts.get("you@example.com") == 3, f"got {counts.get('you@example.com')}")
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

        section("Calls from more than one thread")
        # fastmcp runs sync tools on anyio worker threads, and a worker retires after ~10s
        # idle, so consecutive tool calls routinely arrive on different threads. Each call
        # below runs on a fresh thread after the main thread has already warmed the cache.
        index_module.reset_cache()
        _ = query.search_decisions()
        thread_results: list = []

        def _call_in_new_thread(fn, *args) -> None:
            def run() -> None:
                try:
                    thread_results.append(("ok", fn(*args)))
                except Exception as exc:  # noqa: BLE001 — record any failure for the check
                    thread_results.append(("error", f"{type(exc).__name__}: {exc}"))
            t = threading.Thread(target=run)
            t.start()
            t.join()

        _call_in_new_thread(query.search_decisions)
        _call_in_new_thread(query.get_decision_by_id, known["id"])
        _call_in_new_thread(query.list_attendees)
        errors = [r[1] for r in thread_results if r[0] == "error"]
        check("tool calls on other threads raise no errors", not errors, errors[0] if errors else "")
        if not errors:
            check("search from another thread returns every entry", len(thread_results[0][1]) == second_count, f"got {len(thread_results[0][1])}")
            check("get_decision_by_id from another thread round-trips", thread_results[1][1]["id"] == known["id"])
            check("list_attendees from another thread matches main thread", thread_results[2][1] == query.list_attendees())

        # mtime invalidation triggered from a worker thread must close/replace the cached
        # connection without tripping the same-thread check, and the new row must show up.
        time.sleep(0.05)
        ledger.append(_make_decision("Threaded pricing decision", ["dave@acme.com"], ["pricing"], days_ago=0))
        second_count += 1
        thread_results.clear()
        _call_in_new_thread(query.search_decisions)
        status, payload = thread_results[0]
        check("mtime invalidation works from another thread", status == "ok" and len(payload) == second_count, str(payload)[:200] if status == "error" else f"got {len(payload)}")

        # The lock must serialise queries against invalidation: while one thread holds the
        # connection, a search on another thread waits, then sees the ledger as it is after
        # the holder finishes rather than reading from a connection being closed under it.
        thread_results.clear()
        with index_module.connection():
            waiter = threading.Thread(target=lambda: thread_results.append(len(query.search_decisions())))
            waiter.start()
            waiter.join(timeout=0.3)
            check("search on another thread waits while the connection is held", waiter.is_alive() and thread_results == [])
            time.sleep(0.05)
            ledger.append(_make_decision("Locked-window decision", ["erin@acme.com"], ["pricing"], days_ago=0))
            second_count += 1
        waiter.join()
        check("waiting search returns the post-append count", thread_results == [second_count], f"got {thread_results}")

        # Concurrent calls: several threads hitting the index at once.
        thread_results.clear()
        workers = [threading.Thread(target=lambda: thread_results.append(len(query.search_decisions()))) for _ in range(8)]
        for w in workers:
            w.start()
        for w in workers:
            w.join()
        check("8 concurrent searches all succeed", thread_results == [second_count] * 8, f"got {thread_results}")

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

        section("Disk cache freshness")
        # reset_cache() stands in for a server restart: the next call must decide whether
        # decisions.db still matches decisions.jsonl.
        jsonl_path = ledger.LEDGER_PATH
        index_module.reset_cache()
        baseline = len(query.search_decisions(limit=500))
        backup = tmpdir / "decisions.jsonl.bak"
        shutil.copy2(jsonl_path, backup)  # keeps the older mtime, like a backup restore
        time.sleep(0.05)
        ledger.append(_make_decision("Entry the restore removes", ["frank@acme.com"], ["pricing"], days_ago=0))
        check("append is visible before restore", len(query.search_decisions(limit=500)) == baseline + 1)
        shutil.copy2(backup, jsonl_path)
        index_module.reset_cache()
        restored = len(query.search_decisions(limit=500))
        check("restoring an older JSONL is not masked by a newer decisions.db", restored == baseline, f"got {restored}, expected {baseline}")

        # An append that lands while a rebuild is reading the JSONL leaves a decisions.db
        # written after the append but missing it. After a restart it must not be reused.
        index_module.reset_cache()
        time.sleep(0.05)
        os.utime(jsonl_path)  # force the next call to rebuild rather than load from disk
        real_populate = index_module._populate_from_jsonl
        racing_entry = _make_decision("Appended mid-rebuild", ["gina@acme.com"], ["pricing"], days_ago=0)

        def populate_then_append(conn):
            n = real_populate(conn)
            time.sleep(0.05)
            ledger.append(racing_entry)
            return n

        index_module._populate_from_jsonl = populate_then_append
        try:
            _ = query.search_decisions(limit=500)
        finally:
            index_module._populate_from_jsonl = real_populate
        index_module.reset_cache()
        check(
            "entry appended during a rebuild is visible after restart",
            query.get_decision_by_id(racing_entry["id"]) is not None,
        )

        # The flip side: when nothing changed, a restart must load decisions.db rather than
        # rebuild, or cold starts lose the fast path the disk cache exists for.
        rebuilds = []

        def counting_populate(conn):
            rebuilds.append(1)
            return real_populate(conn)

        index_module._populate_from_jsonl = counting_populate
        try:
            index_module.reset_cache()
            first = query.search_decisions(limit=500)
            index_module.reset_cache()
            second = query.search_decisions(limit=500)
        finally:
            index_module._populate_from_jsonl = real_populate
        check("restart with an unchanged JSONL reuses decisions.db", rebuilds == [] and first == second, f"rebuilds={len(rebuilds)}")

        # Each server process (one per Claude session) persists the cache; one must not
        # delete or replace another's in-flight temp file.
        other_tmp = index_module.DB_PATH.with_suffix(".db.tmp")
        other_tmp.write_bytes(b"another process's half-written cache")
        time.sleep(0.05)
        os.utime(jsonl_path)
        index_module.reset_cache()
        _ = query.search_decisions()
        check(
            "persisting leaves another process's temp file alone",
            other_tmp.exists() and other_tmp.read_bytes() == b"another process's half-written cache",
        )
        leftovers = sorted(p.name for p in tmpdir.glob("decisions.db.*tmp") if p != other_tmp)
        check("persisting leaves no temp file of its own behind", leftovers == [], f"found {leftovers}")

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
