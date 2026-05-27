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

### Plugin format

The repo is structured as a Claude Code plugin (manifest at `.claude-plugin/plugin.json`). For now, `install.sh` is the supported install path — it sets up the prerequisites, scheduler, and launchd job that the plugin manifest does not cover. A `/plugin install` flow may be wired up later once there's a clean way to skip the scheduler-setup steps from inside a plugin install.

## Update

```bash
cd meeting-intelligence
bash update.sh
```

`update.sh` pulls the latest from git, replaces `~/.claude/commands/briefing.md`, `~/.claude/commands/follow-up.md`, and `~/Briefings/scheduler.sh`, and refreshes the editable install of the `briefings_mcp` package in the runtime venv at `~/.briefings/venv`. Your config and your decision ledger are untouched. The launchd job keeps running.

After updating, you can sanity-check the install end-to-end:

```bash
bash scripts/verify-v1.sh
```

Optional flags:

- `--with-briefing` — force-regenerates the next upcoming meeting's briefing and asserts the SITREP shape (verdict from the closed set, plus `Trap:` / `Delta:` / `Comment:`, and `Counterparty:` for external/mixed meetings). Costs a real `claude -p` call and a couple of minutes.
Replies to any follow-up email with `expand: <request>`, `quote: <topic>`, `cancel`, or `extend` are picked up by the scheduler on the next 15-minute cycle. See "Reply keywords" below for details.

## macOS permission setup

The scheduler runs Claude Code headlessly, so it cannot answer macOS permission dialogs. Two one-time setup steps stop those dialogs from ever blocking a run.

**1. Grant your terminal app the broad TCC permissions.** Child processes inherit TCC from their parent, so once Terminal (or iTerm, Ghostty, Warp) is approved, every future `claude` binary it spawns is too. In System Settings → Privacy & Security, add your terminal to:

- Full Disk Access
- App Management
- Files and Folders

Restart the terminal app after granting.

**2. Auto-prune old Claude Code versions.** The native installer drops every prior version at `~/.local/share/claude/versions/<version>` (~200MB each) and never removes them. macOS keys TCC permissions to the binary file, so each leftover triggers fresh prompts after upgrades. A small script plus a SessionStart hook clears stale binaries automatically.

Save to `~/.local/bin/claude-prune-versions` and `chmod +x`:

```bash
#!/bin/bash
set -euo pipefail
versions_dir="$HOME/.local/share/claude/versions"
symlink="$HOME/.local/bin/claude"
[[ -d "$versions_dir" ]] || exit 0
[[ -L "$symlink" ]] || exit 0
current="$(basename "$(readlink "$symlink")")"
[[ -n "$current" ]] || exit 0
find "$versions_dir" -maxdepth 1 -type f ! -name "$current" -delete 2>/dev/null || true
```

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

With both in place, the headless scheduler does not get blocked by permission prompts after Claude Code upgrades.

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
├── briefings_mcp/          # Local MCP server + ledger module (Python)
├── scripts/
│   ├── scheduler.sh        # The 15-minute scheduler with pre-flight gate
│   └── verify-v1.sh        # End-to-end smoke test
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
LOOKBACK_DAYS=60
```

`LOOKBACK_DAYS` controls how far back the briefing's `Delta:` section looks for prior touchpoints with overlapping attendees. The default of 60 catches quarterly cycles without dredging up stale context — drop it to 30 if you want a tighter window, raise it to 90 if you want longer memory.

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

- `expand: <request>` — re-fetches the meeting transcript (Gemini Doc, Teams Recap, or local MacWhisper file) and runs Claude with your specific ask. Example: `expand: write up Mark's industry overview as a one-pager`. The result lands as a reply in the same email thread (and Slack channel if `~/.slack_webhook` is configured).
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

## Actions tracker

Twice a week — Monday and Thursday at 10am local — the scheduler fires `/digest`, which reads open commitments from the ledger and delivers an actions tracker email plus a one-line Slack heads-up. The cadence is hardcoded; the digest file is named `~/Briefings/YYYY-MM-DD-1000-digest.md` and the scheduler uses its presence as the idempotency check, so re-firing within the same day is a no-op.

The digest has up to three sections:

- **Yours** — open commitments where the owner is you (matched by `MY_EMAIL`, "You", "Mark", or "Mark McDermott", case-insensitive). Each item shows meeting name, age in days, and any due date.
- **Owed to you** — open commitments from your meetings where the owner is someone else. Useful for nudging.
- **Nudge drafts** — pre-written 2 to 3 sentence reminder emails for any Owed-to-you item older than 14 days or past its due date. Each draft is numbered for `send: N` reply triggering.

Each Yours item may also carry a `done?` confidence hint if smart pre-marking found a likely match in your Gmail sent items (best-effort, Gmail-only; gracefully skips on error).

### Reply keywords

Reply to the digest email to update commitment state. The scheduler picks up replies every 15 minutes via a `~/Briefings/YYYY-MM-DD-1000-awaiting-digest.md` state file.

- `done: 1, 3` — mark Yours items 1 and 3 as `state: "done"` in the ledger
- `more: 2` — keep Yours item 2 open, snooze to next digest (no state change, just logged)
- `drop: 4` — mark Yours item 4 as `state: "dropped"`
- `send: 2` — fire Nudge draft 2 to its recipient via Gmail
- `cancel` — drop the awaiting-digest thread (state file deleted, no further polling)
- `extend` — reset the 30-day expiry clock on the awaiting-digest state file

Each successful update gets a one-line acknowledgment reply in the same thread. Unrecognized replies get a one-line "didn't recognize that — try `done:`, `more:`, `drop:`, `send:`, `cancel`, or `extend`" response.

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
