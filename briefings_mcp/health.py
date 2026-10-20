"""Weekly health email: what the system did, and what needs a look.

The scheduler's Monday branch used to send a health summary to Slack only. Slack
delivery has been off since 2026-08-05, so the summary had been silently dropped
for months. This builds an email instead: cycle counts and failures from
scheduler.log, the week's ATTENTION flags, problems the cycle plan found in state
files, and what the Monday housekeeping pruned. The subject line says whether
anything needs a look, so a quiet week can be skimmed and archived.

Exercised by `scripts/smoke_test_cycle_plan.py`.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable, Optional

from . import attention

_TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\]")


def count_log(lines: Iterable[str], since: datetime) -> dict[str, int]:
    """Bucket scheduler.log lines from the last week. Same buckets as the old Slack summary."""
    c = dict(cycles=0, skipped=0, ran=0, succeeded=0, timeout=0, auth=0, permission=0, other=0, escalation=0, sleep=0)
    since = since.replace(tzinfo=None)
    for line in lines:
        m = _TS_RE.match(line)
        if not m:
            continue
        try:
            ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M")
        except ValueError:
            continue
        if ts < since:
            continue
        if "streak escalation" in line:
            c["escalation"] += 1
        elif "skipped Claude" in line:
            c["skipped"] += 1
        elif "Running:" in line:
            c["ran"] += 1
        elif "host-sleep majority" in line:
            c["sleep"] += 1
        elif "timed out" in line:
            c["timeout"] += 1
        elif "auth failure" in line or "OAuth token" in line:
            c["auth"] += 1
        elif "permission prompt" in line:
            c["permission"] += 1
        elif "ERROR:" in line:
            c["other"] += 1
    c["cycles"] = c["skipped"] + c["ran"]
    # Not a count of "Done." lines: headless runs write their own "[ts] Done." lines
    # to the same log, which made the old Slack summary report more successes than runs.
    c["succeeded"] = max(0, c["ran"] - c["timeout"] - c["auth"] - c["permission"] - c["other"] - c["sleep"])
    return c


def build_report(log_lines: Iterable[str], now: datetime, plan: Optional[dict], flags: list[dict],
                 housekeeping: dict) -> tuple[str, str]:
    since = now - timedelta(days=7)
    c = count_log(log_lines, since)
    failures = c["timeout"] + c["auth"] + c["permission"] + c["other"]

    look: list[str] = []
    if failures:
        kinds = ", ".join(f"{c[k]} {k}" for k in ("timeout", "auth", "permission", "other") if c[k])
        look.append(f"{failures} failed cycle(s) ({kinds}). See ~/Briefings/scheduler.log.")
    for issue in (plan or {}).get("issues", []):
        look.append(f"State file problem: {issue}")
    seen = set()
    for f in flags:
        if f["key"] in seen:
            continue
        seen.add(f["key"])
        when = datetime.fromisoformat(f["ts"]).strftime("%a %H:%M")
        look.append(f"Flagged by the {f.get('label', 'scheduler')} run ({when}): {f['text']}")
    if plan is None:
        look.append("No cycle plan on disk, so the state-file check below is missing. The plan helper may be failing.")

    subject = ("Meeting-intelligence weekly: " +
               (f"{len(look)} thing{'s' if len(look) != 1 else ''} to look at" if look else "all quiet"))

    def ul(items: list[str]) -> str:
        return "<ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>"

    parts = [f"<p>Week to {now.strftime('%a %-d %b')}.</p>"]
    parts.append("<h3>Needs a look</h3>" + (ul(look) if look else "<p>Nothing.</p>"))
    activity = [
        f"{c['cycles']} scheduler cycles: {c['ran']} woke Claude, {c['skipped']} had nothing to do.",
        f"{c['succeeded']} Claude runs succeeded, {failures} failed"
        + (f", {c['sleep']} skipped because the Mac was asleep." if c["sleep"] else "."),
    ]
    if c["escalation"]:
        activity.append(f"{c['escalation']} repeat-failure escalation(s) fired.")
    parts.append("<h3>Activity</h3>" + ul(activity))

    hk = []
    if housekeeping.get("cleaned") is not None:
        hk.append(f"Removed {housekeeping['cleaned']} state and briefing files older than 30 days.")
    if housekeeping.get("expired") is not None:
        hk.append(f"Auto-expired {housekeeping['expired']} stale commitment(s) from the ledger.")
    if housekeeping.get("token_expires"):
        hk.append(f"The scheduler's Claude token expires around {housekeeping['token_expires']}.")
    if hk:
        parts.append("<h3>Housekeeping</h3>" + ul(hk))

    if plan is not None:
        by_kind: dict[str, int] = {}
        for r in plan.get("state_files", []):
            by_kind[r["kind"]] = by_kind.get(r["kind"], 0) + 1
        waiting = ", ".join(f"{v} {k}" for k, v in sorted(by_kind.items())) or "none"
        parts.append("<h3>Waiting on you</h3>" + ul([
            f"Open reply threads: {waiting}. Each expires on its own (30 days for replies and digests, 7 for transcript requests)."]))
    return subject, "".join(parts)


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Build the weekly health email (prints JSON with subject and html).")
    ap.add_argument("--briefing-dir", default=os.path.expanduser("~/Briefings"))
    ap.add_argument("--cleaned", type=int)
    ap.add_argument("--expired", type=int)
    ap.add_argument("--token-expires", default="")
    args = ap.parse_args(argv)

    bdir = Path(args.briefing_dir)
    now = datetime.now().astimezone()
    log_lines: list[str] = []
    for name in ("scheduler.log.1", "scheduler.log"):
        try:
            log_lines += (bdir / name).read_text(errors="replace").splitlines()
        except OSError:
            pass
    try:
        plan = json.loads((bdir / ".cycle-plan.json").read_text())
    except (OSError, ValueError):
        plan = None
    flags = attention.records_since(bdir / attention.RECORD_FILE, now - timedelta(days=7))
    subject, body = build_report(log_lines, now, plan, flags, {
        "cleaned": args.cleaned, "expired": args.expired, "token_expires": args.token_expires})
    print(json.dumps({"subject": subject, "html": body}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
