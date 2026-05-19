"""Parse a follow-up email reply and fold captured reasons into the ledger.

Implements R14 / U3. The follow-up email's `## Why?` section enumerates high-stakes entries as
`1: …`, `2: …`, etc. The user replies on the same thread with one line per entry in the form
`N: <reason>`. This module strips quoted lines (`>` prefix is universal across Gmail/Apple Mail/
Outlook/phone clients), matches each remaining line against `^\\s*(\\d+):\\s+(.+)$`, indexes `N`
into `pending_entry_ids` at position `N-1`, and calls `ledger.update_why` for each match.

Unmatched non-quoted prose lines append to `why_notes` on the **last** entry in
`pending_entry_ids` — the most-recently-prompted entry from that thread, per R14.

The parser also detects completion: when every UUID in the original `pending_entry_ids` has a
non-empty `why` field in the ledger, the caller (Step 0 of commands/follow-up.md) deletes the
awaiting-why state file. `pending_entry_ids` is treated as an immutable index map; we do not
shrink it across cycles so subsequent replies can keep using the original `N` numbering.
"""

from __future__ import annotations

import re
from typing import TypedDict

from . import ledger

NUMBERED_LINE = re.compile(r"^\s*(\d+):\s+(.+?)\s*$")


class ParseResult(TypedDict):
    matched_count: int
    all_answered: bool
    warnings: list[str]


def parse_and_update(reply_body: str, pending_entry_ids: list[str]) -> ParseResult:
    """Apply a reply body's captured reasons to the ledger.

    `reply_body` is the raw text of the user's reply (as returned by `gws gmail +read`).
    `pending_entry_ids` is the immutable list of ledger entry UUIDs that the original follow-up
    email prompted about, indexed 1..N in the email's `## Why?` section.

    Returns matched_count (numbered lines that successfully updated an entry on this cycle),
    all_answered (True when every UUID in pending_entry_ids now has a non-empty `why`), and a
    list of warnings (out-of-range indices, missing ledger entries, update failures). Warnings
    do not abort the parse — the caller logs them and continues.
    """
    matched_count = 0
    prose_lines: list[str] = []
    warnings: list[str] = []

    for raw in reply_body.split("\n"):
        line = raw.rstrip("\r")
        if line.lstrip().startswith(">"):
            continue
        if not line.strip():
            continue
        m = NUMBERED_LINE.match(line)
        if m:
            n = int(m.group(1))
            reason = m.group(2).strip()
            idx = n - 1
            if 0 <= idx < len(pending_entry_ids):
                entry_id = pending_entry_ids[idx]
                try:
                    if ledger.update_why(entry_id, why=reason):
                        matched_count += 1
                    else:
                        warnings.append(f"entry id {entry_id} not in ledger; skipping")
                except Exception as exc:
                    warnings.append(f"ledger.update_why failed for {entry_id}: {exc}")
            else:
                warnings.append(
                    f"reply line index {n} out of range (1..{len(pending_entry_ids)})"
                )
        else:
            prose_lines.append(line.strip())

    if prose_lines and pending_entry_ids:
        prose_block = "\n".join(prose_lines)
        target_id = pending_entry_ids[-1]
        # Dedupe re-processed replies: when the awaiting-why file persists across cycles
        # (because pending hasn't fully cleared), the same prose would otherwise re-append on
        # every poll. Skip when the target entry's why_notes already ends with this block.
        existing_notes = ""
        for entry in ledger.iter_entries():
            if entry.get("id") == target_id:
                existing_notes = entry.get("why_notes") or ""
                break
        if not existing_notes.endswith(prose_block):
            try:
                ledger.update_why(target_id, why_notes_append=prose_block)
            except Exception as exc:
                warnings.append(
                    f"ledger.update_why (why_notes) failed for {target_id}: {exc}"
                )

    pending_set = set(pending_entry_ids)
    answered: set[str] = set()
    for entry in ledger.iter_entries():
        eid = entry.get("id")
        if eid in pending_set and (entry.get("why") or "").strip():
            answered.add(eid)
    all_answered = pending_set.issubset(answered) if pending_set else False

    return ParseResult(
        matched_count=matched_count,
        all_answered=all_answered,
        warnings=warnings,
    )
