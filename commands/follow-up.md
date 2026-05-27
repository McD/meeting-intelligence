# Post-meeting follow-up
<!-- version: 2026-05-27 — Phase 1 richness upgrades: Notable threads, Source link, Counterparty read (ext/mixed only), inline confidence callouts on actions, hardened Open questions prompt. v1 (2026-05-19) added --force, ledger writes, why-prompt emails, awaiting-why state. -->

After a meeting ends, find the Gemini transcript, extract actions, and deliver them.

**Before doing anything else**, read the delivery email address and company domain:
```bash
MY_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
COMPANY_DOMAIN=$(grep '^COMPANY_DOMAIN=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
if [ -z "$MY_EMAIL" ] || [ -z "$COMPANY_DOMAIN" ]; then
    echo "Error: ~/.briefings_config missing MY_EMAIL or COMPANY_DOMAIN. Run the meeting-intelligence installer." >&2
    exit 1
fi
```
Use `$MY_EMAIL` for all email delivery throughout this command. `$COMPANY_DOMAIN` is used in Step 4 to classify the meeting as internal vs external/mixed for the high-stakes filter.

## Rules
- **Never use osascript, AppleScript, or Apple Mail.app** — use `gws` tools only for email and calendar access
- **Never use osascript to access Calendar** — use the Google Calendar MCP instead

## Routing

Check `$ARGUMENTS`:

- If empty or "all" → process **all** meetings that ended today (no follow-up or awaiting file yet)
- If a meeting name or time → process that **specific** meeting
- If `$ARGUMENTS` contains `--force` (or the user otherwise asks to regenerate / overwrite / replace an existing follow-up) → **force mode**. Bypass the "follow-up file already exists" guard in Step 1 and overwrite the existing file. Force mode is only valid with a specific meeting name; refuse `--force` combined with `all` (the mass-rewrite blast radius is too large to be safe without per-meeting confirmation). Strip the `--force` token from the meeting name when matching against the calendar.

Force mode is the right path when a transcript appeared late, when ledger writes (Step 3 onwards) need to be re-run against an older follow-up that predates the ledger work, or when a manual fix is needed. The default (no `--force`) preserves idempotency — re-running `/follow-up all` from cron must never overwrite a sent follow-up.

---

## Step 0: Check for pending email replies

Before anything else, scan `~/Briefings/` for files matching `*-awaiting-*.md`.

**Dispatch by filename.** The single glob covers two distinct state-file shapes that use the same `*-awaiting-*.md` naming convention. Inspect each match's basename:

- If the basename contains `-awaiting-why-` (e.g. `2026-05-19-1500-awaiting-why-acme-renewal.md`) → follow the **Why-capture branch** below (added in U3 for R14).
- Otherwise (basename contains `-awaiting-` but not `-awaiting-why-`) → follow the **Transcript-request branch** below (the original flow).

Process every awaiting file before falling through to Step 1.

---

### Why-capture branch

These state files were written by Step 6 of a prior follow-up run when high-stakes entries were appended to the ledger. Each one records the Gmail thread the user can reply to and the ledger entry UUIDs pending a `why` answer.

1. Read the file — flat frontmatter, one key per line:
   - `thread_id:` — Gmail thread ID of the follow-up email
   - `meeting:` — meeting name
   - `slug:` — the date+time meeting slug
   - `pending_entry_ids:` — JSON array of ledger entry UUIDs awaiting `why`, in the order they appeared as `1: …`, `2: …`, etc. under the `## Why?` section of the follow-up email
   - `created_at:` — ISO timestamp when the follow-up was sent

2. **Check expiry**: if `created_at` is more than 7 days ago:
   - Delete the awaiting-why file
   - Log `"Why-capture expired for [meeting] — no reply received"` to `~/Briefings/scheduler.log`
   - Skip this entry

3. **Check Gmail thread for a reply** using the stored thread ID:
   ```bash
   gws gmail users threads get --params '{"userId": "me", "id": "[thread_id]"}'
   ```
   If the `messages` array has more than 1 entry, a reply exists. Use the **last** message in the array — its `id` is the reply to read.

4. **If no reply yet** (only 1 message in thread) — skip. The scheduler will check again on the next 15-minute cycle.

5. **If a reply is found**:
   - Read the reply body: `gws gmail +read --message-id "[message_id]"`
   - Parse the body and apply updates by calling `briefings_mcp.why_capture.parse_and_update`. The parser strips quoted lines (`>` prefix is universal across Gmail/Apple Mail/Outlook/phone clients), matches each remaining line against `^\s*(\d+):\s+(.+)$`, indexes `N` into `pending_entry_ids` at position `N-1`, and updates that ledger entry's `why`. Unmatched non-quoted prose appends to `why_notes` on the **last** entry in `pending_entry_ids` — the most-recently-prompted entry from this thread. See `briefings_mcp/why_capture.py` for the parser; the heredoc here is the thin shell that loads inputs and emits JSON:

     ```bash
     PARSE_OUT=$(REPLY_BODY="$REPLY_BODY" \
                 PENDING_IDS_JSON='["<uuid1>","<uuid2>","<uuid3>"]' \
                 python3 <<'PYEOF'
     import json, os
     from briefings_mcp import why_capture

     reply = os.environ.get("REPLY_BODY", "")
     pending = json.loads(os.environ.get("PENDING_IDS_JSON", "[]"))
     print(json.dumps(why_capture.parse_and_update(reply, pending)))
     PYEOF
     )
     ```

   - Parse `$PARSE_OUT` as JSON:
     - `matched_count` (int) — how many `N: …` lines updated a ledger entry on this cycle. Use for the log line.
     - `all_answered` (bool) — true when every UUID in the original `pending_entry_ids` now has a non-empty `why` in the ledger.
     - `warnings` (array of strings) — log each to `~/Briefings/scheduler.log` so out-of-range indices and ledger lookup failures stay visible. Do not abort on warnings.

   - **If `all_answered` is true**: delete the awaiting-why file. Log `"Why-capture complete for [meeting] — N entries updated this cycle"`.

   - **If `all_answered` is false**: leave the awaiting-why file untouched. The scheduler will re-poll on the next cycle; if a further reply lands, the same parser runs against the new latest message. Numbered matches are idempotent (same `why` value re-applied is a no-op); a prose dedupe guard in the parser (see `briefings_mcp/why_capture.py`) prevents `why_notes` from doubling up when the same reply is re-processed. Log `"Why-capture partial for [meeting] — N entries updated this cycle, awaiting more"`.

   - Do **not** rewrite `pending_entry_ids` to drop matched indices: the index map must stay stable so subsequent replies can keep using `N` to address the same original entries. Completion is detected by reading ledger state, not by shrinking the pending list. Do **not** bump `created_at` either — the 7-day clock runs from the original follow-up send.

---

### Transcript-request branch

For each transcript-awaiting file found:

1. Read the file — it contains:
   - `thread_id:` — Gmail thread ID of the transcript request email
   - `meeting:` — meeting name
   - `slug:` — the date+time slug (e.g. `2026-03-26-1030-all-hands`)
   - `requested_at:` — ISO timestamp when the request was sent

2. **Check expiry**: if `requested_at` is more than 7 days ago:
   - Delete the awaiting file
   - Log `"Transcript request expired for [meeting] — no reply received"` to `~/Briefings/scheduler.log`
   - Skip this entry

3. **Check Gmail thread for a reply** using the stored thread ID:
   ```bash
   gws gmail users threads get --params '{"userId": "me", "id": "[thread_id]"}'
   ```
   Parse the response: if `messages` array has more than 1 entry, a reply exists.
   The reply is the last message in the array — note its `id`.

4. **If a reply is found**:
   - Read the reply body: `gws gmail +read --message-id "[message_id]"`
   - **Check for cancellation first.** Take the first non-empty, non-quoted line of the reply body — i.e. the user's actual typed reply, not the quoted original email that Gmail appends after `On [date], ... wrote:`. Lowercase and strip it. If that line is exactly (or starts with, followed by punctuation/whitespace) one of: `cancel`, `skip`, `no transcript`, `n/a`, `nope`:
     - Delete the awaiting file
     - **Write a tombstone follow-up file** at `~/Briefings/YYYY-MM-DD-HHmm-followup-slug.md` (using the slug from the awaiting file) with this exact content:
       ```
       # Follow-up: [Meeting title]
       **[Day, Date] | [Start] – [End]**

       _Transcript request cancelled by user — no follow-up generated._
       ```
       This prevents Step 1 from re-detecting the meeting on the next cycle and re-sending the transcript request.
     - Log `"Transcript request cancelled by user for [meeting]"` to `~/Briefings/scheduler.log`
     - Skip this entry — do not send any email or Slack message
   - **Check for extend next.** Same first-non-quoted-line logic as cancel. If that line is exactly (or starts with, followed by punctuation/whitespace) one of: `extend`, `wait`, `more time`:
     - **Bump the awaiting file's `requested_at` to now** (so the 7-day expiry timer resets). Read the awaiting file, replace the `requested_at:` line with `requested_at: <current ISO timestamp>`, write back.
     - Log `"Transcript request extended by user for [meeting] — expiry reset to 7 days from now"` to `~/Briefings/scheduler.log`
     - Skip this entry — do not generate a follow-up. The scheduler will keep polling the thread for a transcript reply on subsequent cycles, just for another 7 days.
   - Otherwise, the body text is the transcript:
     - Set `$TRANSCRIPT_SOURCE` to the Gmail thread URL of the reply (e.g. `https://mail.google.com/mail/u/0/#inbox/<thread_id>`) so the `## Source` section in Step 5 can link back to the email containing the pasted transcript.
     - Proceed directly to **Step 3** (Read and extract) using this text as the transcript
     - Complete Steps 4 and 5 as normal, using the slug from the awaiting file for the output filename
     - After sending, delete the awaiting file

5. **If no reply yet** (only 1 message in thread) — skip. The scheduler will check again on the next 15-minute cycle.

---

## Step 1: Find recently ended meetings

Detect the system's local timezone:
```bash
TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
```

Get today's calendar events and find meetings that **both**:
- End time is in the past (i.e. `end_time < now`) — do not process meetings that are still in progress or haven't started yet
- Ended any time in the last 2 days (not just today — this catches meetings that fell through if the scheduler was down overnight or had auth issues)
- **Do NOT already have a follow-up or awaiting file** — before processing any meeting, run this exact check and skip it immediately if either file exists:

```bash
# Check for existing follow-up or awaiting file (replace SLUG with the meeting's date-time slug)
ls ~/Briefings/YYYY-MM-DD-HHmm-followup-SLUG.md 2>/dev/null && echo "EXISTS"
ls ~/Briefings/YYYY-MM-DD-HHmm-awaiting-SLUG.md 2>/dev/null && echo "EXISTS"
```

**If either file exists → skip this meeting entirely. Do not re-send email or re-create the file.**

**Force-mode exception:** if Routing detected `--force` for a specific named meeting, the guard above is bypassed for that meeting only. Overwrite the existing follow-up file; if an `*-awaiting-*.md` file exists for the same slug, delete it before regeneration so the rewritten follow-up's awaiting-why state is the authoritative one. Never apply force mode to the `all` sweep.

Only meetings with no existing follow-up or awaiting file (or with force mode set for a specific meeting) should proceed to Step 2.

If no qualifying meetings exist, say so and stop.

---

## Step 2: Find the transcript

For each meeting, search in order — stop as soon as you find a usable transcript.

**Capture two references as you go**, for the `## Source` section in Step 5:

- `$TRANSCRIPT_SOURCE` — the most direct link to the transcript content. By branch:
  - **A, B, D** → the Google Doc URL (e.g. `https://docs.google.com/document/d/<id>`)
  - **C** → the Gmail thread URL of the Teams Meeting Recap (e.g. `https://mail.google.com/mail/u/0/#inbox/<threadId>`)
  - **E** → an absolute `file://` path to the MacWhisper file (e.g. `file:///Users/.../Desktop/recording.txt`)
- `$CALENDAR_EVENT_URL` — the calendar event's `htmlLink` field, captured when the event is fetched in Step 1 or branch A. Always available when the meeting came from the calendar.

Leave `$TRANSCRIPT_SOURCE` empty if no concrete source link can be produced (rare; e.g. transcript pasted inline somewhere without a stable URL). Step 5 omits the Source section gracefully when both values are empty.

**A) Calendar event attachments and description**
- Fetch the full calendar event
- Look for Google Drive links in the description and `attachments` field
- A Gemini transcript is a Google Doc — look for `docs.google.com` links
- The transcript is often labelled "Transcript" or "Notes" or has the meeting name

**B) Gmail — Gemini / Google Meet notes**
- Search for emails received since the meeting start time today:
  - `subject:("Notes from" OR "Gemini") after:YYYY/MM/DD`
  - `"[Meeting name]" after:YYYY/MM/DD`
- Gemini emails the notes doc link directly after the meeting ends
- Extract any Google Doc links and fetch the doc

**C) Gmail — Microsoft Teams transcript**
- Teams automatically emails a "Meeting Recap" after every call. Search:
  - `from:noreply@email.teams.microsoft.com after:YYYY/MM/DD`
  - `subject:"Meeting transcript" OR subject:"Meeting Recap" after:YYYY/MM/DD`
- If found, the transcript text is inline in the email body
- Teams transcripts look like: `Mark McDermott  0:01  Hello...` (name + timestamp + text)

**D) Drive search**
- Search for Google Docs modified today whose title contains the meeting name, "transcript", "notes from", or "meeting recap"
- Pick the most recently modified match

**E) MacWhisper local files**
- Search `~/Documents`, `~/Desktop`, and `~/Downloads` for `.txt` or `.md` files created today
- Look for filenames matching the meeting name or attendee names
- MacWhisper saves as plain text, one speaker turn per line

If no transcript is found after all five checks:
- If the meeting ended **less than 75 minutes ago** → log `"No transcript yet for [meeting] — will retry"` to `~/Briefings/scheduler.log` and **stop without creating any file**. The scheduler will retry on the next 15-minute cycle.
- If the meeting ended **75 minutes ago or more** → send a transcript request email and create an awaiting file:

  1. Compose the request email subject: `"Transcript needed: [Meeting Name] — [Day Date e.g. Thu 2 Apr]"`
  2. Send to $MY_EMAIL:
     ```
     Subject: Transcript needed: [Meeting Name] — [Day Date]

     No transcript was automatically found for [Meeting Name] ([start time]–[end time]).

     To generate your follow-up, reply to this email with the transcript. You can:
     - Paste a MacWhisper recording transcript
     - Forward the Teams "Meeting Recap" email, or paste the transcript from it
     - Paste from any other source

     If no transcript will be available, just reply with "cancel" (or "skip") and this request will be cleared automatically on the next scheduler cycle.

     If the transcript is just slow (and you'd like another 7 days to find/paste it), reply with "extend".
     ```
     Use `gws gmail +send --to "$MY_EMAIL"` (plain text, no `--html` needed)

  3. Capture the `threadId` from the `gws gmail +send` JSON response.

  4. Create `~/Briefings/YYYY-MM-DD-HHmm-awaiting-slug.md` with this exact content:
     ```
     thread_id: [threadId from send response]
     meeting: [Meeting Name]
     slug: YYYY-MM-DD-HHmm-slug
     requested_at: YYYY-MM-DDTHH:MM:SS
     ```

  5. Log `"Transcript request sent for [meeting] — awaiting reply"` to `~/Briefings/scheduler.log`

  6. **Stop** — do not create a follow-up file. The awaiting file prevents the scheduler from reprocessing this meeting, and Step 0 will handle it when the reply arrives.

---

## Step 3: Read and extract

Read the full transcript document.

**Transcript format notes**: Gemini transcripts are plain prose with speaker labels. Teams transcripts have the format `Name  0:01  text`. MacWhisper transcripts are plain text, often with speaker labels. Extract actions from all formats the same way.

Extract:
- **1-sentence meeting summary** — what was this meeting about
- **Key decisions made** — anything agreed or resolved
- **Action items** — each as: `[Person] — [what they need to do] (by [date] if mentioned)`
  - List **Mark's own actions first**
  - If no name is attached to an action, attribute it to the meeting organiser
  - Include ALL actions, not just Mark's
  - **Confidence callouts** — when the transcript leaves the owner or scope genuinely ambiguous, mark the uncertainty inline. Use sparingly; do not hedge clean actions.
    - **Unclear owner** — append `?` to the person's name: `**You?**`, `**Alice?**`, `**Organiser?**`. Trigger this only when the transcript does not assign a clear owner (e.g. "someone should send the recap").
    - **Unclear scope** — append italic `*(scope?)*` at the end of the action text. Trigger when the action is vague enough that the person would not know what "done" looks like (e.g. "Mark to do something about the website" → `**You** — handle the website *(scope?)*`).
    - When an action is unambiguous on both owner and scope, neither marker appears — this is the common case. A follow-up peppered with `?` marks signals a bad extraction, not a thorough one.
- **Open questions** — any question raised in the meeting that did not get a definitive answer, or any topic explicitly flagged "for later", "TBD", "we'll come back to", "needs more thought", or similar. Include questions that arose during decisions even if those decisions still stand (e.g. "we'll launch in March" decided, but "how do we sequence with the partner team?" left open). **Do not** include items that were already captured as Action items — those are tracked separately. If every question raised in the meeting got an answer, return nothing here and the section is omitted.
- **Notable threads** — 3 to 5 bullets capturing texture from the meeting that is not already covered by Summary, Action items, or Key decisions. Interesting framings, analogies, a striking line someone said, soft commitments ("you said you'd think about Z"), tangents worth remembering. **Do not** restate decisions or actions here — this section exists precisely because the punchy top loses the texture. **Ceiling: 5 bullets maximum.** If there are fewer than 3 genuinely notable moments, return fewer (or none) rather than padding. Each bullet should be one sentence, written in the third person where helpful (e.g. "Robert framed the legacy industry as 'selling 2010 hardware in 2026 packaging'").
- **Counterparty read** — *(only when at least one attendee has an email outside `$COMPANY_DOMAIN` — i.e. external or mixed meetings; skip entirely for internal-only meetings)* — one or two sentences on what the people from outside `$COMPANY_DOMAIN` seemed to care about most, separate from agreed actions. Tone, emphasis, what they kept returning to, what they pushed back on. If counterparty signal was thin (e.g. they barely spoke), say so honestly — e.g. "Limited counterparty signal; meeting was largely a Mark monologue." Keep it short and observation-led, not interpretation-led.

If the transcript is long, focus on the last 20% (actions cluster at the end) but scan the whole thing for anything explicitly flagged as an action.

---

## Step 4: Classify items and append to the decision ledger

Each extracted item becomes one entry in the append-only ledger at `~/.briefings/decisions.jsonl` (managed by the `briefings_mcp` package — installed by `install.sh`, see `briefings_mcp/schema.py` for the schema and `briefings_mcp/ledger.py` for the writer).

**Classification:**
- **Key decisions** → ledger `type: "decision"` with `resolved: true` (the meeting reached a resolution).
- **Action items** → ledger `type: "commitment"` with `state: "open"`, `owner: <person>`, and `due: <ISO date or null>`.
- **Open questions** are *not* appended in v1 — they remain in the follow-up doc only.

For each item, infer **1–3 short topic tags** (e.g. `"pricing"`, `"q3-plan"`, `"renewal"`) from its content. Topics are fuzzy-matched by substring in the MCP server, so consistency is helpful but not strict.

**High-stakes flag** (per R12) is computed once for the meeting and applied to every entry from it:

1. **Verdict** — look in `~/Briefings/` for a prior briefing file whose name starts with the same `YYYY-MM-DD-HHmm-` prefix as this follow-up and does **not** contain `-followup-` or `-awaiting-`. If found, scan its first heading line for a word from this closed set: `DECIDE-TODAY`, `DELEGATE`, `DEFER`, `DECLINE`, `PREP-HARD`, `LOW-STAKES`, `MOVE-ASYNC`. If no briefing exists or no verdict word is present, default to `LOW-STAKES`.
2. **is_external** — `true` if any attendee has an email outside `$COMPANY_DOMAIN`; `false` otherwise.
3. **attendee_history_count** — the maximum count of prior ledger entries for any of this meeting's attendees (computed inline below).

Build the items list and append in one Python invocation. The heredoc pattern mirrors `scripts/scheduler.sh` line 81:

```bash
APPEND_OUT=$(MEETING_VERDICT="<verdict word or LOW-STAKES>" \
             IS_EXTERNAL="<true|false>" \
             SOURCE_MEETING="YYYY-MM-DD-HHmm-slug" \
             ATTENDEES_JSON='["alice@acme.com","bob@example.com"]' \
             ITEMS_JSON='[
               {"type":"commitment","summary":"Send pricing memo to Acme","topics":["pricing","acme"],"owner":"You","due":"2026-05-26","state":"open"},
               {"type":"decision","summary":"Defer Q3 region rollout until staffing lands","topics":["q3-plan","staffing"],"resolved":true}
             ]' \
             python3 <<'PYEOF'
import os, json, sys, uuid
from collections import Counter
from datetime import datetime, timezone
from briefings_mcp import ledger, schema

verdict        = os.environ.get("MEETING_VERDICT", "LOW-STAKES")
is_external    = os.environ.get("IS_EXTERNAL", "false").lower() == "true"
source_meeting = os.environ["SOURCE_MEETING"]
attendees      = json.loads(os.environ["ATTENDEES_JSON"])
items          = json.loads(os.environ["ITEMS_JSON"])

# attendee_history_count: max prior ledger entries for any current attendee
counter = Counter()
for entry in ledger.iter_entries():
    for a in entry.get("attendees", []):
        if a in attendees:
            counter[a] += 1
max_count = max(counter.values(), default=0)

high_stakes = schema.is_high_stakes(verdict, is_external, max_count)

now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
results = []
for item in items:
    item.setdefault("id", str(uuid.uuid4()))
    item.setdefault("created_at", now_iso)
    item.setdefault("attendees", attendees)
    item.setdefault("source_meeting", source_meeting)
    item.setdefault("topics", [])
    item.setdefault("why", "")
    item.setdefault("why_notes", "")
    try:
        ledger.append(item)
        results.append({"ok": True, "id": item["id"], "summary": item["summary"]})
    except Exception as exc:
        print(f"WARN: ledger.append failed for {item.get('summary','?')[:60]!r}: {exc}", file=sys.stderr)
        results.append({"ok": False, "summary": item.get("summary", ""), "error": str(exc)})

print(json.dumps({"high_stakes": high_stakes, "results": results}))
PYEOF
)
```

Parse `$APPEND_OUT` as JSON:
- `high_stakes` (bool) gates the why-prompt section in Step 5 and the awaiting-why state file in Step 6.
- `results` (array) is ordered the same as `ITEMS_JSON`. Entries with `ok: true` are the ones that will be numbered `1..N` in the why-prompt section (in array order). Entries with `ok: false` are skipped from the prompts and from `pending_entry_ids` — the follow-up is still delivered (R-level: better to ship a degraded follow-up than skip it entirely).

**If no items were extracted** (`ITEMS_JSON='[]'`), the append step is a no-op: `high_stakes` falls back to the meeting-level flag but `results` is empty, so no Why? section and no awaiting-why file will be produced downstream.

---

## Step 5: Assemble the follow-up

Save to `~/Briefings/YYYY-MM-DD-HHmm-followup-slug.md`, then `chmod 600` the file so it is readable only by the user (follow-ups contain meeting transcripts, attendee actions, and decisions — keep them off other accounts on the machine):

```markdown
# Follow-up: [Meeting title]
**[Day, Date] | [Start] – [End] | [Duration]**

## Summary
[1-2 sentence summary of what the meeting covered and what was decided]

## Action items
- [ ] **You** — [your action] *(by [date] if stated)*
- [ ] [Other person] — [their action]
- [ ] **You?** — [action with unclear owner — see confidence callouts in Step 3]
- [ ] **Alice** — [action with unclear scope] *(scope?)*

## Key decisions
- [Decision made]
- [Decision made]

## Notable threads
- [Texture bullet: framing, analogy, soft commitment, or memorable moment]
- [Another, max 5 total]

## Open questions
- [Unresolved item]

## Counterparty read
[1-2 sentence read on what the external attendees seemed to care about most]

## Source
- Transcript: [link or file path from $TRANSCRIPT_SOURCE]
- Calendar: [link from $CALENDAR_EVENT_URL]
```

Skip any section that has no content. Specifically:

- **`## Counterparty read`** — render only when `is_external` (computed in Step 4) is `true` *and* Step 3 produced counterparty content. For internal-only meetings (`is_external: false`), omit this section unconditionally regardless of what Step 3 returned. This is belt-and-braces — Step 3's prompt already restricts extraction to external/mixed meetings, but the Step 5 check guarantees the section never leaks into internal follow-ups.
- **`## Source`** — if both `$TRANSCRIPT_SOURCE` and `$CALENDAR_EVENT_URL` are empty, omit the section entirely. If only one is empty, render the section with just the non-empty entry. Format transcript links as plain markdown `[link or file path](url)` when the value is a URL; render `file://` paths verbatim (no surrounding link syntax) so they remain copy-pasteable on the same machine.

**Why? section (high-stakes follow-ups only):** If Step 4 returned `high_stakes: true` *and* at least one entry has `ok: true`, append a final `## Why?` section to the file. Number the entries `1..N` over the successfully-appended entries only (in `results` order — so gaps from failed appends are renumbered away, not left as missing). Use this exact shape:

```markdown
## Why?
1: Why? [first successfully-appended entry's summary, ≤80 chars]
2: Why? [second successfully-appended entry's summary]
3: Why? [third successfully-appended entry's summary]

Reply to this thread with one line per entry: `N: <reason>`. Skip any you don't want to capture.
```

If the meeting is low-stakes, no items were extracted, or every append failed, omit the `## Why?` section entirely.

---

## Step 6: Deliver

Send via both channels. Email is sent first because its `threadId` is needed for the awaiting-why state file.

**Email** — to $MY_EMAIL using `--html`, subject: `Follow-up: [Meeting title] ([date])`. Capture the JSON response so the `threadId` is available below.

Convert markdown to HTML using this exact Python snippet (save the follow-up file first, then run):

```bash
HTML=$(python3 << 'PYEOF'
import re

def inline(text):
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    return text

lines = open('FOLLOWUP_FILE').read().split('\n')
out = []
in_list = False

for line in lines:
    if line.startswith('# '):
        if in_list: out.append('</ul>'); in_list = False
        out.append(f'<h2 style="margin:0 0 4px 0">{inline(line[2:])}</h2>')
    elif line.startswith('## '):
        if in_list: out.append('</ul>'); in_list = False
        out.append(f'<h3 style="margin:20px 0 4px 0;border-bottom:1px solid #eee;padding-bottom:4px">{inline(line[3:])}</h3>')
    elif line.startswith('### '):
        if in_list: out.append('</ul>'); in_list = False
        out.append(f'<h4 style="margin:12px 0 2px 0">{inline(line[4:])}</h4>')
    elif re.match(r'^\s*- ', line):
        content = re.sub(r'^\s*- ', '', line)
        if not in_list: out.append('<ul style="margin:4px 0;padding-left:20px">'); in_list = True
        out.append(f'<li style="margin:3px 0">{inline(content)}</li>')
    elif line.strip() == '':
        if in_list: out.append('</ul>'); in_list = False
        out.append('<div style="margin:6px 0"></div>')
    else:
        if in_list: out.append('</ul>'); in_list = False
        out.append(f'<p style="margin:3px 0">{inline(line)}</p>')

if in_list: out.append('</ul>')
print('\n'.join(out))
PYEOF
)
SEND_RESPONSE=$(gws gmail +send --to "$MY_EMAIL" --subject "Follow-up: [Meeting title] ([date])" --body "$HTML" --html)
THREAD_ID=$(printf '%s' "$SEND_RESPONSE" | python3 -c "import sys,json; raw=sys.stdin.read(); b=raw.find('{'); print((json.loads(raw[b:]) if b>=0 else {}).get('threadId',''))")
```

Replace `FOLLOWUP_FILE` with the actual path to the saved follow-up `.md` file. `$THREAD_ID` is used in the awaiting-why step below; the existing transcript-request flow captures `threadId` the same way (Step 2).

**Slack** — if `~/.slack_webhook` exists, convert to mrkdwn and POST:

```bash
SLACK_WEBHOOK=$(cat ~/.slack_webhook 2>/dev/null)
if [ -n "$SLACK_WEBHOOK" ]; then
python3 -c "
import sys, re
text = open('FOLLOWUP_FILE').read()
text = re.sub(r'^### (.+)$', r'*\1*', text, flags=re.MULTILINE)
text = re.sub(r'^## (.+)$', r'\n*\1*', text, flags=re.MULTILINE)
text = re.sub(r'^# (.+)$', r'*\1*', text, flags=re.MULTILINE)
text = re.sub(r'\*\*(.+?)\*\*', r'*\1*', text)
text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<\2|\1>', text)
text = text[:3000]
print(text)
" | python3 -c "
import sys, json
text = sys.stdin.read()
payload = json.dumps({'text': text})
print(payload)
" | curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-type: application/json' -d @-
fi
```

Replace `FOLLOWUP_FILE` with the actual path to the saved follow-up `.md` file. If `~/.slack_webhook` is not found, skip silently.

**Awaiting-why state file (high-stakes follow-ups only).** When Step 4 returned `high_stakes: true` *and* at least one entry has `ok: true`, record the pending state so the scheduler (U3) can match a reply back to the ledger entries. Mirror the awaiting-transcript file shape from Step 2:

```bash
umask 077
AWAITING_WHY=~/Briefings/YYYY-MM-DD-HHmm-awaiting-why-slug.md
cat >"$AWAITING_WHY" <<EOF
thread_id: $THREAD_ID
meeting: [Meeting Name]
slug: YYYY-MM-DD-HHmm-slug
pending_entry_ids: ["<id of entry 1 from results>","<id of entry 2 from results>","<id of entry 3 from results>"]
created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 600 "$AWAITING_WHY"
```

The `pending_entry_ids` array lists the successfully-appended entry UUIDs from Step 4's `results`, in the **same order** they appear under `## Why?` in the follow-up file — so the reply line `N: <reason>` indexes into the array at position `N-1`.

Skip awaiting-why file creation entirely when the meeting is low-stakes, when no items were extracted, when every append failed, or when `$THREAD_ID` is empty (in that last case, log `"WARN: follow-up sent but threadId not captured — awaiting-why state skipped for [meeting]"` to `~/Briefings/scheduler.log` so the gap is visible).

---

## Step 7: Confirm

Tell the user:
- Which meeting was processed
- Where the file was saved
- A 2-line summary of the actions found
