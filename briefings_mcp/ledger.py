"""JSONL ledger of decisions and commitments.

Per R1, the ledger lives at ~/.briefings/decisions.jsonl with mode 600 inside a 700 directory.
The MCP server (U4) is the read path for external agents; commands/briefing.md reads the JSONL
inline; commands/follow-up.md is the sole writer. v1 is single-writer, so no locking.

Writes are append-only with one exception: `update_why` rewrites the file atomically to fold
captured reasons into existing entries (U3 / R14). The supersede-event alternative was rejected
because it would push reconciliation into `query.py` / `index.py` for every read; an atomic
rewrite stays simple and safe given the single-writer guarantee.
"""

from __future__ import annotations

import json
import os
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path
from typing import Iterator

from . import schema

LEDGER_DIR = Path.home() / ".briefings"
LEDGER_PATH = LEDGER_DIR / "decisions.jsonl"

_DIR_MODE = 0o700
_FILE_MODE = 0o600


@contextmanager
def _restricted_umask():
    """Force mode-077 umask around create operations so freshly-made paths inherit 600/700,
    matching the umask 077 pattern at scripts/scheduler.sh:13.
    """
    old = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(old)


def _ensure_paths() -> None:
    """Create the ledger directory and file if missing, with mode 700 / 600."""
    with _restricted_umask():
        LEDGER_DIR.mkdir(mode=_DIR_MODE, parents=True, exist_ok=True)
        if not LEDGER_PATH.exists():
            LEDGER_PATH.touch(mode=_FILE_MODE)
    # Belt-and-suspenders: enforce modes even if the paths pre-existed with looser permissions.
    os.chmod(LEDGER_DIR, _DIR_MODE)
    os.chmod(LEDGER_PATH, _FILE_MODE)


def append(entry: dict) -> None:
    """Validate entry against schema, then write one JSON line and fsync.

    Raises schema.SchemaError before any write happens on invalid input — the ledger remains
    untouched. v1 is single-writer (commands/follow-up.md), so no file locking.
    """
    schema.validate(entry)
    _ensure_paths()
    line = json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(LEDGER_PATH, "a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
        os.fsync(f.fileno())


def update_why(
    entry_id: str,
    *,
    why: str | None = None,
    why_notes_append: str | None = None,
) -> bool:
    """Fold a captured reason into an existing ledger entry.

    Used by the why-capture flow (U3 / R14) when a user replies to a follow-up email. The
    matching entry's `why` field is replaced when `why` is given; `why_notes_append` is
    concatenated onto the existing `why_notes` (newline-separated when both sides are
    non-empty).

    Returns True when an entry was matched and rewritten, False when no entry matched the id
    (the ledger file is left untouched in that case). The whole file is rewritten atomically
    via a tmp file in the same directory plus os.replace — see the module docstring for why
    we accept this over append-only supersede events.

    Raises FileNotFoundError when the ledger file does not yet exist (caller should not be
    asking for updates against a ledger that has never been written).
    """
    if why is None and why_notes_append is None:
        return False
    if not LEDGER_PATH.exists():
        raise FileNotFoundError(LEDGER_PATH)

    matched = False
    lines_out: list[str] = []
    with open(LEDGER_PATH, "r", encoding="utf-8") as f:
        for raw_line in f:
            stripped = raw_line.strip()
            if not stripped:
                lines_out.append(raw_line)
                continue
            entry = json.loads(stripped)
            if entry.get("id") == entry_id:
                matched = True
                if why is not None:
                    entry["why"] = why
                if why_notes_append:
                    existing = entry.get("why_notes") or ""
                    entry["why_notes"] = (
                        f"{existing}\n{why_notes_append}" if existing else why_notes_append
                    )
                lines_out.append(
                    json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
                )
            else:
                # Preserve the original line byte-for-byte (sans the strip-blank-noop) so we
                # don't reformat untouched entries.
                lines_out.append(raw_line if raw_line.endswith("\n") else raw_line + "\n")

    if not matched:
        return False

    tmp_path = LEDGER_PATH.with_suffix(".jsonl.tmp")
    with _restricted_umask():
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.writelines(lines_out)
            f.flush()
            os.fsync(f.fileno())
    os.chmod(tmp_path, _FILE_MODE)
    os.replace(tmp_path, LEDGER_PATH)
    return True


def iter_entries(since: date | None = None) -> Iterator[dict]:
    """Stream ledger entries in append order. If since is given, skip entries whose
    created_at date is earlier than since.

    Reads line-by-line so it stays cheap on a growing ledger. Malformed lines raise rather
    than silently skipping — corruption is louder than a quiet miss.
    """
    if not LEDGER_PATH.exists():
        return
    with open(LEDGER_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            if since is not None:
                created_at = entry.get("created_at", "")
                # Python 3.9 fromisoformat doesn't accept trailing 'Z' — normalise per scheduler.sh:86.
                normalised = created_at.replace("Z", "+00:00") if created_at.endswith("Z") else created_at
                entry_date = datetime.fromisoformat(normalised).date()
                if entry_date < since:
                    continue
            yield entry
