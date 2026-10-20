"""ATTENTION lines: how a headless run tells Mark the system itself needs a look.

On 2026-10-20 a scheduler cycle spotted that its own dedup rule was skipping a
1:1 follow-up, said so clearly, and the only place that sentence went was
scheduler.log. The scheduler prompt now asks Claude to put anything like that on a
line starting `ATTENTION:`. scheduler.sh pipes each run's output through this
module, which decides what to email:

- the same point (compared case- and whitespace-insensitively) is emailed at most
  once a week, so a model that repeats itself every 15 minutes doesn't flood;
- at most DAILY_EMAIL_CAP attention emails go out per day, because a model that
  rephrases the same point each cycle would get past the first rule;
- every line is recorded in attention.jsonl either way, and the weekly health
  email lists the week's lines, so nothing suppressed is lost.

Exercised by `scripts/smoke_test_cycle_plan.py`.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from .cycle_plan import write_atomic

RECORD_FILE = "attention.jsonl"
REPEAT_WINDOW = timedelta(days=7)
RETENTION = timedelta(days=30)
DAILY_EMAIL_CAP = 2

# Tolerates markdown decoration a model may add: "- ATTENTION:", "**ATTENTION:**", "> ATTENTION:".
_ATTENTION_RE = re.compile(r"^[ \t>*_\-]*ATTENTION:[*_]*[ \t]*(\S.*?)[ \t*_]*$", re.IGNORECASE | re.MULTILINE)


def extract_attention(output: str) -> list[str]:
    """Lines a headless run flagged with a leading `ATTENTION:`, de-duplicated, in order."""
    seen: list[str] = []
    for m in _ATTENTION_RE.finditer(output or ""):
        if m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


def attention_key(text: str) -> str:
    norm = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
    return hashlib.sha1(norm.encode()).hexdigest()[:16]


def triage(lines: list[str], records: list[dict], now: datetime) -> tuple[list[str], list[tuple[str, str]]]:
    """Split new ATTENTION lines into (to_email, [(line, reason_suppressed)])."""
    recent_sent = {
        r["key"] for r in records
        if r.get("emailed") and now - datetime.fromisoformat(r["ts"]) < REPEAT_WINDOW
    }
    emails_today = len({
        r["ts"][:16] for r in records
        if r.get("emailed") and datetime.fromisoformat(r["ts"]).date() == now.date()
    })
    fresh, suppressed = [], []
    for line in lines:
        if attention_key(line) in recent_sent:
            suppressed.append((line, "already emailed this week"))
        else:
            fresh.append(line)
    if fresh and emails_today >= DAILY_EMAIL_CAP:
        suppressed += [(line, f"daily cap of {DAILY_EMAIL_CAP} attention emails reached") for line in fresh]
        fresh = []
    return fresh, suppressed


def _save(path: Path, records: list[dict], new: list[dict], now: datetime) -> None:
    # Rewrite rather than append so the file stays bounded at RETENTION of history
    # (longer than the weekly email and the repeat window both need).
    kept = [r for r in records if now - datetime.fromisoformat(r["ts"]) < RETENTION] + new
    write_atomic(path, "".join(json.dumps(r) + "\n" for r in kept))


def mark_sent(path: Path, ts: str, keys: list[str]) -> None:
    records = load_records(path)
    for r in records:
        if r["ts"] == ts and r["key"] in keys:
            r["emailed"] = True
    write_atomic(path, "".join(json.dumps(r) + "\n" for r in records))


def load_records(path: Path) -> list[dict]:
    out = []
    try:
        for raw in path.read_text().splitlines():
            try:
                out.append(json.loads(raw))
            except ValueError:
                continue
    except OSError:
        pass
    return out


def records_since(path: Path, since: datetime) -> list[dict]:
    return [r for r in load_records(path) if datetime.fromisoformat(r["ts"]) >= since]


def render_email(lines: list[str], label: str, now: datetime) -> tuple[str, str]:
    first = lines[0] if len(lines[0]) <= 70 else lines[0][:67] + "..."
    subject = f"Meeting-intelligence needs a look: {first}"
    items = "".join(f"<li>{html.escape(line)}</li>" for line in lines)
    body = (
        f"<p>The {html.escape(label)} run at {now.strftime('%H:%M on %a %-d %b')} flagged "
        f"{'this' if len(lines) == 1 else 'these'} about the system itself:</p><ul>{items}</ul>"
        "<p>Details are in <code>~/Briefings/scheduler.log</code> around that time. "
        "The same point won't be emailed again for a week, and the weekly health email lists every flag.</p>"
    )
    return subject, body


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Triage ATTENTION lines from a headless run (output on stdin).")
    ap.add_argument("--briefing-dir", default=os.path.expanduser("~/Briefings"))
    ap.add_argument("--label", default="scheduler")
    ap.add_argument("--mark-sent", metavar="TS", help="after a successful send: mark this run's lines (keys on stdin) as emailed")
    args = ap.parse_args(argv)
    path = Path(args.briefing_dir) / RECORD_FILE

    if args.mark_sent:
        mark_sent(path, args.mark_sent, sys.stdin.read().split())
        return 0

    now = datetime.now().astimezone().replace(microsecond=0)
    lines = extract_attention(sys.stdin.read())
    if not lines:
        print(json.dumps({"send": [], "suppressed": []}))
        return 0
    records = load_records(path)
    to_send, suppressed = triage(lines, records, now)
    # Recorded as not emailed; scheduler.sh calls --mark-sent only after Gmail accepts
    # the send, so a failed send doesn't mute the same point for a week.
    new = [{"ts": now.isoformat(), "key": attention_key(l), "text": l, "label": args.label, "emailed": False}
           for l in lines]
    _save(path, records, new, now)
    result: dict = {"send": to_send, "suppressed": [{"text": l, "reason": r} for l, r in suppressed]}
    if to_send:
        result["subject"], result["html"] = render_email(to_send, args.label, now)
        result["ts"] = now.isoformat()
        result["keys"] = " ".join(attention_key(l) for l in to_send)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
