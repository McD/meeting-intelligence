"""Ledger schema: the single source of truth for entry shape, valid values, and the high-stakes filter.

Referenced by briefings_mcp.ledger (for validation), commands/follow-up.md (for classification +
high-stakes filtering), and commands/briefing.md (for the verdict word set). Any future change to
the schema or the high-stakes rule lands here so it propagates consistently.
"""

from __future__ import annotations


ENTRY_TYPES = frozenset({"decision", "commitment"})

COMMITMENT_STATES = frozenset({"open", "in-flight", "done", "dropped"})

# Closed verdict word set per R5. Briefing renders the meeting title prefixed with one of these.
VERDICTS = frozenset({
    "DECIDE-TODAY",
    "DELEGATE",
    "DEFER",
    "DECLINE",
    "PREP-HARD",
    "LOW-STAKES",
    "MOVE-ASYNC",
})

HIGH_STAKES_VERDICTS = frozenset({"DECIDE-TODAY", "DECLINE", "PREP-HARD"})

HIGH_STAKES_ATTENDEE_HISTORY_THRESHOLD = 5

SUMMARY_MAX_CHARS = 140

# Per R2 — every ledger entry, regardless of type, carries these keys.
REQUIRED_BASE_FIELDS = (
    "id",
    "created_at",
    "type",
    "summary",
    "attendees",
    "topics",
    "source_meeting",
    "why",
    "why_notes",
)

# Per R3 — commitment entries carry these in addition to REQUIRED_BASE_FIELDS.
REQUIRED_COMMITMENT_FIELDS = ("owner", "due", "state")

# Per R4 — decision entries carry this in addition to REQUIRED_BASE_FIELDS.
REQUIRED_DECISION_FIELDS = ("resolved",)


class SchemaError(ValueError):
    """Raised when an entry fails validation. The ledger does not write on raise."""


def validate(entry: dict) -> None:
    """Raise SchemaError if entry is not a well-formed ledger record.

    Per R1, validation gates every append. The ledger file remains untouched on raise.
    """
    if not isinstance(entry, dict):
        raise SchemaError(f"entry must be a dict, got {type(entry).__name__}")

    missing = [f for f in REQUIRED_BASE_FIELDS if f not in entry]
    if missing:
        raise SchemaError(f"entry missing required fields: {missing}")

    entry_type = entry["type"]
    if entry_type not in ENTRY_TYPES:
        raise SchemaError(f"entry type {entry_type!r} not in {sorted(ENTRY_TYPES)}")

    summary = entry["summary"]
    if not isinstance(summary, str):
        raise SchemaError("summary must be a string")
    if len(summary) > SUMMARY_MAX_CHARS:
        raise SchemaError(f"summary exceeds {SUMMARY_MAX_CHARS} chars: {len(summary)}")

    if not isinstance(entry["attendees"], list):
        raise SchemaError("attendees must be a list of email addresses")
    if not isinstance(entry["topics"], list):
        raise SchemaError("topics must be a list of tag strings")

    if entry_type == "commitment":
        missing_c = [f for f in REQUIRED_COMMITMENT_FIELDS if f not in entry]
        if missing_c:
            raise SchemaError(f"commitment missing required fields: {missing_c}")
        state = entry["state"]
        if state not in COMMITMENT_STATES:
            raise SchemaError(f"commitment state {state!r} not in {sorted(COMMITMENT_STATES)}")

    elif entry_type == "decision":
        missing_d = [f for f in REQUIRED_DECISION_FIELDS if f not in entry]
        if missing_d:
            raise SchemaError(f"decision missing required fields: {missing_d}")
        if not isinstance(entry["resolved"], bool):
            raise SchemaError("decision.resolved must be a bool")


def is_high_stakes(verdict: str, is_external: bool, attendee_history_count: int) -> bool:
    """Per R12 — an entry is high-stakes when ANY of: verdict is in the high-stakes set,
    the meeting is external/mixed, OR an attendee has at least the threshold of prior ledger entries.

    The follow-up email composes why-prompts only for high-stakes entries.
    """
    if verdict in HIGH_STAKES_VERDICTS:
        return True
    if is_external:
        return True
    if attendee_history_count >= HIGH_STAKES_ATTENDEE_HISTORY_THRESHOLD:
        return True
    return False
