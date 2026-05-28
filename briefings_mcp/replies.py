"""Reply-keyword classification: pure functions for the watermark + From-header guards.

`commands/follow-up.md` Step 0's awaiting-reply and awaiting-digest branches make
their dispatch decisions from two signals: (1) whether the message has already been
processed (watermark match against `last_processed_msg`), and (2) whether the message
is actually from the user vs from the bot's own past sends or from a third party who
landed in the thread.

The runtime implementation is prose that Claude Code follows on each scheduler cycle.
This module is the canonical specification of the comparison logic — same shape, same
edge cases, exercised by `scripts/smoke_test_dedup.py`. Keep the prose in sync.

Why both prose AND code? The scheduler executes the prose (the LLM is the runtime),
but the prose is unit-testable only against the code. Drift between the two is the
biggest risk; the test suite catches it by asserting that this module's behaviour
matches what the prose claims.
"""

from __future__ import annotations

import re
from typing import Literal, Optional, Tuple

ClassifyResult = Literal["process", "skip_watermark", "skip_third_party", "skip_bot"]


# RFC 5322 From header — extract the address inside <…> if present, else treat the
# whole value as a bare email. Display name is anything non-whitespace before the
# opening angle bracket. This is intentionally simple: gws and standard mail clients
# produce these shapes; we do not parse group syntax, quoted-string display names,
# or comments. If you hit a real edge case, add a test row to smoke_test_dedup.py.
_ANGLE_ADDR_RE = re.compile(r"<\s*([^>]+?)\s*>")


def parse_from_address(header: str) -> Tuple[Optional[str], str]:
    """Return (display_name, address) from a From header value.

    Empty string display_name and the unchanged input both surface as
    (None, header.strip()) so callers don't need to special-case empty headers.
    """
    if not header:
        return None, ""

    s = header.strip()
    m = _ANGLE_ADDR_RE.search(s)
    if m:
        address = m.group(1).strip()
        display = s[: m.start()].strip()
        return (display or None, address)

    return None, s


def classify_message(
    from_header: str,
    my_email: str,
    last_processed_msg: Optional[str],
    current_msg_id: str,
) -> ClassifyResult:
    """Decide what to do with the latest message in an awaiting-* thread.

    `process` — the message is a real user reply we haven't seen yet; Step 5 runs.
    `skip_watermark` — already processed on a prior cycle; do nothing.
    `skip_third_party` — From address is not the user's; do not let it drive the
        keyword parser. The watermark gets advanced so the same third-party message
        doesn't trigger this check again, but no keyword action is taken.
    `skip_bot` — From address is the user's BUT no display name is present, which
        identifies the bot's own outbound sends (`gws gmail +send` produces bare
        addresses). Watermark advances; no action.

    Watermark check is strict: present AND non-empty AND exactly equal to the
    current message ID. An empty or None watermark never matches.
    """
    if last_processed_msg and last_processed_msg == current_msg_id:
        return "skip_watermark"

    display, address = parse_from_address(from_header)

    if address.lower() != my_email.lower():
        return "skip_third_party"

    if not display:
        return "skip_bot"

    return "process"
