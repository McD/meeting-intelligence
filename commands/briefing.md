# Pre-meeting briefing
<!-- version: 2026-04-13 -->

Generate a briefing document for upcoming meetings (internal and external), pulling context from Gmail, Drive, and Slack.

## Routing

Check `$ARGUMENTS` first:

- If `$ARGUMENTS` is "all", run briefings for **all** meetings today that don't have one yet
- If `$ARGUMENTS` is a meeting name or time, find that specific meeting and brief it
- If `$ARGUMENTS` is empty, brief the **next** upcoming meeting
- If `$ARGUMENTS` is "setup", reply that setup is handled by `install.sh` in the meeting-intelligence repo, not by this command, then stop.

---
## Generate a briefing

**Before doing anything else**, read your config:
```bash
MY_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
COMPANY_DOMAIN=$(grep '^COMPANY_DOMAIN=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
if [ -z "$MY_EMAIL" ] || [ -z "$COMPANY_DOMAIN" ]; then
    echo "Error: ~/.briefings_config missing MY_EMAIL or COMPANY_DOMAIN. Run the meeting-intelligence installer." >&2
    exit 1
fi
```
Use `$MY_EMAIL` for all email delivery throughout this command. `$COMPANY_DOMAIN` is your company's internal email domain, used for internal/external classification below.

### Step 1: Find the target meeting(s)

Use Google Calendar to get today's remaining events.

**If generating for a specific meeting** (`$ARGUMENTS` is a name/time): search for the matching event.

**If generating for the next meeting** (no arguments): pick the next event with 2+ attendees (skip solo blocks and declined events).

**If generating for all** (`$ARGUMENTS` is "all"): collect all events **starting within the next 2 hours** (from now) that have 2+ attendees, plus any event that started within the last 15 minutes (you may be joining late). Do not include meetings further than 2 hours away — this prevents early briefings on evenings or weekends for next-day or future meetings. Skip solo blocks and declined events.

If no meetings fall within this window, respond with a single line: "No meetings to brief in the next 2 hours." Do **not** list upcoming meetings on future days, do **not** offer to generate briefings for them, and do **not** generate any briefing files. Stop.

**Classify each meeting as internal or external:**
- **Internal**: all attendees have @$COMPANY_DOMAIN email addresses
- **External**: any attendee has a domain outside $COMPANY_DOMAIN (and not a domain you've sent 50+ emails to in the last 90 days — treat those as "internal-adjacent" and classify as internal)
- **Mixed**: some internal, some external attendees — treat as external

For each target meeting, check if a briefing already exists at `~/Briefings/` matching the date and a slug of the meeting name. If it exists, skip it and move to the next.

### Step 2: Extract meeting details

Detect the system's local timezone first:
```bash
TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
```
Use this to convert all meeting times to local time before displaying them. If detection fails, fall back to the timezone specified in the calendar event.

For each meeting, pull:
- Event title, start time, end time, duration (all in local time)
- Location or video conferencing link
- Calendar description (this often contains the agenda)
- Any URLs embedded in the description
- Full attendee list with names and email addresses

### Step 3: Research attendees

**For external attendees** (non-$COMPANY_DOMAIN domains):

**Gmail** (last 90 days):
- Search for threads involving their email address
- Take the 5 most recent threads
- For each thread: note the subject, date, and write a one-line summary of where things stand (e.g. "Awaiting their response on pricing" or "Closed, they confirmed the March timeline")

**Drive** (last 90 days):
- Search for docs shared with or by their email address
- Search for docs containing their name in the content
- List up to 5 most recently modified, with doc title and last modified date

**Past call transcripts** (last 6 months):
- Search Gmail for emails with subject containing "Notes from" or "Gemini" that involve their email address or name
- Search Gmail for Teams Meeting Recap emails: `from:noreply@email.teams.microsoft.com "[attendee name]"` or `subject:"Meeting Recap" "[attendee name]"`
- Search Drive for Google Docs with titles containing "Notes by Gemini" or "transcript" that mention their name
- For each transcript found, read it and extract: what topics were covered, any commitments or actions agreed, and any relationship context worth knowing
- Summarise as 2-4 bullet points under "Previous calls" — focus on what was left open, agreed, or relevant to this meeting
- If multiple transcripts exist, prioritise the most recent 2

**Slack** (last 30 days):
- Search for messages mentioning their name or email
- Note any relevant context (keep to 2-3 lines max)

If an attendee has no email history, no shared docs, and no past calls, just list their name and email. Don't create empty sections.

---

**For internal attendees** ($COMPANY_DOMAIN — for internal or mixed meetings):

**Slack** (last 30 days) — primary source:
- Search for recent messages from them in shared channels
- Look for anything related to the meeting topic or ongoing work between you
- Summarise as 2-3 lines of relevant context

**Past call transcripts** (last 6 months):
- Search Drive for Google Docs with titles containing "Notes by Gemini" or "transcript" that mention their name
- Extract: topics covered, any open actions or decisions relevant to this meeting
- Summarise as 2-4 bullet points under "Previous calls"

**Drive** (last 30 days):
- Search for docs recently modified by or shared with them that relate to the meeting topic
- List up to 3, with title and last modified date

Skip Gmail for internal attendees. If an internal attendee has no Slack history, no transcripts, and no shared docs relevant to the meeting, just list their name. Don't create empty sections.

### Step 4: Find relevant documents

**Linked docs:** If the calendar description contains URLs to Google Docs, Sheets, or Slides, fetch each one and write a 2-3 sentence summary of its content and current state.

**Related docs:** Search Drive for documents modified in the last 14 days whose titles or content relate to the meeting topic. Use keywords from the event title and description. List up to 5, with title, last modified date, and a one-line description.

### Step 5: Assemble the briefing

Save to `~/Briefings/YYYY-MM-DD-HHmm-meeting-slug.md` where the slug is the meeting title lowercased with spaces replaced by hyphens, truncated to 50 characters.

**After writing the file, set its mode to 600 so it is readable only by the user**: `chmod 600 ~/Briefings/YYYY-MM-DD-HHmm-meeting-slug.md`. Briefings contain attendee emails, email-thread summaries, and prep notes — keep them off other accounts on the machine.

**Prep notes** — always generate this section last, after all research is done. Write 3–5 bullet points that synthesise the most actionable advice based on everything gathered:
- What to lead with or raise first
- Any open threads or commitments from previous calls to address
- Anything sensitive to navigate carefully (relationship dynamics, pending decisions, unresolved tension)
- One or two good questions to ask
- What success looks like for this meeting

This should read like advice from someone who's read all the email and knows the context — not a recap of what's already in the briefing.

Use this structure (skip any section that has no content):

**For external or mixed meetings:**
```markdown
# [Meeting title]
**[Day, Date] | [Start time] - [End time] ([duration]) | [Location/link]**

## Attendees

### [External attendee name] ([company/domain])
[email]
- **Recent threads:**
  - [Subject] ([date]): [one-line status summary]
  - [Subject] ([date]): [one-line status summary]
- **Previous calls:**
  - [Date]: [what was discussed / agreed / left open]
  - [Date]: [what was discussed / agreed / left open]
- **Shared docs:** [Doc title] ([date]), [Doc title] ([date])
- **Slack:** [Brief context if any]

### [Next external attendee]
...

### Internal attendees
[Name], [Name], [Name]

## Agenda
[From calendar description, or omit this section entirely]

## Linked documents
- **[Doc title]:** [2-3 sentence summary]

## Related documents
- [Doc title] ([last modified]): [one-line description]

## Prep notes

```

**For internal-only meetings:**
```markdown
# [Meeting title]
**[Day, Date] | [Start time] - [End time] ([duration]) | [Location/link]**

## Attendees

### [Attendee name]
- **Slack:** [2-3 lines of recent relevant context]
- **Previous calls:**
  - [Date]: [what was discussed / agreed / left open]
- **Shared docs:** [Doc title] ([date])

### [Next attendee]
...

## Agenda
[From calendar description, or omit this section entirely]

## Linked documents
- **[Doc title]:** [2-3 sentence summary]

## Related documents
- [Doc title] ([last modified]): [one-line description]

## Prep notes

```

### Step 6: Quality check

Before saving, verify:
- The briefing is scannable in under 2 minutes
- No empty sections remain (remove them)
- Email thread summaries are genuinely useful (status-oriented, not just "you emailed about X")
- The most important context is near the top
- No filler or padding

Tell the user where the file was saved and give a 2-3 line summary of what's in it.

### Step 7: Deliver the briefing

After saving and quality-checking, deliver via both channels:

**Email** — convert markdown to HTML and send to `$MY_EMAIL` using `--html`:
```bash
HTML=$(python3 << 'PYEOF'
import re

def inline(text):
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    return text

lines = open('BRIEFING_FILE').read().split('\n')
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
gws gmail +send --to "$MY_EMAIL" --subject "Briefing: [Meeting title] — [Day Date e.g. Thu 2 Apr] [Start time]" --body "$HTML" --html
```

**Slack** — convert the briefing to Slack mrkdwn before posting (do NOT wrap in a code block). Check if the webhook URL is configured:
```bash
SLACK_WEBHOOK=$(cat ~/.slack_webhook 2>/dev/null)
```
- If found, convert the markdown to Slack mrkdwn format using this Python snippet, then POST it:
```bash
python3 -c "
import sys, re
text = open('BRIEFING_FILE').read()
# Convert markdown to Slack mrkdwn
text = re.sub(r'^### (.+)$', r'*\1*', text, flags=re.MULTILINE)   # ### → *bold*
text = re.sub(r'^## (.+)$', r'\n*\1*', text, flags=re.MULTILINE)  # ## → *bold* with space
text = re.sub(r'^# (.+)$', r'*\1*', text, flags=re.MULTILINE)     # # → *bold*
text = re.sub(r'\*\*(.+?)\*\*', r'*\1*', text)                    # **bold** → *bold*
text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<\2|\1>', text)       # [text](url) → <url|text>
text = text[:3000]
print(text)
" | python3 -c "
import sys, json
text = sys.stdin.read()
payload = json.dumps({'text': text})
print(payload)
" | curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-type: application/json' -d @-
```
- If not found, skip Slack silently and note to the user that they can enable Slack delivery by saving their Slack incoming webhook URL to `~/.slack_webhook`.

**Google Chat** (fallback if no Slack webhook) — skip unless the user has explicitly configured a Google Chat space.
