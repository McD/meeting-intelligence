"""Display formatters for ledger data.

`pretty_meeting_title` converts a meeting slug (e.g. `2026-05-20-1500-ai-proposal-review-data-tools`)
into a human-readable title (`AI Proposal Review Data Tools`). Used as a fallback in `/digest`
rendering for legacy ledger entries that pre-date the `meeting_title` field on commitments.
New commitments capture the calendar event's `summary` at follow-up time, so the helper only
runs for entries written before that change.
"""

from __future__ import annotations

import re


_SLUG_DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}-\d{4}-")

# Tokens that should be uppercased, lowercased, or specially cased after title-casing.
# Keys are the lowercased token; values are the desired display form.
_TOKEN_OVERRIDES = {
    "ai": "AI",
    "ml": "ML",
    "api": "API",
    "kpi": "KPI",
    "qbr": "QBR",
    "ceo": "CEO",
    "cpo": "CPO",
    "cto": "CTO",
    "cfo": "CFO",
    "coo": "COO",
    "vp": "VP",
    "hr": "HR",
    "pr": "PR",
    "qa": "QA",
    "ux": "UX",
    "ui": "UI",
    "us": "US",
    "uk": "UK",
    "eu": "EU",
    "sc": "SC",
    "mcd": "McD",
    "screencloud": "ScreenCloud",
}


def pretty_meeting_title(slug: str | None) -> str:
    """Best-effort slug → readable title. Returns empty string for falsy input.

    Strips a leading `YYYY-MM-DD-HHmm-` date stamp, splits on `-`, title-cases each token,
    applies a small known-acronym override list, and collapses `1 1` into `1:1`.
    """
    if not slug:
        return ""
    body = _SLUG_DATE_PREFIX.sub("", slug)
    tokens = [t for t in body.split("-") if t]
    pretty = [_TOKEN_OVERRIDES.get(t.lower(), t.capitalize()) for t in tokens]
    text = " ".join(pretty)
    # Collapse "1 1" → "1:1" (common shorthand for one-on-ones in slugs).
    text = re.sub(r"\b1 1\b", "1:1", text)
    return text
