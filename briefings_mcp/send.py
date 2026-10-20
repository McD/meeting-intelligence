"""Send email to the user, and only the user, as one simple command.

Headless runs used to send with a compound shell command: write the body to a
temp file with a heredoc, read it back with `$(cat ...)`, pipe it into
`gws gmail +reply`. The permission rule `Bash(gws *)` only matches a command that
starts with `gws`, so those went to auto mode's classifier, which sometimes
blocked them (2026-10-14, and the 2026-10-20 `expand:` reply). A blocked reply is
a silent failure: the user asked for something and nothing arrived.

This helper gives every self-addressed send one shape that a narrow allow rule
can match (update.sh installs it):

    ~/.briefings/venv/bin/python3 -m briefings_mcp.send self  --subject S --html-file F
    ~/.briefings/venv/bin/python3 -m briefings_mcp.send self  --subject S --markdown-file F
    ~/.briefings/venv/bin/python3 -m briefings_mcp.send reply --message-id ID --html-file F

It is deliberately narrower than gws:
- `self` always sends to MY_EMAIL from ~/.briefings_config; there is no --to.
- `reply` first checks that the message being replied to was sent by MY_EMAIL.
  gws +reply answers the original sender, so this keeps a reply from ever going
  to a third party on the thread.
- body files must live under ~/Briefings/, so it can't be pointed at other
  local files.
Mail to anyone else (digest nudges) stays on plain `gws gmail +send`, where the
classifier's check is the right one.

Prints gws's JSON response (with `id` and `threadId`) on success, exit 0.
Exit 2 on a refused request, 1 on a send failure.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

from .cycle_plan import _my_email_from_config, _parse_gws_output
from .replies import parse_from_address

ALLOWED_ROOT = Path("~/Briefings").expanduser()


class Refused(Exception):
    pass


def body_path(raw: str, root: Path = ALLOWED_ROOT) -> Path:
    """Resolve a body file and refuse anything outside `root` (symlinks resolved)."""
    p = Path(raw).expanduser().resolve()
    if root.resolve() not in p.parents:
        raise Refused(f"body file must be under {root}: {raw}")
    if not p.is_file():
        raise Refused(f"body file not found: {raw}")
    return p


def check_reply_target(from_header: str, my_email: str) -> None:
    _, address = parse_from_address(from_header)
    if address.lower() != my_email.lower():
        raise Refused(f"message was sent by {address or 'unknown'}, not {my_email}; refusing to reply")


def _gws(gws: str, args: list[str], timeout: int = 60) -> tuple[int, str]:
    try:
        p = subprocess.run([gws, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, f"{type(e).__name__}: {e}"
    return p.returncode, p.stdout + (p.stderr if p.returncode else "")


def _message_from(gws: str, message_id: str) -> str:
    rc, out = _gws(gws, ["gmail", "users", "messages", "get", "--params", json.dumps({
        "userId": "me", "id": message_id, "format": "metadata", "metadataHeaders": ["From"]})])
    data = _parse_gws_output(out) or {}
    if rc != 0 or "error" in data:
        raise Refused(f"could not read message {message_id}: {out.strip()[:200]}")
    for h in (data.get("payload") or {}).get("headers") or []:
        if (h.get("name") or "").lower() == "from":
            return h.get("value") or ""
    return ""


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Email the user (only the user).")
    sub = ap.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("self", help="new email to MY_EMAIL")
    s.add_argument("--subject", required=True)
    r = sub.add_parser("reply", help="reply on a thread to a message MY_EMAIL sent")
    r.add_argument("--message-id", required=True)
    for p in (s, r):
        body = p.add_mutually_exclusive_group(required=True)
        body.add_argument("--html-file")
        body.add_argument("--markdown-file", help="rendered with briefings_mcp.render (the follow-up/briefing renderer)")
        body.add_argument("--text-file")
        p.add_argument("--dry-run", action="store_true", help="pass --dry-run to gws; nothing is sent")
    args = ap.parse_args(argv)

    gws = os.environ.get("GWS") or "gws"
    my_email = _my_email_from_config()
    try:
        if not my_email:
            raise Refused("MY_EMAIL missing from ~/.briefings_config")
        if args.html_file:
            body, html = body_path(args.html_file).read_text(), True
        elif args.markdown_file:
            from .render import md_to_html
            body, html = md_to_html(str(body_path(args.markdown_file))), True
        else:
            body, html = body_path(args.text_file).read_text(), False
        if args.mode == "reply":
            check_reply_target(_message_from(gws, args.message_id), my_email)
            cmd = ["gmail", "+reply", "--message-id", args.message_id, "--body", body]
        else:
            cmd = ["gmail", "+send", "--to", my_email, "--subject", args.subject, "--body", body]
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2
    if html:
        cmd.append("--html")
    if args.dry_run:
        cmd.append("--dry-run")

    rc, out = _gws(gws, cmd)
    data = _parse_gws_output(out)
    if rc != 0 or data is None or "error" in data or (not args.dry_run and "id" not in data):
        print(f"SEND FAILED (rc={rc}): {out.strip()[:400]}", file=sys.stderr)
        return 1
    print(json.dumps(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
