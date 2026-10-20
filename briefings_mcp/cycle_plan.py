"""Deterministic cycle planning for the scheduler and /follow-up.

Every 15 minutes the scheduler used to wake Claude whenever any `*-awaiting-*.md`
file existed, and Claude re-derived, in prose, a set of questions that each have
one right answer: which calendar events are real meetings, which already have a
follow-up, whether the transcript grace period has passed, which awaiting threads
have an unprocessed reply, and which state files have expired. The answers drifted
between cycles (2026-06-06 missed tombstones, 2026-07-02 invented a "delta gate",
2026-10-20 widened the dedup check to a glob and skipped a 1:1 follow-up).

This module answers those questions in code. The scheduler runs it as the
pre-flight gate (Claude only wakes when there is real work), and /follow-up reads
the plan it writes instead of recomputing anything. The judgment work (finding a
transcript, writing the follow-up, interpreting a reply) stays with Claude.

Stdlib only, so it imports even when fastmcp is broken. Pure functions first,
I/O (gws calls, file removal, plan write) in `main()`. Exercised by
`scripts/smoke_test_cycle_plan.py`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from typing import Any, Iterable, Optional

from .replies import classify_message

# State-file kinds (see commands/follow-up.md Step 0 dispatch).
KIND_WHY = "why"
KIND_REPLY = "reply"
KIND_DIGEST = "digest"
KIND_TRANSCRIPT = "transcript"

# Meeting statuses.
M_NOT_MEETING = "not_meeting"
M_NOT_ENDED = "not_ended"
M_OUT_OF_WINDOW = "out_of_window"
M_HANDLED = "handled"
M_PROCEED = "proceed"

# Thread statuses. Only T_NEW and T_UNKNOWN need Claude.
T_NO_REPLY = "no_reply"
T_PROCESSED = "processed"
T_BOT_OWN = "bot_own"
T_THIRD_PARTY = "third_party"
T_NEW = "new"
T_UNKNOWN = "unknown"
T_MISSING = "thread_missing"
T_INVALID = "invalid"
ACTIONABLE_THREAD_STATUSES = (T_NEW, T_UNKNOWN)

FOLLOWUP_WINDOW = timedelta(days=2)
TRANSCRIPT_GRACE = timedelta(minutes=75)
EXPIRY = {KIND_REPLY: ("created_at", 30), KIND_DIGEST: ("created_at", 30), KIND_TRANSCRIPT: ("requested_at", 7)}


class FetchError(Exception):
    """A thread could not be fetched. `missing=True` means Gmail says it no longer exists."""

    def __init__(self, message: str, missing: bool = False):
        super().__init__(message)
        self.missing = missing


# ── parsing helpers ──────────────────────────────────────────────────────────

_TAG_RE = re.compile(r"\[[^\]]*\]")


def slugify(title: str, max_len: int = 60) -> str:
    """Kebab-case a meeting title for state-file names. Strips [tags]; never empty."""
    s = _TAG_RE.sub(" ", title or "").lower().replace("'", "").replace("’", "")
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    if len(s) > max_len:
        s = s[:max_len].rsplit("-", 1)[0] if "-" in s[:max_len] else s[:max_len]
    return s or "meeting"


def parse_state_file(text: str) -> dict[str, Any]:
    """Flat `key: value` frontmatter. Values that look like JSON lists/objects are decoded."""
    out: dict[str, Any] = {}
    for line in (text or "").splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]?(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val[:1] in "[{":
            try:
                val = json.loads(val)
            except ValueError:
                pass
        out[key] = val
    return out


def classify_state_file(name: str, text: Optional[str] = None) -> Optional[str]:
    """Map an `*-awaiting-*.md` basename to its Step 0 branch, or None if it isn't one.

    Content beats the name when given: a transcript request carries `requested_at`,
    so a meeting whose slug happens to start with `reply-` is still classified right.
    """
    if "-awaiting-" not in name or not name.endswith(".md"):
        return None
    if text is not None and "requested_at" in parse_state_file(text):
        return KIND_TRANSCRIPT
    if "-awaiting-why-" in name:
        return KIND_WHY
    if "-awaiting-reply-" in name:
        return KIND_REPLY
    if "-awaiting-digest" in name:
        return KIND_DIGEST
    return KIND_TRANSCRIPT


def parse_ts(value: Any) -> Optional[datetime]:
    """ISO timestamp → aware datetime. Naive values are local time. None if unparseable."""
    if not isinstance(value, str) or not value.strip():
        return None
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.astimezone()


def _local(dt: datetime, tz: Optional[tzinfo]) -> datetime:
    return dt.astimezone(tz) if tz else dt.astimezone()


# ── meetings ─────────────────────────────────────────────────────────────────


def _is_self(att: dict, my_email: str) -> bool:
    return bool(att.get("self")) or (att.get("email") or "").lower() == my_email.lower()


def real_meeting_reason(ev: dict, my_email: str) -> Optional[str]:
    """None if the event is a real meeting, else the reason it isn't."""
    etype = ev.get("eventType") or "default"
    if etype != "default":
        return f"eventType={etype}"
    if not (ev.get("start") or {}).get("dateTime") or not (ev.get("end") or {}).get("dateTime"):
        return "all-day"
    attendees = ev.get("attendees") or []
    others = [a for a in attendees if not _is_self(a, my_email) and not a.get("resource")]
    if not others:
        return "no other attendees"
    me = next((a for a in attendees if _is_self(a, my_email)), None)
    if me and me.get("responseStatus") == "declined":
        return "declined"
    return None


_STAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}-\d{4})-(followup|awaiting)-(.+)\.md$")
TZ_SLACK = timedelta(hours=14)


def _handled_by(stamp: str, slug: str, files: set[str], stamp_unique: bool) -> Optional[str]:
    """The file that shows this meeting already has a follow-up or a transcript request.

    Exact paths first. A pre-meeting briefing's `-awaiting-reply-briefing-` file and a
    post-follow-up `-awaiting-reply-` file are never matches: the first must not block
    the follow-up, and the second always sits beside a `-followup-` file.

    Timezone tolerance: the same slug within TZ_SLACK of this stamp also counts (see
    below).

    Legacy fallback: slugs used to be chosen by the model, so an older file may carry a
    different slug for the same meeting. When this is the only real meeting starting at
    that minute, any follow-up or transcript-request file with the same stamp counts.
    """
    for name in (f"{stamp}-followup-{slug}.md", f"{stamp}-awaiting-{slug}.md"):
        if name in files:
            return name
    # Stamps are local time, so after a timezone change the same meeting gets a new
    # stamp. A file with the identical slug whose stamp is within TZ_SLACK of this one
    # is the same meeting; without this, travelling re-opened every handled meeting in
    # the 2-day window and re-sent transcript requests.
    here = datetime.strptime(stamp, "%Y-%m-%d-%H%M")
    for name in sorted(files):
        m = _STAMP_RE.match(name)
        if not m or m.group(3) != slug:
            continue
        if m.group(2) == "awaiting" and classify_state_file(name) != KIND_TRANSCRIPT:
            continue
        if abs(datetime.strptime(m.group(1), "%Y-%m-%d-%H%M") - here) <= TZ_SLACK:
            return name
    if stamp_unique:
        for name in sorted(files):
            if name.startswith(f"{stamp}-followup-") and name.endswith(".md"):
                return name
            if name.startswith(f"{stamp}-awaiting-") and classify_state_file(name) == KIND_TRANSCRIPT:
                return name
    return None


def evaluate_meetings(events: Iterable[dict], now: datetime, files: set[str], my_email: str,
                      tz: Optional[tzinfo] = None) -> list[dict]:
    """One record per event with a status and, for real meetings, stamp/slug/timing."""
    rows: list[dict] = []
    for ev in events:
        row: dict[str, Any] = {
            "title": ev.get("summary", ""),
            "event_id": ev.get("id", ""),
            "html_link": ev.get("htmlLink", ""),
        }
        reason = real_meeting_reason(ev, my_email)
        if reason:
            row.update(status=M_NOT_MEETING, reason=reason)
            rows.append(row)
            continue
        start = parse_ts(ev["start"]["dateTime"])
        end = parse_ts(ev["end"]["dateTime"])
        if not start or not end:
            row.update(status=M_NOT_MEETING, reason="unparseable time")
            rows.append(row)
            continue
        row.update(
            stamp=_local(start, tz).strftime("%Y-%m-%d-%H%M"),
            slug=slugify(row["title"]),
            start=_local(start, tz).isoformat(),
            end=_local(end, tz).isoformat(),
            attendees=[a.get("email", "") for a in ev.get("attendees") or [] if not a.get("resource")],
        )
        rows.append(row)

    stamp_counts: dict[str, int] = {}
    for r in rows:
        if "stamp" in r:
            stamp_counts[r["stamp"]] = stamp_counts.get(r["stamp"], 0) + 1

    for r in rows:
        if "stamp" not in r:
            continue
        end = parse_ts(r["end"])
        if end >= now:
            r.update(status=M_NOT_ENDED)
            continue
        if end < now - FOLLOWUP_WINDOW:
            r.update(status=M_OUT_OF_WINDOW)
            continue
        hit = _handled_by(r["stamp"], r["slug"], files, stamp_counts[r["stamp"]] == 1)
        if hit:
            r.update(status=M_HANDLED, reason=hit)
            continue
        since = now - end
        r.update(
            status=M_PROCEED,
            minutes_since_end=int(since.total_seconds() // 60),
            transcript_request_due=since >= TRANSCRIPT_GRACE,
            followup_file=f"{r['stamp']}-followup-{r['slug']}.md",
            awaiting_file=f"{r['stamp']}-awaiting-{r['slug']}.md",
        )
    return rows


def briefing_needed(events: Iterable[dict], now: datetime, files: set[str], tz: Optional[tzinfo] = None) -> bool:
    """Same rule as the scheduler's original inline gate: a meeting starting in the next
    2h (or in the last 15 min) with no briefing file for its start stamp. /briefing makes
    its own decisions; this only decides whether to wake it."""
    for ev in events:
        attendees = ev.get("attendees") or []
        me = next((a for a in attendees if a.get("self")), None)
        if me and me.get("responseStatus") == "declined":
            continue
        if ev.get("eventType") in ("workingLocation", "outOfOffice", "focusTime"):
            continue
        if len(attendees) < 2:
            continue
        start = parse_ts((ev.get("start") or {}).get("dateTime"))
        if not start or not (ev.get("end") or {}).get("dateTime"):
            continue
        prefix = _local(start, tz).strftime("%Y-%m-%d-%H%M") + "-"
        has_briefing = any(f.startswith(prefix) and "-followup-" not in f and "-awaiting-" not in f for f in files)
        if now - timedelta(minutes=15) <= start <= now + timedelta(hours=2) and not has_briefing:
            return True
    return False


# ── awaiting threads ─────────────────────────────────────────────────────────


def _from_header(message: dict) -> str:
    for h in (message.get("payload") or {}).get("headers") or []:
        if (h.get("name") or "").lower() == "from":
            return h.get("value") or ""
    return ""


def thread_status(messages: list[dict], state: dict, kind: str, my_email: str) -> str:
    """Mirror of follow-up.md Step 0's per-thread decision, on the LAST message only."""
    if not messages:
        return T_UNKNOWN
    # threads.get includes drafts; a half-written reply is not a reply.
    messages = [m for m in messages if "DRAFT" not in (m.get("labelIds") or [])]
    if len(messages) <= 1:
        return T_NO_REPLY
    last = messages[-1]
    last_id = last.get("id", "")
    bot_ids = state.get("bot_sent_ids")
    if isinstance(bot_ids, list) and last_id in bot_ids and state.get("last_processed_msg") != last_id:
        return T_BOT_OWN
    verdict = classify_message(_from_header(last), my_email, state.get("last_processed_msg") or None, last_id)
    if verdict == "skip_watermark":
        return T_PROCESSED
    if verdict == "skip_third_party":
        return T_THIRD_PARTY
    # classify_message's "skip_bot": the user's address with no display name, which is
    # how gws sends look. Gmail replies from the user carry the display name. Applied
    # even when bot_sent_ids exists: a bot send whose id the model forgot to record
    # would otherwise read as a new reply and the bot would answer itself every cycle.
    if verdict == "skip_bot":
        return T_BOT_OWN
    return T_NEW


def is_expired(state: dict, kind: str, now: datetime) -> bool:
    if kind not in EXPIRY:
        return False
    field, days = EXPIRY[kind]
    ts = parse_ts(state.get(field))
    return bool(ts) and now - ts > timedelta(days=days)


def threads_needed(state_files: dict[str, str], now: datetime) -> dict[str, str]:
    """{file: thread_id} for every state file that needs a Gmail thread check."""
    need: dict[str, str] = {}
    for name, text in state_files.items():
        kind = classify_state_file(name, text)
        state = parse_state_file(text)
        if kind in (None, KIND_WHY) or is_expired(state, kind, now):
            continue
        if state.get("thread_id"):
            need[name] = state["thread_id"]
    return need


# ── whole plan ───────────────────────────────────────────────────────────────


def build_plan(events: Optional[list[dict]], now: datetime, state_files: dict[str, str],
               threads: dict[str, Any], my_email: str, tz: Optional[tzinfo] = None,
               other_files: Iterable[str] = ()) -> dict:
    """Combine meetings and state files into the plan the scheduler and /follow-up obey.

    `events=None` means the calendar fetch failed: fail open on both gates.
    `threads` maps thread_id → list of messages, or a FetchError.
    """
    files = set(state_files) | set(other_files)
    issues: list[str] = []
    remove: list[str] = []
    sf_rows: list[dict] = []

    for name in sorted(state_files):
        text = state_files[name]
        kind = classify_state_file(name, text)
        if kind is None:
            continue
        state = parse_state_file(text)
        row: dict[str, Any] = {"file": name, "kind": kind, "thread_id": state.get("thread_id", ""),
                               "meeting": state.get("meeting", ""), "last_msg_id": ""}
        if kind == KIND_WHY:
            row["status"] = "retire"
            remove.append(name)
        elif is_expired(state, kind, now):
            row["status"] = "expired"
            remove.append(name)
        elif not row["thread_id"]:
            row["status"] = T_INVALID
            issues.append(f"{name} has no thread_id, so its replies can never be checked")
        else:
            field = EXPIRY[kind][0]
            if state.get(field) and parse_ts(state.get(field)) is None:
                issues.append(f"{name} has an unreadable {field} ({state.get(field)!r}), so it will never expire")
            got = threads.get(row["thread_id"])
            if isinstance(got, FetchError):
                row["status"] = T_MISSING if got.missing else T_UNKNOWN
                row["error"] = str(got)
                if got.missing:
                    issues.append(f"{name} points at a Gmail thread that no longer exists")
            elif got is None:
                row["status"] = T_UNKNOWN
                row["error"] = "not fetched"
            else:
                row["status"] = thread_status(got, state, kind, my_email)
                row["last_msg_id"] = got[-1].get("id", "") if got else ""
        sf_rows.append(row)

    to_process = [r for r in sf_rows if r["status"] in ACTIONABLE_THREAD_STATUSES]

    if events is None:
        meetings: list[dict] = []
        issues.append("calendar fetch failed; both gates failed open")
        needs_briefing = needs_followup = True
    else:
        meetings = evaluate_meetings(events, now, files, my_email, tz=tz)
        needs_briefing = briefing_needed(events, now, files, tz=tz)
        needs_followup = bool(to_process) or any(m["status"] == M_PROCEED for m in meetings)

    return {
        "generated_at": now.isoformat(),
        "needs_briefing": needs_briefing,
        "needs_followup": needs_followup,
        "calendar_ok": events is not None,
        "meetings": meetings,
        "meetings_to_process": [m for m in meetings if m["status"] == M_PROCEED],
        "state_files": sf_rows,
        "state_files_to_process": to_process,
        "remove": remove,
        "issues": issues,
    }


# ── I/O ──────────────────────────────────────────────────────────────────────


def _parse_gws_output(raw: str) -> Optional[dict]:
    """gws prints a keyring preamble before its JSON; decode from the first brace."""
    brace = (raw or "").find("{")
    try:
        data = json.loads(raw[brace:]) if brace >= 0 else None
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _gws_json(gws: str, args: list[str], timeout: int = 45) -> dict:
    """Run gws and decode its JSON, raising FetchError on any failure."""
    try:
        p = subprocess.run([gws, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise FetchError(f"{type(e).__name__}: {e}")
    data = _parse_gws_output(p.stdout)
    if data is None:
        raise FetchError(f"unparseable gws output (rc={p.returncode}): {(p.stdout or p.stderr)[:200]!r}")
    if "error" in data:
        err = data["error"] or {}
        code = err.get("code")
        raise FetchError(f"gws error {code}: {err.get('message', '')}", missing=code == 404)
    if p.returncode != 0:
        raise FetchError(f"gws rc={p.returncode}: {p.stderr[:200]!r}")
    return data


def fetch_thread(gws: str, thread_id: str) -> Any:
    try:
        data = _gws_json(gws, ["gmail", "users", "threads", "get", "--params", json.dumps({
            "userId": "me", "id": thread_id, "format": "metadata", "metadataHeaders": ["From"],
            "fields": "messages(id,labelIds,payload/headers)"})])
    except FetchError as e:
        return e
    return data.get("messages") or []


def fetch_calendar(gws: str, now: datetime) -> Optional[list[dict]]:
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    params = {"calendarId": "primary", "singleEvents": True, "orderBy": "startTime",
              "timeMin": (now - FOLLOWUP_WINDOW).astimezone(timezone.utc).strftime(fmt),
              "timeMax": (now + timedelta(hours=2)).astimezone(timezone.utc).strftime(fmt)}
    try:
        return _gws_json(gws, ["calendar", "events", "list", "--params", json.dumps(params)]).get("items", [])
    except FetchError:
        return None


def _events_from_text(raw: str) -> Optional[list[dict]]:
    data = _parse_gws_output(raw)
    return data["items"] if data is not None and "items" in data else None


def _my_email_from_config() -> str:
    try:
        for line in Path("~/.briefings_config").expanduser().read_text().splitlines():
            if line.startswith("MY_EMAIL="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


def _log(briefing_dir: Path, message: str) -> None:
    with open(briefing_dir / "scheduler.log", "a") as f:
        f.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M')}] {message}\n")


def write_atomic(path: Path, text: str) -> None:
    """tmp + rename, mode 0600 (same shape as ledger.py's state rewrites)."""
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--briefing-dir", default=os.path.expanduser("~/Briefings"))
    ap.add_argument("--calendar-env", metavar="VAR", help="read the gws calendar JSON from this env var instead of fetching")
    ap.add_argument("--my-email", default="")
    ap.add_argument("--apply", action="store_true", help="delete expired and retired state files (logged)")
    ap.add_argument("--out", help="write the plan JSON here (default <briefing-dir>/.cycle-plan.json)")
    args = ap.parse_args(argv)

    bdir = Path(args.briefing_dir)
    my_email = args.my_email or _my_email_from_config()
    if not my_email:
        print("ERROR: MY_EMAIL not set (pass --my-email or set it in ~/.briefings_config)", file=sys.stderr)
        return 2
    gws = os.environ.get("GWS") or shutil.which("gws") or "/opt/homebrew/bin/gws"
    now = datetime.now().astimezone()

    names = sorted(os.listdir(bdir)) if bdir.is_dir() else []
    state_files = {n: (bdir / n).read_text(errors="replace") for n in names if classify_state_file(n)}
    other = [n for n in names if n not in state_files]

    ids = sorted(set(threads_needed(state_files, now).values()))
    with ThreadPoolExecutor(max_workers=6) as pool:
        calendar = None if args.calendar_env else pool.submit(fetch_calendar, gws, now)
        threads = dict(zip(ids, pool.map(lambda t: fetch_thread(gws, t), ids)))
        events = calendar.result() if calendar else _events_from_text(os.environ.get(args.calendar_env, ""))

    plan = build_plan(events, now, state_files, threads, my_email, other_files=other)

    if args.apply:
        rows = {r["file"]: r for r in plan["state_files"]}
        for name in plan["remove"]:
            r = rows[name]
            try:
                (bdir / name).unlink()
            except FileNotFoundError:
                continue
            if r["status"] == "retire":
                _log(bdir, f"Retiring Phase 1 awaiting-why file: {name} — feature replaced in Phase 2")
            elif r["kind"] == KIND_TRANSCRIPT:
                _log(bdir, f"Transcript request expired for {r['meeting'] or name} — no reply received")
            elif r["kind"] == KIND_DIGEST:
                _log(bdir, f"Awaiting-digest expired — no reply within 30 days for {name}")
            else:
                _log(bdir, f"Awaiting-reply expired for {r['meeting'] or name} — no reply within 30 days")
        plan["removed"] = plan.pop("remove")
    write_atomic(Path(args.out) if args.out else bdir / ".cycle-plan.json", json.dumps(plan, indent=2) + "\n")

    counts: dict[str, int] = {}
    for r in plan["state_files"]:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(f"NEED_BRIEFING={int(plan['needs_briefing'])}")
    print(f"NEED_FOLLOWUP={int(plan['needs_followup'])}")
    print(f"SUMMARY=meetings to process: {len(plan['meetings_to_process'])}; state files: "
          + (", ".join(f"{v} {k}" for k, v in sorted(counts.items())) or "none")
          + (f"; issues: {len(plan['issues'])}" if plan["issues"] else ""))
    for issue in plan["issues"]:
        print(f"ISSUE={issue}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
