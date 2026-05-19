"""SQLite index built from the JSONL ledger.

The JSONL at ~/.briefings/decisions.jsonl is canonical (per the plan's Key Technical Decisions);
this module exposes a derived in-memory SQLite database for fast filtered queries by the MCP
tools in `server.py`. The in-memory database is also persisted to ~/.briefings/decisions.db so
cold starts (the SIGTERM-on-spawn behavior in claude/claude-code#40207) stay sub-second on a
fully-populated ledger.

Invalidation is mtime-based: if the JSONL is newer than the disk cache or the disk cache is
missing or corrupt, the index is rebuilt from JSONL via `executemany()` and the new state is
written back to disk. Subsequent reads come from the in-memory copy.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
from pathlib import Path
from typing import Optional

from . import ledger

logger = logging.getLogger(__name__)

DB_PATH = ledger.LEDGER_DIR / "decisions.db"

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS entries (
    id              TEXT PRIMARY KEY,
    created_at      TEXT NOT NULL,
    type            TEXT NOT NULL,
    summary         TEXT NOT NULL,
    attendees_flat  TEXT NOT NULL,
    topics_flat     TEXT NOT NULL,
    source_meeting  TEXT,
    why             TEXT,
    why_notes       TEXT,
    owner           TEXT,
    due             TEXT,
    state           TEXT,
    resolved        INTEGER,
    raw             TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS entries_created_at_idx ON entries(created_at);
CREATE INDEX IF NOT EXISTS entries_type_idx       ON entries(type);
CREATE INDEX IF NOT EXISTS entries_state_idx      ON entries(state);
"""

_INSERT_SQL = """
INSERT OR REPLACE INTO entries
    (id, created_at, type, summary, attendees_flat, topics_flat,
     source_meeting, why, why_notes, owner, due, state, resolved, raw)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


def _to_row(entry: dict) -> tuple:
    """Project a ledger entry into the flat row shape the index stores."""
    attendees = entry.get("attendees") or []
    topics = entry.get("topics") or []
    return (
        entry["id"],
        entry["created_at"],
        entry["type"],
        entry["summary"],
        " ".join(str(a) for a in attendees),
        " ".join(str(t) for t in topics),
        entry.get("source_meeting"),
        entry.get("why"),
        entry.get("why_notes"),
        entry.get("owner"),
        entry.get("due"),
        entry.get("state"),
        1 if entry.get("resolved") else 0 if "resolved" in entry else None,
        json.dumps(entry, ensure_ascii=False, separators=(",", ":")),
    )


def _create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(_SCHEMA_SQL)


def _populate_from_jsonl(conn: sqlite3.Connection) -> int:
    rows = [_to_row(e) for e in ledger.iter_entries()]
    if rows:
        conn.executemany(_INSERT_SQL, rows)
    conn.commit()
    return len(rows)


def _persist_to_disk(mem_conn: sqlite3.Connection) -> None:
    """Atomically dump the in-memory db to ~/.briefings/decisions.db (mode 600)."""
    ledger._ensure_paths()  # guarantees ~/.briefings exists with mode 700
    tmp_path = DB_PATH.with_suffix(".db.tmp")
    if tmp_path.exists():
        tmp_path.unlink()
    with ledger._restricted_umask():
        disk_conn = sqlite3.connect(tmp_path)
    try:
        mem_conn.backup(disk_conn)
    finally:
        disk_conn.close()
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, DB_PATH)


def _load_from_disk_into_memory() -> Optional[sqlite3.Connection]:
    """Try to load the on-disk cache into a fresh in-memory connection.

    Returns the in-memory connection on success, None if the disk file is missing or
    corrupt — corruption gets logged and the caller falls back to rebuilding from JSONL.
    """
    if not DB_PATH.exists():
        return None
    try:
        disk_conn = sqlite3.connect(DB_PATH)
        try:
            mem_conn = sqlite3.connect(":memory:")
            disk_conn.backup(mem_conn)
        finally:
            disk_conn.close()
        # Light integrity probe — readable schema and the entries table is queryable.
        mem_conn.execute("SELECT COUNT(*) FROM entries").fetchone()
        return mem_conn
    except sqlite3.DatabaseError as exc:
        logger.warning("SQLite cache at %s is corrupt (%s); rebuilding from JSONL", DB_PATH, exc)
        try:
            DB_PATH.unlink()
        except OSError:
            pass
        return None


# Module-level cache: (mem_conn, jsonl_mtime_ns_when_built)
_cache: Optional[tuple[sqlite3.Connection, int]] = None


def _jsonl_mtime_ns() -> int:
    """Return the JSONL file mtime in nanoseconds, or 0 if it does not exist yet."""
    try:
        return ledger.LEDGER_PATH.stat().st_mtime_ns
    except FileNotFoundError:
        return 0


def _disk_mtime_ns() -> int:
    try:
        return DB_PATH.stat().st_mtime_ns
    except FileNotFoundError:
        return 0


def get_connection() -> sqlite3.Connection:
    """Return an in-memory SQLite connection populated with the current ledger contents.

    Cheap on the hot path: if JSONL hasn't changed since the cached connection was built,
    the same connection is returned. Otherwise the index is reloaded from the disk cache
    (when fresh) or rebuilt from JSONL (when stale or corrupt) and re-persisted to disk.
    """
    global _cache

    jsonl_mtime = _jsonl_mtime_ns()

    if _cache is not None:
        cached_conn, cached_mtime = _cache
        if cached_mtime == jsonl_mtime:
            return cached_conn
        cached_conn.close()
        _cache = None

    # JSONL is the authority. If the disk cache is at least as new, we can load it directly.
    if jsonl_mtime > 0 and _disk_mtime_ns() >= jsonl_mtime:
        mem_conn = _load_from_disk_into_memory()
        if mem_conn is not None:
            _cache = (mem_conn, jsonl_mtime)
            return mem_conn

    # Rebuild from JSONL.
    mem_conn = sqlite3.connect(":memory:")
    _create_schema(mem_conn)
    n = _populate_from_jsonl(mem_conn)
    logger.info("Rebuilt SQLite index from JSONL (%d entries)", n)
    if jsonl_mtime > 0:
        _persist_to_disk(mem_conn)

    _cache = (mem_conn, jsonl_mtime)
    return mem_conn


def reset_cache() -> None:
    """Drop the in-memory connection. Test seam; production calls go through get_connection."""
    global _cache
    if _cache is not None:
        _cache[0].close()
        _cache = None


def entry_from_row(row: sqlite3.Row | tuple) -> dict:
    """Reverse of _to_row: hand back the original ledger entry dict from a queried row."""
    raw = row["raw"] if isinstance(row, sqlite3.Row) else row[-1]
    return json.loads(raw)
