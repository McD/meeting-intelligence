"""JSONL ledger of decisions and commitments.

Per R1, the ledger lives at ~/.briefings/decisions.jsonl with mode 600 inside a 700 directory.
The MCP server (U4) is the read path for external agents; commands/briefing.md reads the JSONL
inline; commands/follow-up.md is the sole writer for new entries. v1 is single-writer, so no
locking.

Writes are mostly append-only. Phase 2 removed `update_why` when the Why? capture loop was
retired. Phase 3 deliberately walks that back for one specific field: `update_commitment_state`
mutates a commitment entry's `state` so the actions tracker digest's reply-keyword updates
(`done:`, `drop:`) can persist. All other fields remain append-only. The atomic-rewrite shape
(tmp file + os.replace) is safe under the single-writer guarantee; supersede-event alternatives
push reconciliation into every reader for negligible gain.

Phase 4 adds a dedup-on-write guard in `append`: commitment entries whose `source_meeting` +
`summary` (exact or first-60-char-prefix) already match a recent entry are silent-skipped.
Prevents /follow-up --force re-runs from accumulating duplicate copies of the same action item.
The companion `scripts/dedup_ledger.py` cleans up duplicates already on disk.
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


_DEDUP_SCAN_LIMIT = 50  # Last-N entries scanned by dedup-on-write (Phase 4).
_DEDUP_PREFIX_LEN = 60  # Prefix length for near-duplicate summary matching.


def _is_duplicate_commitment(entry: dict) -> bool:
    """Phase 4 dedup-on-write: scan the last few ledger entries for a near-duplicate.

    A commitment is a near-duplicate when an existing entry shares its `source_meeting`,
    has `type == "commitment"`, and matches the summary exactly OR on the first 60 chars.
    Decisions are never deduped here; the first commitment for a meeting is never a duplicate.

    Fails open: any error reading the ledger returns False so the append proceeds. Better to
    write a possible duplicate than to silently drop data.
    """
    if entry.get("type") != "commitment":
        return False
    source_meeting = entry.get("source_meeting")
    summary = entry.get("summary") or ""
    if not source_meeting or not summary:
        return False
    if not LEDGER_PATH.exists():
        return False

    new_prefix = summary[:_DEDUP_PREFIX_LEN]
    try:
        # Tail the last N lines — cheap on a small ledger, bounded on a growing one.
        with open(LEDGER_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for raw in reversed(lines[-_DEDUP_SCAN_LIMIT:]):
            stripped = raw.strip()
            if not stripped:
                continue
            existing = json.loads(stripped)
            if existing.get("type") != "commitment":
                continue
            if existing.get("source_meeting") != source_meeting:
                continue
            existing_summary = existing.get("summary") or ""
            if existing_summary == summary:
                return True
            # Prefix-of-prefix match: catches Claude rephrasings where one summary
            # is a substring extension of another (e.g. "Send memo" vs "Send memo by Friday").
            # Both prefixes truncated at 60 chars; one starting-with the other is enough.
            existing_prefix = existing_summary[:_DEDUP_PREFIX_LEN]
            if existing_prefix and new_prefix and (
                existing_prefix.startswith(new_prefix)
                or new_prefix.startswith(existing_prefix)
            ):
                return True
    except (OSError, json.JSONDecodeError):
        return False

    return False


def append(entry: dict) -> None:
    """Validate entry against schema, then write one JSON line and fsync.

    Raises schema.SchemaError before any write happens on invalid input — the ledger remains
    untouched. v1 is single-writer (commands/follow-up.md), so no file locking.

    Phase 4: if `entry` is a commitment that already exists for the same source_meeting (by
    exact or 60-char-prefix summary match against the last 50 entries), the write is a
    silent no-op. The caller doesn't need to know; the digest stops showing duplicate
    actions on /follow-up --force re-runs.
    """
    schema.validate(entry)
    if _is_duplicate_commitment(entry):
        return
    _ensure_paths()
    line = json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(LEDGER_PATH, "a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
        os.fsync(f.fileno())


def update_commitment_state(entry_id: str, new_state: str) -> bool:
    """Mutate one commitment entry's `state` field in place.

    Used by the actions tracker digest's reply-keyword flow (Phase 3 / `done:`, `drop:`). Only
    commitment entries are mutable; decision entries (and any other future types) are rejected.
    Returns True on a successful update, False when no entry matched the id (the ledger file is
    left untouched in that case).

    The whole file is rewritten atomically via a tmp file in the same directory plus os.replace.
    Safe under the single-writer guarantee documented in the module docstring. See `append` for
    the append-only contract for all other fields.

    Raises schema.SchemaError when `new_state` is not in COMMITMENT_STATES, or when the matched
    entry's type is not "commitment". Raises FileNotFoundError when the ledger file does not yet
    exist (caller should not be asking for updates against a ledger that has never been written).
    """
    if new_state not in schema.COMMITMENT_STATES:
        raise schema.SchemaError(
            f"new_state {new_state!r} not in {sorted(schema.COMMITMENT_STATES)}"
        )
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
                if entry.get("type") != "commitment":
                    raise schema.SchemaError(
                        f"entry {entry_id!r} is type {entry.get('type')!r}, expected 'commitment'"
                    )
                matched = True
                entry["state"] = new_state
                lines_out.append(
                    json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
                )
            else:
                # Preserve untouched entries byte-for-byte so a state update doesn't reformat
                # the rest of the ledger.
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
