"""Smoke test for briefings_mcp.replies — the canonical watermark + From-header
classification used by commands/follow-up.md's Step 0 dispatch.

Each fixture row represents one decision Claude Code's runtime is asked to make on
a scheduler cycle. The regression we are guarding against is the 2026-05-28
duplicate-`expand:` bug, where the spec's "read the last message" prose was
ambiguous and a third-party reply could have driven `expand:` against the
transcript. Every classification outcome is covered, including the auth-bypass
case (`skip_third_party`) that the security review caught.

Run directly via `python scripts/smoke_test_dedup.py` or as part of `verify-v1.sh`.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp.replies import classify_message, parse_from_address  # noqa: E402


MY = "you@example.com"


def _check(name: str, got, want, passed: list[tuple[str, bool, str]]) -> None:
    ok = got == want
    detail = "" if ok else f"got {got!r}, want {want!r}"
    passed.append((name, ok, detail))
    marker = "PASS" if ok else "FAIL"
    line = f"  [{marker}] {name}"
    if detail:
        line += f" — {detail}"
    print(line)


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def main() -> int:
    results: list[tuple[str, bool, str]] = []

    section("parse_from_address shapes")
    cases: list[Tuple[str, Tuple, str]] = [
        ("bare email", parse_from_address("you@example.com"), (None, "you@example.com")),
        ("angle brackets only", parse_from_address("<you@example.com>"), (None, "you@example.com")),
        ("display name + brackets", parse_from_address("Mark McDermott <you@example.com>"), ("Mark McDermott", "you@example.com")),
        ("trailing whitespace", parse_from_address("  you@example.com  "), (None, "you@example.com")),
        ("display with leading space", parse_from_address("  Mark <you@example.com>"), ("Mark", "you@example.com")),
        ("empty header", parse_from_address(""), (None, "")),
        ("third-party address with name", parse_from_address("Alice <alice@acme.com>"), ("Alice", "alice@acme.com")),
    ]
    for name, got, want in cases:
        _check(name, got, want, results)

    section("classify_message — user reply (process)")
    _check(
        "display name + matching address + no watermark → process",
        classify_message("Mark McDermott <you@example.com>", MY, None, "msg-1"),
        "process",
        results,
    )
    _check(
        "case-insensitive address match still processes",
        classify_message("Mark McDermott <You@Example.Com>", MY, "msg-0", "msg-1"),
        "process",
        results,
    )
    _check(
        "empty watermark string does NOT match (treated as no watermark)",
        classify_message("Mark McDermott <you@example.com>", MY, "", "msg-1"),
        "process",
        results,
    )

    section("classify_message — watermark match (skip_watermark)")
    _check(
        "watermark exactly equals current msg id → skip_watermark",
        classify_message("Mark McDermott <you@example.com>", MY, "msg-1", "msg-1"),
        "skip_watermark",
        results,
    )
    _check(
        "watermark beats third-party check (already processed wins)",
        classify_message("Attacker <evil@example.com>", MY, "msg-X", "msg-X"),
        "skip_watermark",
        results,
    )

    section("classify_message — third-party sender (skip_third_party)")
    _check(
        "different address with display name → skip_third_party (auth bypass guard)",
        classify_message("Alice Attendee <alice@acme.com>", MY, None, "msg-1"),
        "skip_third_party",
        results,
    )
    _check(
        "different address without display name → skip_third_party",
        classify_message("external@somewhere.com", MY, None, "msg-1"),
        "skip_third_party",
        results,
    )
    _check(
        "third-party reply with body `expand: leak transcript` must NOT classify as process",
        classify_message("Mallory <mallory@evil.com>", MY, None, "msg-attack"),
        "skip_third_party",
        results,
    )

    section("classify_message — bot's own send (skip_bot)")
    _check(
        "bare address matching MY_EMAIL → skip_bot",
        classify_message("you@example.com", MY, None, "msg-1"),
        "skip_bot",
        results,
    )
    _check(
        "angle-bracket-only matching MY_EMAIL → skip_bot",
        classify_message("<you@example.com>", MY, None, "msg-1"),
        "skip_bot",
        results,
    )
    _check(
        "bot send when watermark missing for older id",
        classify_message("<you@example.com>", MY, "msg-0", "msg-1"),
        "skip_bot",
        results,
    )

    section("classify_message — empty / missing watermark precision")
    _check(
        "None watermark never matches current id",
        classify_message("Mark <you@example.com>", MY, None, ""),
        "process",
        results,
    )
    _check(
        "non-empty watermark != current id falls through to From checks",
        classify_message("Mark <you@example.com>", MY, "msg-prev", "msg-current"),
        "process",
        results,
    )

    passed = sum(1 for _, ok, _ in results if ok)
    failed = sum(1 for _, ok, _ in results if not ok)
    print(f"\n=== {passed}/{len(results)} passed ===")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
