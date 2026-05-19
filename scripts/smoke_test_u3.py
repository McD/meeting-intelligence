"""U3 smoke test: exercises the why-capture parser end-to-end against a tmpdir ledger.

Run with: .venv/bin/python scripts/smoke_test_u3.py

Covers the plan's U3 test scenarios:
  * AE5 happy: numbered reply lines update matching ledger entries' `why` fields
  * Quoted-only reply (`> 2: ...`) — no updates
  * Literal `1: skip` capture (no magic keyword)
  * Free-form prose appended to `why_notes` on last pending entry
  * Out-of-range index `999: ...` — warning, ignored, other valid lines processed
  * Idempotent re-parse of the same reply — `why` stays stable, `why_notes` not duplicated
  * `all_answered` flag flips to True only when every pending entry has a non-empty `why`

7-day expiry is bash-level (the awaiting-why file's created_at vs now) and is asserted
manually in commands/follow-up.md Step 0; this script focuses on parser correctness.
"""

from __future__ import annotations

import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import index as index_module
from briefings_mcp import ledger, why_capture


def _redirect_ledger_to(tmpdir: Path) -> None:
    """Point ledger + index at an isolated tmpdir for testing. Real ~/.briefings is untouched."""
    ledger.LEDGER_DIR = tmpdir
    ledger.LEDGER_PATH = tmpdir / "decisions.jsonl"
    index_module.DB_PATH = tmpdir / "decisions.db"
    index_module.reset_cache()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_commitment(summary: str) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "created_at": _now_iso(),
        "type": "commitment",
        "summary": summary,
        "attendees": ["alice@acme.com"],
        "topics": ["test"],
        "source_meeting": "2026-05-19-1000-test",
        "why": "",
        "why_notes": "",
        "owner": "You",
        "due": None,
        "state": "open",
    }


def _lookup(entry_id: str) -> dict | None:
    for entry in ledger.iter_entries():
        if entry.get("id") == entry_id:
            return entry
    return None


_results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    _results.append((name, ok, detail))
    marker = "PASS" if ok else "FAIL"
    print(f"  [{marker}] {name}" + (f" — {detail}" if detail and not ok else ""))


def section(title: str) -> None:
    print(f"\n# {title}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="u3-smoke-") as raw_tmp:
        tmpdir = Path(raw_tmp)
        _redirect_ledger_to(tmpdir)

        section("Setup — append 3 commitments to the fixture ledger")
        e1 = _make_commitment("Send pricing memo to Acme")
        e2 = _make_commitment("Confirm Q2 burn forecast with Finance")
        e3 = _make_commitment("Share renewal terms with vendor")
        for e in (e1, e2, e3):
            ledger.append(e)
        pending = [e1["id"], e2["id"], e3["id"]]
        check("3 entries appended", sum(1 for _ in ledger.iter_entries()) == 3)
        check("entries start with empty why", all(_lookup(p)["why"] == "" for p in pending))

        section("AE5 happy: `2: …\\n3: …` updates entries 2 and 3, entry 1 left pending")
        reply = "2: Q2 burn higher than forecast\n3: They need it before quarter close\n"
        result = why_capture.parse_and_update(reply, pending)
        check("matched_count == 2", result["matched_count"] == 2, f"got {result['matched_count']}")
        check("no warnings", result["warnings"] == [], f"got {result['warnings']}")
        check("entry 2 why set", _lookup(e2["id"])["why"] == "Q2 burn higher than forecast")
        check("entry 3 why set", _lookup(e3["id"])["why"] == "They need it before quarter close")
        check("entry 1 why still empty", _lookup(e1["id"])["why"] == "")
        check("all_answered False (entry 1 still pending)", result["all_answered"] is False)

        section("Quoted-only reply: lines starting with `>` are ignored")
        # Reset entry 1 to confirm nothing flows in.
        before_e1 = _lookup(e1["id"])["why"]
        quoted = "> 1: this should not count\n> 2: nor this\n"
        result = why_capture.parse_and_update(quoted, pending)
        check("matched_count == 0", result["matched_count"] == 0)
        check("entry 1 untouched", _lookup(e1["id"])["why"] == before_e1)

        section("Literal `skip` capture (no magic keyword)")
        # Use a fresh ledger to avoid stomping prior state.
        ledger.LEDGER_PATH.unlink()
        for e in (e1, e2, e3):
            e["why"] = ""
            e["why_notes"] = ""
            ledger.append(e)
        skip_reply = "1: skip\n"
        result = why_capture.parse_and_update(skip_reply, pending)
        check("entry 1 why == 'skip' (literal)", _lookup(e1["id"])["why"] == "skip")
        check("matched_count == 1", result["matched_count"] == 1)

        section("Free-form prose appends to why_notes on the LAST pending entry")
        prose_reply = "they were anxious about Q3\nand wanted a call back next week\n"
        result = why_capture.parse_and_update(prose_reply, pending)
        e3_notes = _lookup(e3["id"])["why_notes"]
        check("matched_count == 0", result["matched_count"] == 0)
        check(
            "entry 3 why_notes contains prose",
            "they were anxious about Q3" in e3_notes and "next week" in e3_notes,
            f"got {e3_notes!r}",
        )
        check("entry 1 why_notes untouched", _lookup(e1["id"])["why_notes"] == "")
        check("entry 2 why_notes untouched", _lookup(e2["id"])["why_notes"] == "")

        section("Idempotent re-parse: same prose does not double-up")
        notes_before = _lookup(e3["id"])["why_notes"]
        result = why_capture.parse_and_update(prose_reply, pending)
        notes_after = _lookup(e3["id"])["why_notes"]
        check("why_notes unchanged on re-parse", notes_before == notes_after,
              f"before={notes_before!r} after={notes_after!r}")

        section("Out-of-range index logs a warning, valid lines still process")
        out_of_range = "999: this is way too high\n2: legitimate reason\n"
        # Reset entry 2 first so we can detect the update.
        ledger.LEDGER_PATH.unlink()
        e1["why"] = "skip"; e1["why_notes"] = ""
        e2["why"] = ""; e2["why_notes"] = ""
        e3["why"] = ""; e3["why_notes"] = ""
        for e in (e1, e2, e3):
            ledger.append(e)
        result = why_capture.parse_and_update(out_of_range, pending)
        check("matched_count == 1", result["matched_count"] == 1)
        check("at least one warning", len(result["warnings"]) >= 1, f"got {result['warnings']}")
        check(
            "warning mentions out-of-range index",
            any("999" in w or "out of range" in w for w in result["warnings"]),
            f"got {result['warnings']}",
        )
        check("entry 2 still updated", _lookup(e2["id"])["why"] == "legitimate reason")

        section("Numbered match for missing ledger id warns rather than crashes")
        bogus_pending = ["00000000-0000-0000-0000-000000000000"]
        result = why_capture.parse_and_update("1: orphan reason\n", bogus_pending)
        check("matched_count == 0", result["matched_count"] == 0)
        check("warning for missing entry", any("not in ledger" in w for w in result["warnings"]),
              f"got {result['warnings']}")

        section("all_answered flips True only when every pending entry has a non-empty why")
        # Fresh state.
        ledger.LEDGER_PATH.unlink()
        e1["why"] = ""; e1["why_notes"] = ""
        e2["why"] = ""; e2["why_notes"] = ""
        e3["why"] = ""; e3["why_notes"] = ""
        for e in (e1, e2, e3):
            ledger.append(e)
        partial = why_capture.parse_and_update("1: a\n2: b\n", pending)
        check("partial.all_answered False", partial["all_answered"] is False)
        final = why_capture.parse_and_update("3: c\n", pending)
        check("final.all_answered True", final["all_answered"] is True)

        section("File mode preserved across rewrites")
        mode = ledger.LEDGER_PATH.stat().st_mode & 0o777
        check("ledger file mode == 600", mode == 0o600, f"got {oct(mode)}")

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
