# Actions tracker digest
<!-- version: 2026-05-28 — Step 6 state file creation now uses atomic tmp+rename (modelled on briefings_mcp/ledger.py:189-196); includes empty last_processed_msg field for the dedup watermark consumed by commands/follow-up.md awaiting-digest branch. Previous: Phase 4.1 — Step 5 email renderer inlined explicitly; handles *italic* and numbered (1.) lists. Phase 4 added period themes one-liner. Phase 3 v1 — twice-weekly digest of open commitments with reply-keyword updates. -->

Read open commitments from the ledger and deliver an actions tracker email plus Slack heads-up. Idempotent: skip if a digest file already exists for today.

**Before doing anything else**, read the user identity from `~/.briefings_config`:

```bash
MY_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
COMPANY_DOMAIN=$(grep '^COMPANY_DOMAIN=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
MY_NAME=$(grep '^MY_NAME=' ~/.briefings_config 2>/dev/null | cut -d= -f2-)
if [ -z "$MY_EMAIL" ] || [ -z "$COMPANY_DOMAIN" ]; then
    echo "Error: ~/.briefings_config missing MY_EMAIL or COMPANY_DOMAIN. Run the meeting-intelligence installer." >&2
    exit 1
fi
# MY_NAME is optional. If absent, fall back to the local-part of MY_EMAIL.
if [ -z "$MY_NAME" ]; then
    MY_NAME="${MY_EMAIL%%@*}"
fi
MY_FIRST_NAME="${MY_NAME%% *}"
```

## Rules

- **Never use osascript, AppleScript, or Apple Mail.app** — use `gws` tools only for email
- This command is invoked by the scheduler twice a week (Mon and Thu at 10am local) and may also be invoked manually for ad-hoc digests. Both paths are idempotent.

---

## Step 0: Idempotency check

The digest file for today's slot is `~/Briefings/$(date +%Y-%m-%d)-1000-digest.md`. If it exists already, exit cleanly without re-sending — the digest has already been generated for this slot.

```bash
DIGEST_SLUG="$(date +%Y-%m-%d)-1000-digest"
DIGEST_FILE="$HOME/Briefings/${DIGEST_SLUG}.md"
if [ -f "$DIGEST_FILE" ]; then
    echo "Digest already generated for today at $DIGEST_FILE. Skipping."
    exit 0
fi
```

Note: this check uses today's date in local time, matching the slot the scheduler fires in. Manual invocations on the same day are also no-ops.

---

## Step 1: Pull open commitments from the ledger

Use a Python heredoc to read `~/.briefings/decisions.jsonl` via `briefings_mcp.ledger.iter_entries` and split into Yours (owner matches MY_EMAIL, "You", or any token derived from MY_NAME — case-insensitive) and Owed to you (everything else where attendees contains MY_EMAIL).

Include both `state: "open"` and `state: "in-flight"` commitments (both are still in flight from the user's perspective). Decisions are not in scope here.

```bash
LEDGER_OUT=$(MY_EMAIL="$MY_EMAIL" MY_NAME="$MY_NAME" python3 <<'PYEOF'
import os, json, sys
from datetime import datetime, timezone
from briefings_mcp import ledger

my_email = os.environ["MY_EMAIL"].lower()
my_name = os.environ.get("MY_NAME", "").strip().lower()
my_aliases = {my_email, "you"}
if my_name:
    my_aliases.add(my_name)
    first = my_name.split()[0]
    if first:
        my_aliases.add(first)

def is_mine(owner_str):
    if not owner_str:
        return False
    return owner_str.strip().lower() in my_aliases

now = datetime.now(timezone.utc)

mine, owed = [], []
for entry in ledger.iter_entries():
    if entry.get("type") != "commitment":
        continue
    if entry.get("state") not in ("open", "in-flight"):
        continue
    owner = entry.get("owner", "") or ""
    attendees = entry.get("attendees", []) or []
    # parse created_at age in days
    created = entry.get("created_at", "")
    try:
        normalised = created.replace("Z", "+00:00") if created.endswith("Z") else created
        age_days = (now - datetime.fromisoformat(normalised)).days
    except Exception:
        age_days = 0
    record = {
        "id": entry["id"],
        "summary": entry.get("summary", "")[:140],
        "owner": owner,
        "due": entry.get("due"),
        "source_meeting": entry.get("source_meeting", ""),
        "attendees": attendees,
        "created_at": created,
        "age_days": age_days,
    }
    if is_mine(owner):
        mine.append(record)
    elif my_email in [a.lower() for a in attendees]:
        owed.append(record)

print(json.dumps({"mine": mine, "owed": owed}))
PYEOF
)
```

Parse `$LEDGER_OUT` as JSON. The `mine` array becomes the **Yours** section; the `owed` array becomes the **Owed to you** section.

**If both arrays are empty**, jump to Step 5's "nothing open" branch — no email, just a Slack notice. Do not create a digest file or an awaiting-reply file.

---

## Step 2: Smart pre-marking for Yours (best-effort)

For each item in `mine`, search Gmail sent items between its `created_at` and now for messages whose subject or body matches keywords from the commitment summary. If a likely match exists, flag the item with a `done?` confidence mark.

**Implementation**: for each Yours item, run a focused gws gmail search. Extract 2–3 key nouns from the commitment summary (e.g. "send pricing memo to Acme" → "pricing", "Acme") and search:

```bash
gws gmail search --params '{"userId": "me", "q": "in:sent after:YYYY/MM/DD pricing acme"}'
```

(YYYY/MM/DD is the commitment's created_at date, slashes for Gmail's query syntax.)

If the search returns any results, examine the first 2–3 messages briefly — does any actually correspond to this action? Use your judgement. If yes, set `done_hint: true` on the item. If no clear match or the search errors out, leave `done_hint: false`.

**This is best-effort.** If gws is unavailable, if Gmail returns an error, or if you're uncertain, set `done_hint: false` and continue. The digest must ship even if pre-marking fails entirely.

Don't over-apply: the goal is to catch the ~30% of obvious cases where the user has clearly already done the thing. Conservative is better than noisy.

---

## Step 3: Build nudge drafts for overdue Owed-to-you

For each item in `owed`:

- **Overdue check**: `age_days >= 14` OR (`due` is set and parses as an ISO date earlier than today)
- If overdue, draft a 2–3 sentence reminder email to the owner

**Resolve the owner's email**: look at the commitment's `attendees` array and pick the entry whose name fragment matches `owner`. If the attendees are emails like `robert@example.com`, match by substring: does `robert` appear in any attendee? Pick the first match. If no match, skip this nudge (don't draft a reminder you can't send) and log a one-line warning to scheduler.log.

Draft shape (generic but personable):

```
Hi <first name>,

Following up on <commitment summary> from our <meeting name> on <date>. Where does this stand?

— $MY_FIRST_NAME
```

Substitute `$MY_FIRST_NAME` (set at the top of this command from the config) for the actual sign-off. Cap drafts at ~80 words. Don't editorialize about the delay; just ask the question.

Build a `nudges` array of `{to, subject, body}` records in display order. This is what the reply-keyword `send: N` will fire.

---

## Step 4: Assemble the digest markdown

Save to `$DIGEST_FILE` (from Step 0), then `chmod 600` the file.

```markdown
# Actions tracker
**<Day>, <DD Mon YYYY> | 10:00 <TZ>**

*Period themes: topic1 (N), topic2 (M), topic3 (K)*

## Yours
1. *(open N days)* <summary> — <meeting name>, <DD Mon>
2. *done?* *(open N days)* <summary> — <meeting name>, <DD Mon>
3. *(open N days, due DD Mon)* <summary> — <meeting name>, <DD Mon>

## Owed to you
1. *(open N days)* **<Owner first name>** — <summary> — <meeting name>, <DD Mon>
2. *(open N days)* **<Owner first name>** — <summary> — <meeting name>, <DD Mon>

## Nudge drafts
1. **To: <email> — Re: <meeting name>**

   Hi <first name>,

   Following up on <commitment summary> from our <meeting name> on <DD Mon>. Where does this stand?

   — $MY_FIRST_NAME

---

Reply to update:
- `done: 1, 3` — mark Yours items complete in the ledger
- `more: 2` — keep open, snooze to next digest
- `drop: 4` — abandon a Yours item
- `send: 1` — fire Nudge draft #1
- `cancel` — drop this digest thread
- `extend` — reset the 30-day reply window
```

**Period themes line (Phase 4):** Below the date heading, before `## Yours`, render an italic one-liner of recurring topics from the ledger. Call `briefings_mcp.query.find_patterns(window_days=60, min_count=3, limit=3)` (no attendee or topic filter — global view). Format: `*Period themes: topic1 (N), topic2 (M), topic3 (K)*`. Omit the line entirely when `find_patterns` returns an empty list. This is contextual scene-setting, not a section heading.

```bash
THEMES_OUT=$(python3 <<'PYEOF'
import json
from briefings_mcp.query import find_patterns
print(json.dumps(find_patterns(window_days=60, min_count=3, limit=3)))
PYEOF
)
```

**Omit-when-empty**: if there are no Yours items, omit `## Yours` entirely. Same for `## Owed to you` and `## Nudge drafts`. The footer always appears (as long as the digest was generated at all).

**Numbering**: each section's numbering is independent. `done: 1` always means "Yours #1", `send: 2` always means "Nudge drafts #2". The footer's example numbers should match the actual content where possible (e.g. don't say `drop: 4` if Yours has only 3 items).

The age-and-due rendering format: `*(open N days)*` if no due date, `*(open N days, due DD Mon)*` if due is set. If the due date is in the past, use `*(open N days, OVERDUE since DD Mon)*` to call it out.

**`done?` rendering**: prepend `*done?*` *after* the number and dot, before the parenthesized age. Renders as: `2. *done?* *(open 5 days)* Draft 5-page state-of-industry document — SC External Positioning, 20 May`.

---

## Step 5: Deliver

**Email** — to `$MY_EMAIL` using `--html`, subject: `Actions tracker — <Day> <DD Mon> <YYYY>`. Convert the markdown to HTML using the exact Python snippet below — same renderer as `commands/follow-up.md` Step 6, handles `**bold**`, `*italic*`, `[link](url)`, bulleted lists (`- item`), and numbered lists (`1. item`). Do not improvise a different renderer; the digest's italic styling (`*Period themes:*`, `*(open N days)*`, `*done?*`) and numbered lists depend on this behaviour.

```bash
HTML=$(DIGEST_FILE="$DIGEST_FILE" python3 << 'PYEOF'
import os, re

def inline(text):
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'(?<![\w*])\*([^*\n]+?)\*(?![\w*])', r'<i>\1</i>', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    return text

def close_lists(out, state):
    if state['ul']: out.append('</ul>'); state['ul'] = False
    if state['ol']: out.append('</ol>'); state['ol'] = False

lines = open(os.environ['DIGEST_FILE']).read().split('\n')
out = []
state = {'ul': False, 'ol': False}

for line in lines:
    if line.startswith('# '):
        close_lists(out, state)
        out.append(f'<h2 style="margin:0 0 4px 0">{inline(line[2:])}</h2>')
    elif line.startswith('## '):
        close_lists(out, state)
        out.append(f'<h3 style="margin:20px 0 4px 0;border-bottom:1px solid #eee;padding-bottom:4px">{inline(line[3:])}</h3>')
    elif line.startswith('### '):
        close_lists(out, state)
        out.append(f'<h4 style="margin:12px 0 2px 0">{inline(line[4:])}</h4>')
    elif re.match(r'^\s*- ', line):
        if state['ol']: out.append('</ol>'); state['ol'] = False
        content = re.sub(r'^\s*- ', '', line)
        if not state['ul']: out.append('<ul style="margin:4px 0;padding-left:20px">'); state['ul'] = True
        out.append(f'<li style="margin:3px 0">{inline(content)}</li>')
    elif re.match(r'^\s*\d+\.\s+', line):
        if state['ul']: out.append('</ul>'); state['ul'] = False
        content = re.sub(r'^\s*\d+\.\s+', '', line)
        if not state['ol']: out.append('<ol style="margin:4px 0;padding-left:24px">'); state['ol'] = True
        out.append(f'<li style="margin:3px 0">{inline(content)}</li>')
    elif line.strip() == '':
        close_lists(out, state)
        out.append('<div style="margin:6px 0"></div>')
    else:
        close_lists(out, state)
        out.append(f'<p style="margin:3px 0">{inline(line)}</p>')

close_lists(out, state)
print('\n'.join(out))
PYEOF
)
SEND_RESPONSE=$(gws gmail +send --to "$MY_EMAIL" --subject "Actions tracker — $(date '+%A %-d %b %Y')" --body "$HTML" --html)
THREAD_ID=$(printf '%s' "$SEND_RESPONSE" | python3 -c "import sys,json; raw=sys.stdin.read(); b=raw.find('{'); print((json.loads(raw[b:]) if b>=0 else {}).get('threadId',''))")
```

**Slack heads-up** — if `~/.slack_webhook` exists, post a one-line summary:

```
:bookmark_tabs: Actions tracker delivered — <N> yours / <M> owed.
```

Where N is `len(mine)` and M is `len(owed)`. If smart pre-marking flagged some items, add `(<K> may already be done)` to the end.

**"Nothing open" branch** — if both `mine` and `owed` are empty (skipped from Step 1), skip the email entirely. Slack notice:

```
:white_check_mark: Actions tracker: nothing open — clean slate for the week ahead.
```

Exit after the Slack notice. No digest file, no awaiting-reply file.

---

## Step 6: Create the awaiting-digest state file

When at least one of `mine` or `owed` was non-empty AND `$THREAD_ID` is non-empty, create the state file so commands/follow-up.md's Step 0 can route reply-keyword updates.

```bash
umask 077
AWAITING_DIGEST="$HOME/Briefings/$(date +%Y-%m-%d)-1000-awaiting-digest.md"
MINE_IDS_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['LEDGER_OUT'])['mine']))" | python3 -c "import sys,json; print(json.dumps([r['id'] for r in json.load(sys.stdin)]))")
OWED_IDS_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['LEDGER_OUT'])['owed']))" | python3 -c "import sys,json; print(json.dumps([r['id'] for r in json.load(sys.stdin)]))")
NUDGES_JSON='[{"to":"robert@example.com","subject":"Re: SC External Positioning","body":"Hi Robert,..."}]'  # replace with actual computed nudges

TMP="${AWAITING_DIGEST}.tmp"
cat >"$TMP" <<EOF
thread_id: $THREAD_ID
created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
mine: $MINE_IDS_JSON
owed: $OWED_IDS_JSON
nudges: $NUDGES_JSON
last_processed_msg:
EOF
chmod 600 "$TMP"
mv "$TMP" "$AWAITING_DIGEST"
```

Use the tmp+rename pattern modelled on `briefings_mcp/ledger.py:189-196`. Never overwrite the file in place — a crash mid-write would truncate the JSON arrays and lose every action item the digest tracked. This is the same atomic shape that `commands/follow-up.md`'s Step 0 Step 6 watermark write uses for subsequent updates.

The `mine` and `owed` arrays are JSON of UUIDs in **display order** (so `done: 1` resolves to `mine[0]`). The `nudges` array is JSON of `{to, subject, body}` records in display order (so `send: 1` resolves to `nudges[0]`).

`last_processed_msg` is empty initially. `commands/follow-up.md`'s awaiting-digest branch sets it to the Gmail message ID of every user reply it acts on (`done:`/`drop:`/`more:`/`send:`/`extend`/unrecognized), preventing the same reply from being re-processed on the next scheduler cycle. Without this watermark a `more: 2` reply would re-ack on every 15-minute tick until something else moves the thread.

If `$THREAD_ID` is empty (email send didn't return a threadId), log `"WARN: digest sent but threadId not captured — awaiting-digest state skipped for $(date +%Y-%m-%d)"` to `~/Briefings/scheduler.log` and skip the state file. The digest itself is still delivered; only the reply-keyword loop is degraded.

---

## Step 7: Confirm

Tell the user:
- The digest was generated for today
- N yours / M owed (and K with `done?` hints if any)
- Path to the digest file
- That reply keywords (`done:`, `more:`, `drop:`, `send:`, `cancel`, `extend`) will be picked up on the next scheduler cycle via the awaiting-digest state file
