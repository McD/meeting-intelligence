"""Filter resolution and result shaping for the MCP tools in `server.py`.

Keeps SQL out of the tool handlers so the tool surface stays flat and the SQL stays in one
file. Topic and attendee filters use substring match per the plan's Risks table (topic-tag
fuzziness from Claude-inferred extraction means exact match would miss); type, state, and
date filters are exact.
"""

from __future__ import annotations

import sqlite3
from collections import Counter
from datetime import date, timedelta
from typing import Optional

from . import index as index_module
from . import ledger as ledger_module

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


def find_patterns(
    window_days: int = 60,
    min_count: int = 3,
    limit: int = 3,
    attendees: Optional[list[str]] = None,
    topic_filter: Optional[list[str]] = None,
    types: Optional[list[str]] = None,
) -> list[tuple[str, int]]:
    """Return recurring topic tags from the ledger within a date window.

    Used by /briefing, /follow-up, and /digest (Phase 4) to surface cross-meeting echoes.
    Streams entries via `ledger.iter_entries(since=...)` and counts topic-tag occurrences
    (case-insensitive). Returns `(topic, count)` tuples sorted by count desc, then topic
    asc for deterministic tie-breaking. Empty list when no topic clears `min_count`.

    Filters:
    - `attendees` — only count entries whose attendees intersect with this list
      (case-insensitive). Used by /briefing to scope patterns to the current meeting's
      attendees.
    - `topic_filter` — only count entries whose topic tags include at least one of these
      (case-insensitive substring match against any tag). Used by /follow-up to scope
      patterns to this meeting's topics.
    - `types` — restrict to specific entry types (e.g. ["commitment"]); defaults to both
      commitments and decisions.

    Returns at most `limit` tuples. `window_days=0` returns an empty list (the window
    excludes everything).
    """
    if window_days <= 0 or min_count < 1 or limit < 1:
        return []

    since = date.today() - timedelta(days=window_days)

    attendees_lc = {a.lower() for a in (attendees or [])}
    topic_filter_lc = {t.lower() for t in (topic_filter or [])}
    types_set = set(types) if types else {"commitment", "decision"}

    counter: Counter[str] = Counter()
    for entry in ledger_module.iter_entries(since=since):
        if entry.get("type") not in types_set:
            continue

        if attendees_lc:
            entry_attendees = {a.lower() for a in (entry.get("attendees") or [])}
            if not (entry_attendees & attendees_lc):
                continue

        entry_topics = [t for t in (entry.get("topics") or []) if t]
        if not entry_topics:
            continue

        if topic_filter_lc:
            entry_topics_lc = {t.lower() for t in entry_topics}
            if not any(
                any(want in have for have in entry_topics_lc)
                for want in topic_filter_lc
            ):
                continue

        for tag in entry_topics:
            counter[tag.lower()] += 1

    # Counter.most_common is count-desc; explicit sort gives deterministic tie-break.
    above_threshold = [
        (topic, count) for topic, count in counter.items() if count >= min_count
    ]
    above_threshold.sort(key=lambda pair: (-pair[1], pair[0]))
    return above_threshold[:limit]
