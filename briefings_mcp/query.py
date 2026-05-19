"""Filter resolution and result shaping for the MCP tools in `server.py`.

Keeps SQL out of the tool handlers so the tool surface stays flat and the SQL stays in one
file. Topic and attendee filters use substring match per the plan's Risks table (topic-tag
fuzziness from Claude-inferred extraction means exact match would miss); type, state, and
date filters are exact.
"""

from __future__ import annotations

import sqlite3
from collections import Counter
from typing import Optional

from . import index as index_module

_MAX_LIMIT = 500


def _clamp(value: Optional[int], default: int) -> int:
    if value is None:
        return default
    if value < 1:
        return 1
    if value > _MAX_LIMIT:
        return _MAX_LIMIT
    return value


def search_decisions(
    attendee: Optional[str] = None,
    topic: Optional[str] = None,
    type: Optional[str] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    state: Optional[str] = None,
    limit: Optional[int] = 50,
) -> list[dict]:
    """Return ledger entries matching the supplied filters, most recent first.

    All filters are AND-combined. Unset filters are ignored. Topic and attendee use substring
    match (case-insensitive); type, state, and date bounds are exact. ISO `created_at` strings
    sort lexicographically, so date_from/date_to comparisons are direct string comparisons.
    """
    conn = index_module.get_connection()
    conn.row_factory = sqlite3.Row

    clauses: list[str] = []
    params: list = []

    if attendee:
        clauses.append("LOWER(attendees_flat) LIKE ?")
        params.append(f"%{attendee.lower()}%")
    if topic:
        clauses.append("LOWER(topics_flat) LIKE ?")
        params.append(f"%{topic.lower()}%")
    if type:
        clauses.append("type = ?")
        params.append(type)
    if state:
        clauses.append("state = ?")
        params.append(state)
    if date_from:
        clauses.append("created_at >= ?")
        params.append(date_from)
    if date_to:
        clauses.append("created_at <= ?")
        # Inclusive upper bound covering the whole day if a bare date was passed.
        params.append(date_to if "T" in date_to else date_to + "T23:59:59")

    where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
    sql = f"SELECT raw FROM entries{where} ORDER BY created_at DESC LIMIT ?"
    params.append(_clamp(limit, 50))

    return [index_module.entry_from_row(row) for row in conn.execute(sql, params)]


def get_decision_by_id(id: str) -> Optional[dict]:
    """Return a single entry by its UUID, or None when no entry matches."""
    if not id:
        return None
    conn = index_module.get_connection()
    conn.row_factory = sqlite3.Row
    row = conn.execute("SELECT raw FROM entries WHERE id = ?", (id,)).fetchone()
    return index_module.entry_from_row(row) if row else None


def list_attendees(limit: Optional[int] = 100) -> list[dict]:
    """Return attendee emails ordered by entry-count descending.

    Each item is `{"attendee": "...", "entry_count": N}` so the caller doesn't have to
    re-parse a stringly-typed list. Attendees are stored as space-separated tokens in the
    index; we re-aggregate here rather than maintaining a second table because the projected
    attendee cardinality is small (low hundreds at v1 scale).
    """
    conn = index_module.get_connection()
    counter: Counter[str] = Counter()
    for (flat,) in conn.execute("SELECT attendees_flat FROM entries"):
        if not flat:
            continue
        for token in flat.split():
            counter[token] += 1

    capped = _clamp(limit, 100)
    return [
        {"attendee": attendee, "entry_count": count}
        for attendee, count in counter.most_common(capped)
    ]
