# meeting-intelligence

Automated pre-meeting briefings and post-meeting follow-ups, powered by Claude Code and your Google Workspace and Slack accounts.

Every 15 minutes a background scheduler checks your calendar. About two hours before a meeting, it generates a briefing and delivers it to your inbox and a private Slack channel. Within 75 minutes of a meeting ending, it finds the Gemini, Teams, or MacWhisper transcript, extracts actions and decisions, and sends a follow-up. If no transcript is found, it emails you a request that you can reply to with the transcript, "cancel", or "extend".

The thing that makes the briefings actually useful is the cross-source context. For each attendee, Claude reads your recent Gmail threads, prior call transcripts, Drive docs they've touched, and Slack messages where their name has come up. For internal meetings, Slack is the primary signal: what has this person been saying in shared channels, what's the ongoing work between the two of you, what's currently live around the meeting topic. By the time the briefing lands in your inbox, you walk in already knowing where things stand.

## What you get

- `/briefing`, `/follow-up`, and `/digest` slash commands inside Claude Code
- A `scheduler.sh` that runs every 15 minutes via launchd and decides whether there's any work to do before invoking Claude (skips about 90% of cycles)
- Twice-weekly actions tracker digest (Mon and Thu at 10am local) of your open commitments with reply-keyword updates
- Multi-source context: Gmail, Drive, Slack, prior call transcripts
- Email and Slack delivery
- Idempotent installer that's safe to re-run

## Prerequisites

- macOS (Apple Silicon or Intel)
- A Google Workspace account
- A Claude Max subscription, so the scheduler can run unattended
- A private Slack channel + incoming webhook URL (optional)

The installer sets up Homebrew, Node.js, [Claude Code](https://claude.com/claude-code), and [gws](https://github.com/googleworkspace/cli) automatically. gws uses its own bundled OAuth client, so you do not need to create a Google Cloud project.

## Install

```bash
git clone https://github.com/McD/meeting-intelligence.git
cd meeting-intelligence
bash install.sh
```

The installer asks for two things: the email address briefings should be sent to, and your company's email domain (used to classify meetings as internal vs external). Both are saved to `~/.briefings_config`. The slash commands read this config at runtime, so updating either value is just a matter of editing the file (no re-install needed).

**During and after install you'll see macOS permission prompts** — from Terminal first, then from `gtimeout`, then from Claude Code itself once the scheduler starts running. Click Allow on every one. See [macOS permission setup](#macos-permission-setup) below for the full story; for now, Allow is always the right answer.

### Plugin format

The repo is structured as a Claude Code plugin (manifest at `.claude-plugin/plugin.json`). For now, `install.sh` is the supported install path — it sets up the prerequisites, scheduler, and launchd job that the plugin manifest does not cover. A `/plugin install` flow may be wired up later once there's a clean way to skip the scheduler-setup steps from inside a plugin install.

## After install

The launchd job is loaded and running on a 15-minute cadence. Your first briefing arrives roughly **two hours before your next eligible calendar event** (a meeting with 2+ attendees that you haven't declined). Most cycles do nothing — the scheduler skips about 90% of runs when there's no work — so don't expect log spam.

**Sanity-check the install end-to-end:**

```bash
bash scripts/verify-v1.sh
```

13 automated assertions cover file layout, the runtime Python venv, MCP server registration, the decision ledger, the reply-dedup classifier, and the smoke-test harnesses. Each one prints PASS or FAIL. If everything passes, the install is good.

Optional flags exercise the real Claude-call paths (each costs a few API spend and a couple of minutes):

- `--with-briefing` — force-regenerate the next upcoming meeting's briefing and assert SITREP shape (verdict from the closed set, plus `Trap:` / `Delta:` / `Comment:`, and `Counterparty:` for external/mixed)
- `--with-followup` — force-regenerate the latest follow-up and assert Phase 1 shape
- `--with-digest` — force-generate today's digest and assert Phase 3 shape

**Watch the scheduler in real time:**

```bash
tail -f ~/Briefings/scheduler.log
```

A cycle with nothing to do logs `Pre-flight: nothing to do, skipped Claude.` and exits in under a second. A cycle that runs Claude logs `Running: briefing+follow-up` and takes 30 seconds to a few minutes depending on what's pending.

**Reply keywords on follow-up and digest emails** — `expand: <request>`, `quote: <topic>`, `cancel`, `extend` (follow-up); `done: N`, `done-owed: N`, `more: N`, `drop: N`, `not-mine: N`, `drop-owed: N`, `send: N`, `cancel`, `extend` (digest) — are picked up by the next scheduler cycle. See [Reply keywords](#reply-keywords) below for the full list and semantics.

## Update

```bash
cd meeting-intelligence
bash update.sh
```

`update.sh` pulls the latest from git, replaces `~/.claude/commands/briefing.md`, `~/.claude/commands/follow-up.md`, and `~/Briefings/scheduler.sh`, and refreshes the editable install of the `briefings_mcp` package in the runtime venv at `~/.briefings/venv`. Your config and your decision ledger are untouched. The launchd job keeps running. Re-run `bash scripts/verify-v1.sh` after updating if you want belt-and-suspenders confirmation.

## macOS permission setup

**TL;DR.** macOS will prompt for permissions as the scheduler runs. **Click Allow on every dialog you see from Claude Code, `gtimeout`, or a bare version number like `2.1.133`.** These are real and necessary. Expect 3-6 prompts in the first hour after install, then quiet for ~30 days until macOS Sequoia's renewable-consent cycle re-prompts. There is no way to suppress these entirely — only manage them.

The rest of this section is detail for when something doesn't behave the way that TL;DR predicts.

### One-time terminal grant

Grant your terminal app the broad TCC permissions. This covers interactive `claude` runs (when you sign in, debug a failing scheduler cycle, or run `/briefing` by hand). Child processes inherit TCC from their parent, so once Terminal (or iTerm, Ghostty, Warp) is approved, every future `claude` binary it spawns is too. In System Settings → Privacy & Security, add your terminal to:

- Full Disk Access
- App Management
- Files and Folders

Restart the terminal app after granting.

### Why the scheduler still prompts

Terminal's grants do not reach the scheduler. launchd-spawned processes don't inherit TCC from Terminal — their TCC parent is launchd itself. So the first time the scheduler runs after a Claude Code update, macOS will show a permission dialog (typically "`<version>` would like to access data from other apps"). Click Allow. If you miss the prompt the scheduler will fail silently until you do — see `scheduler.log` for `ERROR: …` lines and the Slack heads-up the scheduler posts on Claude Code version change.

If the same prompt re-appears for the same Claude Code version (you've clicked Allow but it keeps re-prompting on each 15-minute cycle), the TCC grant didn't stick — a known macOS quirk for launchd-spawned binaries. Two workarounds:

- Open System Settings → Privacy & Security → App Management and confirm the entry is toggled on. Remove any stale duplicate entries from older Claude versions.
- If it still re-prompts, add `/bin/bash` to App Management (broad but reliable — bash is the launchd entry point for the scheduler).

### macOS Sequoia monthly re-auth

Starting with macOS 15, Apple requires periodic re-authorization for some Privacy permissions — notably "Allow access to data of other apps" (`SystemPolicyAppData`). Even when correctly granted, the prompt will recur every ~30 days. There is no user-level workaround; click Allow and continue. The scheduler will fail silently between the prompt firing and you answering it.

### Auto-prune old Claude versions and their TCC entries

The Claude Code native installer drops every prior version at `~/.local/share/claude/versions/<version>` (~200MB each) and never removes them. Each leftover binary leaves an orphaned macOS TCC permission entry that can re-trigger prompts for the scheduler. A small script plus a SessionStart hook clears both automatically.

Save to `~/.local/bin/claude-prune-versions` and `chmod +x`:

```bash
#!/bin/bash
set -euo pipefail

versions_dir="$HOME/.local/share/claude/versions"
symlink="$HOME/.local/bin/claude"
tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
log_file="$HOME/Briefings/scheduler.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] claude-prune-versions: $1" >> "$log_file" 2>/dev/null || true; }

[[ -d "$versions_dir" ]] || exit 0
[[ -L "$symlink" ]] || exit 0

current="$(basename "$(readlink "$symlink")")"
[[ -n "$current" ]] || exit 0

# Snapshot stale paths BEFORE deleting binaries — needed to match TCC's `client` column.
stale_paths=()
while IFS= read -r f; do
    stale_paths+=("$f")
done < <(find "$versions_dir" -maxdepth 1 -type f ! -name "$current" 2>/dev/null)

# Remove orphaned TCC rows whose path lives under the Claude versions dir.
# Bounded scope: `client_type = 1` restricts to path-based entries (not bundle IDs),
# and equality on `client` only matches the specific stale binary path. No other TCC
# entries are touched.
if [[ -f "$tcc_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    for path in "${stale_paths[@]+"${stale_paths[@]}"}"; do
        escaped="${path//\'/\'\'}"
        err=$(sqlite3 "$tcc_db" "DELETE FROM access WHERE client = '$escaped' AND client_type = 1;" 2>&1)
        rc=$?
        if [[ $rc -ne 0 ]]; then
            # Common causes: TCC.db locked by tccd or System Settings (transient,
            # retried next session) / Full Disk Access not granted to this process
            # (persistent, requires user action). Both leave the binary cleanup intact
            # below; only orphan-row removal degrades.
            log "WARN: sqlite3 DELETE failed for $path (rc=$rc): $err"
        fi
    done
fi

find "$versions_dir" -maxdepth 1 -type f ! -name "$current" -delete 2>/dev/null || true
```

The TCC cleanup step requires Full Disk Access on whatever process actually runs the SessionStart hook. In the typical install the hook is registered in `~/.claude/settings.json` so it runs under Claude Code, which means **Claude Code itself needs FDA** — not just Terminal. If FDA is missing, the sqlite3 call fails with a logged warning and only the binary cleanup runs (next launch of a Claude version still prompts, but stale rows do not accumulate).

Then add a SessionStart hook to `~/.claude/settings.json` (merge into existing `hooks` if present):

```json
"hooks": {
  "SessionStart": [
    {
      "hooks": [
        { "type": "command", "command": "~/.local/bin/claude-prune-versions" }
      ]
    }
  ]
}
```

With both in place, stale Claude Code versions and their orphaned TCC entries no longer accumulate. You'll still get one App Management prompt after each Claude Code upgrade (see note above) — click Allow once per upgrade and the scheduler resumes on the next 15-minute cycle.

## Layout

```
meeting-intelligence/
├── install.sh              # Installs prerequisites, slash commands, scheduler, MCP server
├── update.sh               # Pulls latest, re-installs without re-asking config
├── pyproject.toml          # briefings_mcp package metadata (fastmcp dep)
├── .claude-plugin/
│   └── plugin.json         # Plugin manifest
├── commands/
│   ├── briefing.md         # /briefing slash command
│   ├── follow-up.md        # /follow-up slash command
│   └── digest.md           # /digest slash command (Phase 3 actions tracker)
├── briefings_mcp/
│   ├── server.py           # FastMCP server (search_decisions, get_decision_by_id, list_attendees)
│   ├── ledger.py           # Append-only JSONL ledger + atomic state writes
│   ├── query.py            # SQLite-indexed search + cross-meeting pattern detection
│   ├── replies.py          # Canonical From-header / watermark classifier (used by Step 4 of follow-up.md)
│   └── schema.py           # Ledger entry validation
├── scripts/
│   ├── scheduler.sh        # The 15-minute scheduler with pre-flight gate
│   ├── dedup_ledger.py     # One-time ledger cleanup (Phase 4; dry-run by default)
│   ├── verify-v1.sh        # End-to-end smoke test (13 assertions; --with-* flags exercise real Claude calls)
│   ├── smoke_test_u3p3.py  # Commitment-state mutator
│   ├── smoke_test_u4.py    # Ledger query module
│   ├── smoke_test_u4p4.py  # find_patterns + ledger dedup
│   └── smoke_test_dedup.py # Reply-dedup classifier (28 fixtures incl. third-party attack rows)
└── README.md
```

After install, files land here:

```
~/.claude/commands/briefing.md         # Copy of the slash command
~/.claude/commands/follow-up.md
~/.claude/commands/digest.md
~/Briefings/scheduler.sh
~/Briefings/scheduler.log              # Rolling log, capped at 500KB
~/Briefings/YYYY-MM-DD-HHmm-*.md       # One briefing per meeting
~/Briefings/YYYY-MM-DD-HHmm-followup-*.md
~/Briefings/YYYY-MM-DD-1000-digest.md  # Twice-weekly actions tracker (Mon/Thu)
~/Briefings/*-awaiting-reply-*.md      # Per-meeting reply-keyword state (expand/quote/cancel/extend)
~/Briefings/*-awaiting-digest-*.md     # Per-digest reply-keyword state (done/more/drop/send/cancel/extend)
~/.briefings_config                    # MY_EMAIL, COMPANY_DOMAIN, LOOKBACK_DAYS
~/.briefings/decisions.jsonl           # Decision + commitment ledger (mode 600)
~/.briefings/decisions.db              # SQLite index, rebuilt on JSONL change
~/.briefings/venv/                     # Runtime venv for briefings_mcp + fastmcp
~/.slack_webhook                       # Optional Slack incoming webhook URL
~/Library/LaunchAgents/com.<user>.briefings.plist
```

## Configuration

`~/.briefings_config`:

```
MY_EMAIL=you@example.com
COMPANY_DOMAIN=example.com
MY_NAME=Your Full Name
LOOKBACK_DAYS=60
```

`LOOKBACK_DAYS` controls how far back the briefing's `Delta:` section looks for prior touchpoints with overlapping attendees. The default of 60 catches quarterly cycles without dredging up stale context — drop it to 30 if you want a tighter window, raise it to 90 if you want longer memory.

`MY_NAME` is optional. It widens the "Yours" matcher in `/digest` to catch commitments where the owner is recorded as your display name ("Jane Doe") rather than your email address. If the field is absent the matcher falls back to the local-part of your email — fine for most cases, but if your name appears literally in extracted commitments you'll get better results by setting it.

Edit any value and re-run `update.sh` (or just edit the file; the commands read it on every run).

## What context Claude pulls

Each briefing draws on whichever of these sources have something relevant. Nothing is included if it's empty, so briefings stay scannable.

**For external attendees** (domains outside your `COMPANY_DOMAIN`):

- **Gmail** — last 5 threads involving their address, each with a one-line status summary ("awaiting their response on pricing", "closed, they confirmed the March timeline")
- **Prior call transcripts** — Gemini, Teams Recap, or Google Doc transcripts from the last 6 months that mention them, summarised as 2 to 4 bullets covering what was agreed and what was left open
- **Drive** — docs shared with or by them, or containing their name, in the last 90 days
- **Slack** — any messages in the last 30 days where their name or email appears, summarised in 2 to 3 lines

**For internal attendees** (your own colleagues), Slack is the primary signal:

- **Slack** — recent messages from them in shared channels, anything related to the meeting topic, ongoing work between the two of you
- **Prior call transcripts** — same as above, focused on open actions or decisions relevant to this meeting
- **Drive** — recently shared or modified docs that relate to the meeting topic

**Always included:**

- Any Google Doc, Sheet, or Slide linked from the calendar invite, fetched and summarised in 2 to 3 sentences
- Other Drive docs modified in the last 14 days whose titles or contents match the meeting topic
- **Prep notes** at the bottom: 3 to 5 bullets of synthesised advice (what to lead with, open threads to address, sensitive dynamics, good questions to ask, what success looks like for this meeting)

## Decision ledger and MCP server

Every `/follow-up` writes the decisions and commitments it extracts to an append-only ledger at `~/.briefings/decisions.jsonl`. The next briefing for the same people uses that ledger to fill a `Delta:` section — what changed since the last touchpoint — so the SITREP that lands in your inbox already knows what's still open with this person and what was last decided. Historical entries from before Phase 2 may carry populated `why`/`why_notes` fields from the retired Why? capture loop; the briefing reads them naturally if present.

### Reply keywords

Every follow-up invites four reply keywords on its email thread. The scheduler polls each thread every 15 minutes via the `~/Briefings/*-awaiting-reply-*.md` state file written when the follow-up was sent.

- `expand: <request>` — re-fetches the meeting transcript (Gemini Doc, Teams Recap, or local MacWhisper file) and runs Claude with your specific ask. Example: `expand: write up the industry overview as a one-pager`. The result lands as a reply in the same email thread (and Slack channel if `~/.slack_webhook` is configured).
- `quote: <topic>` — returns 3 to 6 direct quotes from the transcript where speakers discuss the topic. Useful for pulling out the actual lines someone said about a thing.
- `cancel` — drops the reply thread for this meeting. The state file is deleted.
- `extend` — resets the 30-day expiry clock. Use when you want to come back to a meeting weeks later.

Each follow-up email ends with a one-line footer listing these keywords. Anything else replied to the thread gets a one-line "didn't recognize that keyword" response so you know the system saw your message.

A local read-only MCP server (`briefings_mcp`) exposes the ledger to anything else that speaks MCP — Claude Desktop, Claude Code in unrelated projects, future MCP consumers — via three tools:

- `search_decisions(attendee, topic, type, date_from, date_to, state, limit)`
- `get_decision_by_id(id)`
- `list_attendees(limit)`

The server runs from a dedicated Python venv at `~/.briefings/venv` and is registered automatically by `install.sh` via `claude mcp add briefings --scope user`. Confirm with `claude mcp list | grep briefings`.

The briefing itself reads the ledger inline (no MCP roundtrip on the hot path); the MCP server is purely the read path for external agents.

### Pattern flags

Phase 4 added cross-meeting pattern detection. The function `briefings_mcp.query.find_patterns` scans the ledger for recurring topic tags within the last 60 days and surfaces the top three. Patterns appear in three places:

- **In `/briefing`**, as a `Patterns:` line in the SITREP block (after `Counterparty:`). Filtered by this meeting's attendees, so the patterns shown are the ones this person keeps raising in your meetings.
- **In `/follow-up`**, as a `## Pattern flags` section between `## Counterparty read` and `## Source`. Filtered by this meeting's topic tags — i.e. the recurring themes this meeting reinforced.
- **In `/digest`**, as a one-line italic period themes summary at the top. Global view: the period's top recurring tags across all your meetings.

A "pattern" is a topic tag appearing in three or more ledger entries within the 60-day window. The cap is three patterns per surface, sorted by frequency. When no topic clears the threshold, the line or section is omitted.

Topic tags come from `/follow-up`'s Step 4 (Claude infers 1-3 tags per commitment or decision). The detection is exact-match, case-insensitive — if you want pattern flags to be sharper, the lever is the tagging step, not the detection step.

### Ledger dedup

`/follow-up --force` re-extractions used to accumulate near-identical commitment entries in the ledger (3+ copies of the same Robert action surfaced during Phase 3 testing). Phase 4 fixed this at two layers:

- **Dedup-on-write** in `briefings_mcp.ledger.append`: when a new commitment is appended, the last 50 entries are scanned for the same `source_meeting` with an exact or 60-character-prefix match on `summary`. If a match exists, the write is a silent no-op.
- **One-time cleanup script** at `scripts/dedup_ledger.py`: scans the entire ledger for duplicate commitment clusters within the same source_meeting and reports them. Dry-run by default. Run with `--apply` to actually rewrite the ledger (atomically, via tmp file + os.replace).

```bash
python3 scripts/dedup_ledger.py           # dry-run: report clusters, change nothing
python3 scripts/dedup_ledger.py --apply   # rewrite the ledger, keeping the survivor per cluster
```

The survivor per cluster is picked by state rank first (`done` > `dropped` > `in-flight` > `open`) and earliest `created_at` as the tiebreak. The dry-run prints the survivor and the entries to be removed so you can review before committing.

Decisions are never deduped — only commitments. The schema is unchanged.

## Actions tracker

Twice a week — Monday and Thursday at 10am local — the scheduler fires `/digest`, which reads open commitments from the ledger and delivers an actions tracker email plus a one-line Slack heads-up. The cadence is hardcoded; the digest file is named `~/Briefings/YYYY-MM-DD-1000-digest.md` and the scheduler uses its presence as the idempotency check, so re-firing within the same day is a no-op.

The digest has up to three sections:

- **Yours** — open commitments where the owner is you (matched case-insensitively against `MY_EMAIL`, the literal "You", and any token derived from `MY_NAME` if set). Each item shows meeting name, age in days, and any due date.
- **Owed to you** — open commitments from your meetings where the owner is someone else. Useful for nudging.
- **Nudge drafts** — pre-written 2 to 3 sentence reminder emails for any Owed-to-you item older than 14 days or past its due date. Each draft is numbered for `send: N` reply triggering.

Each Yours item may also carry a `done?` confidence hint if smart pre-marking found a likely match in your Gmail sent items (best-effort, Gmail-only; gracefully skips on error).

### Reply keywords

Reply to the digest email to update commitment state. The scheduler picks up replies every 15 minutes via a `~/Briefings/YYYY-MM-DD-1000-awaiting-digest.md` state file.

- `done: 1, 3` — mark Yours items 1 and 3 as `state: "done"` in the ledger
- `done-owed: 2` — mark Owed-to-you item 2 as `state: "done"` (use when Step 2's Slack pre-marking flagged it `*done?*` and you can confirm)
- `more: 2` — keep Yours item 2 open, snooze to next digest (no state change, just logged)
- `drop: 4` — mark Yours item 4 as `state: "dropped"`
- `not-mine: 5` — disown Yours item 5; sets `owner` to `"unassigned"` and the item disappears from both sections of future digests (useful when extraction over-attributed an action to you)
- `not-mine: 5 → Cédric` — same as `not-mine: 5` but reassigns ownership to a named person; the item reappears in **Owed to you** on the next cycle
- `drop-owed: 2` — mark Owed-to-you item 2 as `state: "dropped"` (useful for FYI items captured as commitments that aren't actually owed to you)
- `send: 2` — fire Nudge draft 2 to its recipient via Gmail
- `cancel` — drop the awaiting-digest thread (state file deleted, no further polling)
- `extend` — reset the 30-day expiry clock on the awaiting-digest state file

Each section is capped at 15 items per digest, newest first; the older overflow is kept in the ledger and counted in an italic "…and N more older items hidden" line. The cap shrinks naturally as you reply `done:` / `done-owed:` / `drop:` / `not-mine:` / `drop-owed:` and older items become visible.

Items may carry up to two best-effort annotations from Step 2's cross-source enrichment: `*done?*` when Gmail or Slack suggests the relevant person has already done the thing (works for both sections — your sent messages for Yours, the owner's Slack messages for Owed), and an indented italic `*Next: <event name> on <DD Mon>*` line when one of the item's attendees is on your calendar in the next 14 days. The `*done?*` mark is a hint, not a claim; use `done:` / `done-owed:` to confirm.

Each successful update gets a one-line acknowledgment reply in the same thread. Unrecognized replies get a one-line "didn't recognize that — try `done:`, `done-owed:`, `more:`, `drop:`, `not-mine:`, `drop-owed:`, `send:`, `cancel`, or `extend`" response.

If the ledger has no open commitments on a Mon or Thu, the digest skips the email entirely and posts a single Slack notice ("Actions tracker: nothing open — clean slate for the week ahead."). No empty email lands in your inbox.

To disable the digest, either comment out the `NEED_DIGEST` gate in `scripts/scheduler.sh` (around line 179) or delete `~/.claude/commands/digest.md` — the scheduler falls through to existing briefing and follow-up logic without it.

## How meetings get classified

- **Internal**: every attendee has an `@COMPANY_DOMAIN` address
- **External**: at least one attendee is outside that domain
- **Mixed**: treated as external

## How the scheduler decides whether to run Claude

Every 15 minutes the scheduler does this in plain bash before touching Claude:

1. Check gws OAuth token. If expired, notify Slack and exit
2. Pull the next 2 hours of calendar events
3. Decide whether any meeting needs a briefing (no briefing file on disk yet and starts within 2h) or a follow-up (ended in the last 2 days, no follow-up file yet)
4. Check for any `*-awaiting-*.md` files indicating pending transcript, reply-keyword, or digest-reply replies
5. Check if it's Monday or Thursday between 10:00 and 10:14 local time and today's digest file does not yet exist

If nothing needs doing, it exits without invoking Claude. In practice this skips about 90% of runs, which keeps Claude usage predictable. When multiple tasks are pending (e.g. a briefing AND a follow-up AND the Mon/Thu digest), the scheduler runs them in sequence within a single Claude invocation to keep the token budget tight.

## Troubleshooting

```bash
launchctl list | grep briefings    # Is the scheduler loaded?
tail -50 ~/Briefings/scheduler.log # What did the last few runs do?
gws auth login                     # Re-authenticate Google
claude                             # Open Claude Code interactively to debug
```

Common issues:

- **No briefings arriving**: confirm `launchctl list | grep briefings` shows the job, then check the log. If the log says "auth check failed", run `gws auth login`.
- **gws auth keeps expiring**: gws uses bundled OAuth credentials. If your Workspace admin restricts third-party OAuth apps, you may need a custom client (out of scope here).
- **"command not found: /briefing"**: close and reopen Claude Code so it picks up the newly-installed slash command.
- **Briefings stopped after a Claude Code update**: Claude Code occasionally re-prompts for permissions after major updates, which the headless scheduler cannot answer. The scheduler detects version changes and posts a heads-up to Slack when this happens. If the log shows "Claude Code is asking for permission approval", open a terminal, run `claude` once, accept any prompts (in particular re-enabling `--dangerously-skip-permissions` if it asks), then briefings resume on the next 15-minute cycle. To stop this from happening in the first place, follow the macOS permission setup section above.

## License

MIT
