"""Smoke test for briefings_mcp.cycle_plan — the deterministic half of each cycle.

`cycle_plan` decides, in code, everything about a /follow-up cycle that has a
right answer: which calendar events are real meetings, which already have a
follow-up, whether the 75-minute transcript grace has passed, and which
awaiting-* threads have a reply nobody has processed. The scheduler uses it to
decide whether to wake Claude at all; /follow-up reads its output instead of
re-deriving those answers in prose.

Every fixture below is a decision the LLM used to make on its own and, at least
once, made wrongly:

- 2026-10-20: the dedup check was widened to a glob, matched the pre-meeting
  briefing's `-awaiting-reply-briefing-` file, and silently skipped a 1:1 follow-up.
- 2026-06-06: the dedup check missed cancellation tombstones and re-fired
  transcript requests.
- 2026-07-02 onward: an invented "delta gate" sometimes replaced per-thread checks.

Run directly via `python scripts/smoke_test_cycle_plan.py` or as part of
`verify-v1.sh`.
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import attention as att  # noqa: E402
from briefings_mcp import cycle_plan as cp  # noqa: E402
from briefings_mcp import health  # noqa: E402

MY = "you@example.com"
LISBON = timezone(timedelta(hours=1))  # WEST, fixed so the test is TZ-stable
NOW = datetime(2026, 10, 20, 12, 7, tzinfo=LISBON)

results: list[tuple[str, bool, str]] = []


def check(name, got, want):
    ok = got == want
    results.append((name, ok, "" if ok else f"got {got!r}, want {want!r}"))


def event(summary, start, end, attendees=None, **extra):
    ev = {
        "id": summary.lower().replace(" ", "")[:12],
        "summary": summary,
        "start": {"dateTime": start.isoformat()},
        "end": {"dateTime": end.isoformat()},
        "htmlLink": "https://calendar.example/" + summary,
        "attendees": attendees if attendees is not None else [
            {"email": MY, "self": True, "responseStatus": "accepted"},
            {"email": "sam@example.com", "responseStatus": "accepted"},
        ],
    }
    ev.update(extra)
    return ev


def at(h, m, day=20):
    return datetime(2026, 10, day, h, m, tzinfo=LISBON)


def meeting_status(events, files, now=NOW):
    return {m["title"]: m["status"] for m in cp.evaluate_meetings(events, now, set(files), MY, tz=LISBON)}


# ── slugify ───────────────────────────────────────────────────────────────────
check("slug: fortnightly 1:1", cp.slugify("Alex / Sam - Fortnightly 1:1"), "alex-sam-fortnightly-1-1")
check("slug: trailing punctuation", cp.slugify("Kicking Off?"), "kicking-off")
check("slug: meeting-class tags stripped", cp.slugify("[coaching] Weekly with Ana"), "weekly-with-ana")
check("slug: ampersand", cp.slugify("Catchup - Sam & Alex"), "catchup-sam-alex")
check("slug: long titles cut on a word boundary",
      len(cp.slugify("Jordan Example (Acme) <> Pat Sample & Robin Placeholder (Example Partners) quarterly")) <= 60, True)
check("slug: never empty", cp.slugify("???"), "meeting")

# ── state-file classification ─────────────────────────────────────────────────
check("kind: why", cp.classify_state_file("2026-05-01-0900-awaiting-why-x.md"), cp.KIND_WHY)
check("kind: reply", cp.classify_state_file("2026-10-14-1515-awaiting-reply-catchup-sam-alex.md"), cp.KIND_REPLY)
check("kind: briefing reply", cp.classify_state_file("2026-10-20-1030-awaiting-reply-briefing-alex.md"), cp.KIND_REPLY)
# The digest basename has no trailing dash; the old prose rule ("contains
# -awaiting-digest-") would have routed it to the transcript branch.
check("kind: digest (no trailing dash)", cp.classify_state_file("2026-10-19-1000-awaiting-digest.md"), cp.KIND_DIGEST)
check("kind: transcript", cp.classify_state_file("2026-10-20-1030-awaiting-alex-sam-fortnightly-1-1.md"), cp.KIND_TRANSCRIPT)
check("kind: not a state file", cp.classify_state_file("2026-10-20-1030-alex-sam-fortnightly-1-1.md"), None)
check("kind: content wins over a 'reply-' meeting slug",
      cp.classify_state_file("2026-10-20-1030-awaiting-reply-strategy.md", "thread_id: x\nrequested_at: 2026-10-20T10:00:00Z\n"),
      cp.KIND_TRANSCRIPT)

parsed = cp.parse_state_file('thread_id: abc\nlast_processed_msg:\nbot_sent_ids: ["m1", "m2"]\nmeeting: A: B\n')
check("parse: empty value", parsed.get("last_processed_msg"), "")
check("parse: JSON list", parsed.get("bot_sent_ids"), ["m1", "m2"])
check("parse: colon inside value", parsed.get("meeting"), "A: B")

# ── meeting qualification + dedup ─────────────────────────────────────────────
one_to_one = event("Alex / Sam - Fortnightly 1:1", at(10, 30), at(11, 0))

# THE 2026-10-20 BUG: only the pre-meeting briefing's state file exists.
check("dedup: briefing awaiting-reply file does NOT suppress the follow-up",
      meeting_status([one_to_one], ["2026-10-20-1030-awaiting-reply-briefing-alex-sam-fortnightly-1-1.md",
                              "2026-10-20-1030-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_PROCEED)
check("dedup: transcript-request file suppresses",
      meeting_status([one_to_one], ["2026-10-20-1030-awaiting-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_HANDLED)
check("dedup: follow-up file suppresses",
      meeting_status([one_to_one], ["2026-10-20-1030-followup-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_HANDLED)
# THE 2026-06-06 BUG: a cancellation tombstone is a follow-up file and must suppress.
check("dedup: tombstone follow-up suppresses",
      meeting_status([one_to_one], ["2026-10-20-1030-followup-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_HANDLED)
check("dedup: post-follow-up awaiting-reply alone does not suppress (follow-up file covers it)",
      meeting_status([one_to_one], ["2026-10-20-1030-awaiting-reply-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_PROCEED)

# Legacy LLM-chosen slugs differ from slugify(); same start stamp still dedups
# when it is the only real meeting at that time.
partners = event("Jordan Example (Acme) <> Pat Sample & Robin Placeholder (Example Partners)", at(13, 0, 19), at(13, 45, 19))
check("dedup: legacy slug, unique stamp → handled",
      meeting_status([partners], ["2026-10-19-1300-followup-jordan-example-pat-sample-robin-placeholder.md"])[partners["summary"]],
      cp.M_HANDLED)
other_same_time = event("Board prep", at(13, 0, 19), at(13, 30, 19))
st = meeting_status([partners, other_same_time], ["2026-10-19-1300-followup-jordan-example-pat-sample-robin-placeholder.md"])
check("dedup: legacy slug, shared stamp → not assumed handled", st["Board prep"], cp.M_PROCEED)

# Real-meeting filter
lunch = event("Lunch", at(12, 0), at(12, 5), attendees=[])
home = event("Home", at(9, 0), at(17, 0), eventType="workingLocation")
declined = event("Declined sync", at(9, 0), at(9, 30), attendees=[
    {"email": MY, "self": True, "responseStatus": "declined"}, {"email": "x@example.com"}])
room_only = event("Desk booking", at(9, 0), at(9, 30), attendees=[
    {"email": MY, "self": True, "responseStatus": "accepted"},
    {"email": "room@resource.calendar.google.com", "resource": True}])
holiday = {"summary": "Matt T Holiday", "start": {"date": "2026-10-20"}, "end": {"date": "2026-10-21"}}
st = meeting_status([lunch, home, declined, room_only, holiday], [])
check("filter: solo block", st["Lunch"], cp.M_NOT_MEETING)
check("filter: workingLocation", st["Home"], cp.M_NOT_MEETING)
check("filter: declined", st["Declined sync"], cp.M_NOT_MEETING)
check("filter: only a room resource", st["Desk booking"], cp.M_NOT_MEETING)
check("filter: all-day", st["Matt T Holiday"], cp.M_NOT_MEETING)

# Timing
in_progress = event("Still going", at(11, 30), at(12, 30))
check("timing: in progress", meeting_status([in_progress], [])["Still going"], cp.M_NOT_ENDED)
m74 = cp.evaluate_meetings([event("A", at(10, 0), NOW - timedelta(minutes=74))], NOW, set(), MY, tz=LISBON)[0]
m75 = cp.evaluate_meetings([event("A", at(10, 0), NOW - timedelta(minutes=75))], NOW, set(), MY, tz=LISBON)[0]
check("grace: 74 min → no transcript request yet", m74["transcript_request_due"], False)
check("grace: 75 min → transcript request due", m75["transcript_request_due"], True)
old = event("Old", at(9, 0, 17), at(9, 30, 17))
check("window: ended >2 days ago", meeting_status([old], [])["Old"], cp.M_OUT_OF_WINDOW)
check("stamp uses local start time", cp.evaluate_meetings([one_to_one], NOW, set(), MY, tz=LISBON)[0]["stamp"], "2026-10-20-1030")

# ── thread status ─────────────────────────────────────────────────────────────
def msg(mid, frm=f"<{MY}>"):
    return {"id": mid, "payload": {"headers": [{"name": "From", "value": frm}]}}


user = f"Me <{MY}>"
check("thread: only the bot send", cp.thread_status([msg("t1")], {}, cp.KIND_REPLY, MY), cp.T_NO_REPLY)
check("thread: new user reply", cp.thread_status([msg("t1"), msg("u1", user)], {"bot_sent_ids": ["t1"]}, cp.KIND_REPLY, MY), cp.T_NEW)
check("thread: watermark matches", cp.thread_status([msg("t1"), msg("u1", user)], {"last_processed_msg": "u1"}, cp.KIND_REPLY, MY), cp.T_PROCESSED)
check("thread: empty watermark never matches", cp.thread_status([msg("t1"), msg("u1", user)], {"last_processed_msg": ""}, cp.KIND_REPLY, MY), cp.T_NEW)
check("thread: last is a bot send (bot_sent_ids)",
      cp.thread_status([msg("t1"), msg("u1", user), msg("b2", user)], {"bot_sent_ids": ["t1", "b2"], "last_processed_msg": "u1"}, cp.KIND_REPLY, MY),
      cp.T_BOT_OWN)
check("thread: legacy file, bare From → bot", cp.thread_status([msg("t1"), msg("b2")], {}, cp.KIND_REPLY, MY), cp.T_BOT_OWN)
check("thread: third-party reply", cp.thread_status([msg("t1"), msg("x1", "Eve <eve@evil.example>")], {"bot_sent_ids": ["t1"]}, cp.KIND_REPLY, MY), cp.T_THIRD_PARTY)
check("thread: transcript reply is new", cp.thread_status([msg("t1"), msg("u1", user)], {}, cp.KIND_TRANSCRIPT, MY), cp.T_NEW)
# "extend" on a transcript request now writes a watermark; before, every cycle re-read
# the same reply and pushed the expiry forward forever.
check("thread: transcript reply already handled (extend)",
      cp.thread_status([msg("t1"), msg("u1", user)], {"last_processed_msg": "u1"}, cp.KIND_TRANSCRIPT, MY), cp.T_PROCESSED)
check("thread: no messages → unknown", cp.thread_status([], {}, cp.KIND_REPLY, MY), cp.T_UNKNOWN)

# ── expiry ────────────────────────────────────────────────────────────────────
iso = lambda d: d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
check("expiry: reply at 29 days", cp.is_expired({"created_at": iso(NOW - timedelta(days=29))}, cp.KIND_REPLY, NOW), False)
check("expiry: reply at 31 days", cp.is_expired({"created_at": iso(NOW - timedelta(days=31))}, cp.KIND_REPLY, NOW), True)
check("expiry: digest at 31 days", cp.is_expired({"created_at": iso(NOW - timedelta(days=31))}, cp.KIND_DIGEST, NOW), True)
check("expiry: transcript at 6 days", cp.is_expired({"requested_at": iso(NOW - timedelta(days=6))}, cp.KIND_TRANSCRIPT, NOW), False)
check("expiry: transcript at 8 days", cp.is_expired({"requested_at": iso(NOW - timedelta(days=8))}, cp.KIND_TRANSCRIPT, NOW), True)
check("expiry: unparseable timestamp never expires", cp.is_expired({"created_at": "soon"}, cp.KIND_REPLY, NOW), False)

# ── whole-cycle plan + gate ───────────────────────────────────────────────────
state_files = {
    "2026-10-20-1030-awaiting-reply-briefing-alex-sam-fortnightly-1-1.md": "thread_id: tb\ncreated_at: 2026-10-20T09:38:19Z\nlast_processed_msg:\n",
    "2026-10-19-1000-awaiting-digest.md": 'thread_id: td\ncreated_at: 2026-10-19T12:13:20Z\nbot_sent_ids: ["td"]\nlast_processed_msg:\n',
    "2026-09-01-1000-awaiting-reply-old.md": "thread_id: to\ncreated_at: 2026-09-01T10:00:00Z\n",
    "2026-05-01-0900-awaiting-why-x.md": "thread_id: tw\n",
}
threads = {"tb": [msg("tb")], "td": [msg("td")]}
plan = cp.build_plan([one_to_one, lunch], NOW, state_files, threads, MY, tz=LISBON)
check("plan: the 1:1 proceeds despite briefing file", [m["title"] for m in plan["meetings_to_process"]], ["Alex / Sam - Fortnightly 1:1"])
check("plan: expired + retired files listed for removal",
      sorted(plan["remove"]), ["2026-05-01-0900-awaiting-why-x.md", "2026-09-01-1000-awaiting-reply-old.md"])
check("plan: no reply threads → nothing to act on", plan["state_files_to_process"], [])
check("plan: gate wakes Claude for the meeting", plan["needs_followup"], True)

quiet = cp.build_plan([lunch], NOW, {k: v for k, v in state_files.items() if "digest" in k}, threads, MY, tz=LISBON)
check("gate: 31 idle awaiting files no longer wake Claude", quiet["needs_followup"], False)

replied = cp.build_plan([], NOW, {"2026-10-19-1000-awaiting-digest.md": state_files["2026-10-19-1000-awaiting-digest.md"]},
                        {"td": [msg("td"), msg("u9", user)]}, MY, tz=LISBON)
check("gate: a real reply wakes Claude", replied["needs_followup"], True)
check("plan: the reply is listed with its message id",
      [(s["file"], s["last_msg_id"]) for s in replied["state_files_to_process"]], [("2026-10-19-1000-awaiting-digest.md", "u9")])

broken = cp.build_plan([], NOW, {"2026-10-19-1000-awaiting-digest.md": state_files["2026-10-19-1000-awaiting-digest.md"]},
                       {"td": cp.FetchError("network")}, MY, tz=LISBON)
check("gate: fetch failure fails open", broken["needs_followup"], True)
check("plan: fetch failure is listed for a manual check", broken["state_files_to_process"][0]["status"], cp.T_UNKNOWN)

gone = cp.build_plan([], NOW, {"2026-10-19-1000-awaiting-digest.md": state_files["2026-10-19-1000-awaiting-digest.md"]},
                     {"td": cp.FetchError("missing", missing=True)}, MY, tz=LISBON)
check("gate: deleted thread does not wake Claude every cycle", gone["needs_followup"], False)
check("plan: deleted thread surfaces as an issue", len(gone["issues"]), 1)

# ── briefing gate parity with the old inline scheduler gate ──────────────────
soon = event("Soon", NOW + timedelta(minutes=30), NOW + timedelta(minutes=60))
check("briefing: upcoming meeting, no file", cp.briefing_needed([soon], NOW, set()), True)
check("briefing: upcoming meeting, file exists",
      cp.briefing_needed([soon], NOW, {(NOW + timedelta(minutes=30)).astimezone().strftime("%Y-%m-%d-%H%M") + "-soon.md"}), False)
check("briefing: solo block ignored", cp.briefing_needed([event("Gym", NOW + timedelta(minutes=30), NOW + timedelta(minutes=60), attendees=[])], NOW, set()), False)

# ── ATTENTION lines from headless output ─────────────────────────────────────
out = "Step 0 done.\nATTENTION: dedup glob matches briefing files\n  attention: lower-case ok too\nNot ATTENTION: mid-line\nATTENTION:\n"
check("attention: extracted", att.extract_attention(out), ["dedup glob matches briefing files", "lower-case ok too"])
check("attention: none", att.extract_attention("all fine"), [])

def rec(text, hours_ago, emailed=True):
    return {"ts": (NOW - timedelta(hours=hours_ago)).isoformat(), "key": att.attention_key(text), "text": text, "emailed": emailed}

send, sup = att.triage(["Dedup glob is wrong"], [], NOW)
check("attention: first sighting is emailed", send, ["Dedup glob is wrong"])
send, sup = att.triage(["dedup  glob is WRONG."], [rec("Dedup glob is wrong", 3)], NOW)
check("attention: same point, different case/spacing → suppressed", (send, len(sup)), ([], 1))
send, sup = att.triage(["Dedup glob is wrong"], [rec("Dedup glob is wrong", 24 * 8)], NOW)
check("attention: re-emailed after a week", send, ["Dedup glob is wrong"])
send, sup = att.triage(["A third distinct problem"], [rec("one", 1), rec("two", 2)], NOW)
check("attention: daily cap holds back a rephrasing model", (send, sup[0][1].startswith("daily cap")), ([], True))
send, sup = att.triage(["New problem"], [rec("one", 1), rec("two", 2, emailed=False)], NOW)
check("attention: suppressed lines don't count toward the cap", send, ["New problem"])
subj, body = att.render_email(["<script>x</script> broke"], "follow-up", NOW)
check("attention: email body is HTML-escaped", "<script>" in body, False)

# ── weekly health email ──────────────────────────────────────────────────────
log = [
    "[2026-10-19 09:00] Pre-flight: nothing to do, skipped Claude.",
    "[2026-10-19 09:15] Running: follow-up",
    "[2026-10-19 09:16] Done.",
    "[2026-10-19 09:30] Running: follow-up",
    "[2026-10-19 09:45] ERROR: follow-up timed out after 900s (Claude killed).",
    "[2026-10-01 09:00] ERROR: ancient failure outside the week",
]
c = health.count_log(log, NOW - timedelta(days=7))
check("health: counts", (c["cycles"], c["ran"], c["skipped"], c["succeeded"], c["timeout"], c["other"]), (3, 2, 1, 1, 1, 0))
c = health.count_log(log + ["[2026-10-19 09:16] Done.", "[2026-10-19 09:17] Done."], NOW - timedelta(days=7))
check("health: the model's own 'Done.' log lines don't inflate successes", c["succeeded"], 1)
quiet_plan = {"issues": [], "state_files": [{"kind": "reply"}]}
subj, _ = health.build_report(log[:3], NOW, quiet_plan, [], {})
check("health: quiet week subject", subj, "Meeting-intelligence weekly: all quiet")
subj, body = health.build_report(log, NOW, {"issues": ["x.md points at a Gmail thread that no longer exists"], "state_files": []},
                                 [rec("Dedup glob is wrong", 5)], {"cleaned": 4, "expired": 0})
check("health: failures + issues + flags all surface", subj, "Meeting-intelligence weekly: 3 things to look at")
check("health: housekeeping reported", "Removed 4 state and briefing files" in body, True)
subj, _ = health.build_report([], NOW, None, [], {})
check("health: a missing plan is itself flagged", subj.endswith("1 thing to look at"), True)


# ── review fixes (2026-10-20) ────────────────────────────────────────────────
# Timezone change: the same meeting viewed from New York gets a different local stamp.
NY = timezone(timedelta(hours=-4))
tz_files = {"2026-10-20-1030-followup-alex-sam-fortnightly-1-1.md"}
check("tz: handled file found after travelling west",
      {m["title"]: m["status"] for m in cp.evaluate_meetings([one_to_one], NOW, tz_files, MY, tz=NY)}["Alex / Sam - Fortnightly 1:1"],
      cp.M_HANDLED)
check("tz: a different meeting with the same slug 3 days away is not matched",
      meeting_status([one_to_one], ["2026-10-17-1030-followup-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_PROCEED)
check("tz: a briefing reply file with the slug never matches",
      meeting_status([one_to_one], ["2026-10-20-0930-awaiting-reply-briefing-alex-sam-fortnightly-1-1.md"])["Alex / Sam - Fortnightly 1:1"],
      cp.M_PROCEED)

draft = {"id": "d1", "labelIds": ["DRAFT"], "payload": {"headers": [{"name": "From", "value": user}]}}
check("thread: a half-written draft is not a reply", cp.thread_status([msg("t1"), draft], {"bot_sent_ids": ["t1"]}, cp.KIND_REPLY, MY), cp.T_NO_REPLY)
check("thread: unrecorded bot send (bare From) is not a reply even with bot_sent_ids",
      cp.thread_status([msg("t1"), msg("u1", user), msg("b9")], {"bot_sent_ids": ["t1"], "last_processed_msg": "u1"}, cp.KIND_DIGEST, MY),
      cp.T_BOT_OWN)

nocal = cp.build_plan(None, NOW, {}, {}, MY, tz=LISBON)
check("calendar failure: flagged so /follow-up checks meetings by hand", (nocal["calendar_ok"], nocal["needs_followup"]), (False, True))
check("calendar ok flag", cp.build_plan([], NOW, {}, {}, MY, tz=LISBON)["calendar_ok"], True)

check("threads_needed: only live files with a thread are fetched", cp.threads_needed({
    "2026-05-01-0900-awaiting-why-x.md": "thread_id: w\n",
    "2026-09-01-1000-awaiting-reply-old.md": "thread_id: o\ncreated_at: 2026-09-01T10:00:00Z\n",
    "2026-10-19-1000-awaiting-reply-nothread.md": "created_at: 2026-10-19T10:00:00Z\n",
    "2026-10-19-1000-awaiting-reply-live.md": "thread_id: live\ncreated_at: 2026-10-19T10:00:00Z\n",
    "2026-10-20-1030-awaiting-x.md": "thread_id: tr\nrequested_at: 2026-10-20T11:00:00Z\n",
}, NOW), {"2026-10-19-1000-awaiting-reply-live.md": "live", "2026-10-20-1030-awaiting-x.md": "tr"})

soon_declined = event("Soon", NOW + timedelta(minutes=30), NOW + timedelta(minutes=60), attendees=[
    {"email": MY, "self": True, "responseStatus": "declined"}, {"email": "x@example.com"}])
check("briefing: declined upcoming meeting ignored", cp.briefing_needed([soon_declined], NOW, set()), False)
check("parse_ts: naive timestamps are local time", cp.parse_ts("2026-10-20T10:00:00").tzinfo is not None, True)

check("attention: markdown-decorated lines are caught",
      att.extract_attention("- ATTENTION: one\n**ATTENTION:** two**\n> attention: three"), ["one", "two", "three"])
send, _ = att.triage(["Dedup glob is wrong"], [rec("Dedup glob is wrong", 3, emailed=False)], NOW)
check("attention: a point whose email failed is emailed again", send, ["Dedup glob is wrong"])

# ── CLI end to end, against a fake gws in a temp dir ─────────────────────────
import json, os, stat, subprocess, tempfile  # noqa: E402
with tempfile.TemporaryDirectory() as td:
    bd = Path(td) / "Briefings"; bd.mkdir()
    fake = Path(td) / "gws"
    fake.write_text("""#!/usr/bin/env python3
import json, sys
p = json.loads(sys.argv[sys.argv.index('--params') + 1])
tid = p.get('id')
print('Using keyring backend: keyring')
if tid == 'gone':
    print(json.dumps({'error': {'code': 404, 'message': 'Not Found'}})); sys.exit(1)
if tid == 'bad':
    print(json.dumps({'error': {'code': 400, 'message': 'Bad Request'}})); sys.exit(1)
msgs = [{'id': tid, 'payload': {'headers': [{'name': 'From', 'value': '<you@example.com>'}]}}]
if tid == 'replied':
    msgs.append({'id': 'r1', 'payload': {'headers': [{'name': 'From', 'value': 'Me <you@example.com>'}]}})
print(json.dumps({'messages': msgs}))
""")
    fake.chmod(0o755)
    files = {
        "2026-05-01-0900-awaiting-why-x.md": "thread_id: w\n",
        "2020-01-01-0900-awaiting-old.md": "thread_id: o\nmeeting: Old\nrequested_at: 2020-01-01T09:00:00Z\n",
        "2099-01-01-1000-awaiting-reply-gone.md": "thread_id: gone\ncreated_at: 2099-01-01T10:00:00Z\n",
        "2099-01-01-1000-awaiting-reply-bad.md": "thread_id: bad\ncreated_at: 2099-01-01T10:00:00Z\n",
        "2099-01-01-1000-awaiting-reply-replied.md": 'thread_id: replied\ncreated_at: 2099-01-01T10:00:00Z\nbot_sent_ids: ["replied"]\n',
        "2099-01-01-1000-awaiting-reply-quiet.md": "thread_id: quiet\ncreated_at: 2099-01-01T10:00:00Z\n",
        "2099-01-01-1000-notes.md": "not a state file\n",
    }
    for n, t in files.items():
        (bd / n).write_text(t)
    env = dict(os.environ, GWS=str(fake), CAL='{"items": []}')
    out = subprocess.run([sys.executable, "-m", "briefings_mcp.cycle_plan", "--briefing-dir", str(bd), "--calendar-env", "CAL",
                          "--my-email", MY, "--apply"], cwd=REPO_ROOT, env=env, capture_output=True, text=True)
    check("cli: exits 0", (out.returncode, out.stderr[-200:]), (0, ""))
    check("cli: gate lines printed", [l for l in out.stdout.splitlines() if l.startswith("NEED_")], ["NEED_BRIEFING=0", "NEED_FOLLOWUP=1"])
    remaining = sorted(os.listdir(bd))
    check("cli --apply: expired + retired files deleted, nothing else",
          [n for n in files if n not in remaining], ["2026-05-01-0900-awaiting-why-x.md", "2020-01-01-0900-awaiting-old.md"])
    log = (bd / "scheduler.log").read_text()
    check("cli --apply: each deletion logged", ("Retiring Phase 1" in log, "Transcript request expired for Old" in log), (True, True))
    planf = bd / ".cycle-plan.json"
    plan = json.loads(planf.read_text())
    status = {r["file"]: r["status"] for r in plan["state_files"]}
    check("cli: Gmail 404 → thread_missing (not actionable)", status["2099-01-01-1000-awaiting-reply-gone.md"], cp.T_MISSING)
    check("cli: Gmail 400 → unknown (fails open, Claude checks it)", status["2099-01-01-1000-awaiting-reply-bad.md"], cp.T_UNKNOWN)
    check("cli: real reply → new", status["2099-01-01-1000-awaiting-reply-replied.md"], cp.T_NEW)
    check("cli: quiet thread → no_reply", status["2099-01-01-1000-awaiting-reply-quiet.md"], cp.T_NO_REPLY)
    check("cli: plan file is private (0600)", stat.S_IMODE(planf.stat().st_mode), 0o600)

    # attention: triage → (send succeeds) → mark-sent → repeat suppressed
    run_att = lambda stdin, *a: subprocess.run([sys.executable, "-m", "briefings_mcp.attention", "--briefing-dir", str(bd), *a],
                                               cwd=REPO_ROOT, input=stdin, capture_output=True, text=True)
    r1 = json.loads(run_att("ATTENTION: plan disagrees with calendar\n").stdout)
    check("attention cli: first flag is offered for email", r1["send"], ["plan disagrees with calendar"])
    r2 = json.loads(run_att("ATTENTION: plan disagrees with calendar\n").stdout)
    check("attention cli: unconfirmed send is offered again", r2["send"], ["plan disagrees with calendar"])
    run_att(r2["keys"], "--mark-sent", r2["ts"])
    r3 = json.loads(run_att("ATTENTION: plan disagrees with calendar\n").stdout)
    check("attention cli: after --mark-sent the repeat is suppressed", (r3["send"], len(r3["suppressed"])), ([], 1))


# ── briefings_mcp.send: self-only email helper ───────────────────────────────
from briefings_mcp import send as snd  # noqa: E402
with tempfile.TemporaryDirectory() as td:
    root = Path(td) / "Briefings"; (root / ".outbox").mkdir(parents=True)
    ok_file = root / ".outbox" / "x.html"; ok_file.write_text("<p>hi</p>")
    outside = Path(td) / "secret.txt"; outside.write_text("nope")
    (root / ".outbox" / "link.html").symlink_to(outside)
    check("send: body under ~/Briefings accepted", snd.body_path(str(ok_file), root) == ok_file.resolve(), True)
    for name, path in [("outside file", outside), ("symlink escaping the root", root / ".outbox" / "link.html"),
                       ("dot-dot escape", root / ".outbox" / ".." / ".." / "secret.txt")]:
        try:
            snd.body_path(str(path), root); got = "accepted"
        except snd.Refused:
            got = "refused"
        check(f"send: {name} refused", got, "refused")
for frm, want in [(f"Me <{MY}>", "ok"), (f"<{MY.upper()}>", "ok"), ("Eve <eve@evil.example>", "refused"), ("", "refused")]:
    try:
        snd.check_reply_target(frm, MY); got = "ok"
    except snd.Refused:
        got = "refused"
    check(f"send: reply target {frm or '(empty)'!r}", got, want)

# ── report ────────────────────────────────────────────────────────────────────
failed = [r for r in results if not r[1]]
for name, ok, detail in results:
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  — ' + detail if detail else ''}")
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
