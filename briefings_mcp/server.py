"""FastMCP server exposing the briefings ledger to external agents.

Three read-only tools query the SQLite index built from ~/.briefings/decisions.jsonl:
`search_decisions`, `get_decision_by_id`, `list_attendees`. Per the plan's Key Technical
Decision, this server is the read path *for external agents only* — `commands/briefing.md`
reads the JSONL directly via embedded Python, so the MCP roundtrip is skipped on the hot
brief-generation path.

Filter parameters are flat scalars so Claude picks them up cleanly; nested objects make
narrow tools harder for the model to fill.
"""

from __future__ import annotations

import logging
from typing import Literal, Optional

from fastmcp import FastMCP

from . import query

logger = logging.getLogger(__name__)

mcp = FastMCP(
    name="briefings",
    instructions=(
        "Read-only access to Mark's personal decision and commitment ledger. "
        "Use search_decisions to find past decisions and commitments by attendee, topic, "
        "type, state, or date range. Use get_decision_by_id when you already have a UUID. "
        "Use list_attendees to discover who appears in the ledger and how often."
    ),
)


@mcp.tool
def search_decisions(
    attendee: Optional[str] = None,
    topic: Optional[str] = None,
    type: Optional[Literal["decision", "commitment"]] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    state: Optional[Literal["open", "in-flight", "done", "dropped"]] = None,
    limit: int = 50,
) -> list[dict]:
    """Search the decision/commitment ledger.

    Args:
        attendee: Substring match against attendee emails (case-insensitive).
        topic: Substring match against topic tags (case-insensitive).
        type: Filter to `decision` or `commitment` entries only.
        date_from: ISO date or datetime; entries with `created_at` on/after this are returned.
        date_to: ISO date or datetime; entries with `created_at` on/before this are returned.
        state: Commitment state filter. Only meaningful for commitment entries.
        limit: Maximum number of entries to return (default 50, max 500).

    Returns:
        List of ledger entries, most recent first.
    """
    return query.search_decisions(
        attendee=attendee,
        topic=topic,
        type=type,
        date_from=date_from,
        date_to=date_to,
        state=state,
        limit=limit,
    )


@mcp.tool
def get_decision_by_id(id: str) -> Optional[dict]:
    """Fetch a single ledger entry by UUID.

    Args:
        id: The entry's UUID (the `id` field on a ledger entry).

    Returns:
        The matching entry as a dict, or null if no entry has that id.
    """
    return query.get_decision_by_id(id)


@mcp.tool
def list_attendees(limit: int = 100) -> list[dict]:
    """List attendees that appear in the ledger, ordered by entry count descending.

    Args:
        limit: Maximum number of attendees to return (default 100, max 500).

    Returns:
        List of `{attendee, entry_count}` objects sorted by entry_count desc.
    """
    return query.list_attendees(limit=limit)
