# Post-meeting follow-up
<!-- version: 2026-04-13 -->

After a meeting ends, find the Gemini transcript, extract actions, and deliver them.

**Before doing anything else**, read the delivery email address:
```bash
MY_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
if [ -z "$MY_EMAIL" ]; then
    echo "Error: MY_EMAIL not configured. Run the meeting-intelligence installer, or add MY_EMAIL=you@example.com to ~/.briefings_config" >&2
    exit 1
fi
```
Use `$MY_EMAIL` for all email delivery throughout this command.

## Rules
- **Never use osascript, AppleScript, or Apple Mail.app** — use `gws` tools only for email and calendar access
- **Never use osascript to access Calendar** — use the Google Calendar MCP instead

## Routing

Check `$ARGUMENTS`:

- If empty or "all" → process **all** meetings that ended today (no follow-up or awaiting file yet)
- If a meeting name or time → process that **specific** meeting

---

## Step 0: Check for pending transcript requests

Before anything else, scan `~/Briefings/` for files matching `*-awaiting-*.md`.

For each awaiting file found:

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

Only meetings with no existing follow-up or awaiting file should proceed to Step 2.

If no qualifying meetings exist, say so and stop.

---

## Step 2: Find the transcript

For each meeting, search in order — stop as soon as you find a usable transcript:

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
- **Open questions** — anything unresolved that needs a follow-up

If the transcript is long, focus on the last 20% (actions cluster at the end) but scan the whole thing for anything explicitly flagged as an action.

---

## Step 4: Assemble the follow-up

Save to `~/Briefings/YYYY-MM-DD-HHmm-followup-slug.md`:

```markdown
# Follow-up: [Meeting title]
**[Day, Date] | [Start] – [End] | [Duration]**

## Summary
[1-2 sentence summary of what the meeting covered and what was decided]

## Action items
- [ ] **You** — [your action] *(by [date] if stated)*
- [ ] [Other person] — [their action]

## Key decisions
- [Decision made]
- [Decision made]

## Open questions
- [Unresolved item]
```

Skip any section that has no content.

---

## Step 5: Deliver

Send via both channels:

**Email** — to $MY_EMAIL using `--html`, subject: `Follow-up: [Meeting title] ([date])`

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
gws gmail +send --to "$MY_EMAIL" --subject "Follow-up: [Meeting title] ([date])" --body "$HTML" --html
```

Replace `FOLLOWUP_FILE` with the actual path to the saved follow-up `.md` file.

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

---

## Step 6: Confirm

Tell the user:
- Which meeting was processed
- Where the file was saved
- A 2-line summary of the actions found
