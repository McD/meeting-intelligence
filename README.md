# meeting-intelligence

Automated pre-meeting briefings and post-meeting follow-ups, powered by Claude Code and your Google Workspace and Slack accounts.

Every 15 minutes a background scheduler checks your calendar. About two hours before a meeting, it generates a briefing and delivers it to your inbox and a private Slack channel. Within 75 minutes of a meeting ending, it finds the Gemini, Teams, or MacWhisper transcript, extracts actions and decisions, and sends a follow-up. If no transcript is found, it emails you a request that you can reply to with the transcript, "cancel", or "extend".

The thing that makes the briefings actually useful is the cross-source context. For each attendee, Claude reads your recent Gmail threads, prior call transcripts, Drive docs they've touched, and Slack messages where their name has come up. For internal meetings, Slack is the primary signal: what has this person been saying in shared channels, what's the ongoing work between the two of you, what's currently live around the meeting topic. By the time the briefing lands in your inbox, you walk in already knowing where things stand.

## What you get

- `/briefing` and `/follow-up` slash commands inside Claude Code
- A `scheduler.sh` that runs every 15 minutes via launchd and decides whether there's any work to do before invoking Claude (skips about 90% of cycles)
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

`update.sh` pulls the latest from git and replaces `~/.claude/commands/briefing.md`, `~/.claude/commands/follow-up.md`, and `~/Briefings/scheduler.sh`. Your config is untouched. The launchd job keeps running.

## Layout

```
meeting-intelligence/
├── install.sh              # Installs prerequisites, slash commands, scheduler
├── update.sh               # Pulls latest, re-installs without re-asking config
├── .claude-plugin/
│   └── plugin.json         # Plugin manifest
├── commands/
│   ├── briefing.md         # /briefing slash command
│   └── follow-up.md        # /follow-up slash command
├── scripts/
│   └── scheduler.sh        # The 15-minute scheduler with pre-flight gate
└── README.md
```

After install, files land here:

```
~/.claude/commands/briefing.md         # Copy of the slash command
~/.claude/commands/follow-up.md
~/Briefings/scheduler.sh
~/Briefings/scheduler.log              # Rolling log, capped at 500KB
~/Briefings/YYYY-MM-DD-HHmm-*.md       # One briefing per meeting
~/Briefings/YYYY-MM-DD-HHmm-followup-*.md
~/.briefings_config                    # MY_EMAIL and COMPANY_DOMAIN
~/.slack_webhook                       # Optional Slack incoming webhook URL
~/Library/LaunchAgents/com.<user>.briefings.plist
```

## Configuration

`~/.briefings_config`:

```
MY_EMAIL=you@example.com
COMPANY_DOMAIN=example.com
```

Edit either value and re-run `update.sh` (or just edit the file; the commands read it on every run).

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

## How meetings get classified

- **Internal**: every attendee has an `@COMPANY_DOMAIN` address
- **External**: at least one attendee is outside that domain
- **Mixed**: treated as external

## How the scheduler decides whether to run Claude

Every 15 minutes the scheduler does this in plain bash before touching Claude:

1. Check gws OAuth token. If expired, notify Slack and exit
2. Pull the next 2 hours of calendar events
3. Decide whether any meeting needs a briefing (no briefing file on disk yet and starts within 2h) or a follow-up (ended in the last 2 days, no follow-up file yet)
4. Check for any `*-awaiting-*.md` files indicating pending transcript replies

If nothing needs doing, it exits without invoking Claude. In practice this skips about 90% of runs, which keeps Claude usage predictable. When both a briefing and a follow-up are needed, it does one combined Claude call instead of two.

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
- **Briefings stopped after a Claude Code update**: Claude Code occasionally re-prompts for permissions after major updates, which the headless scheduler cannot answer. The scheduler detects version changes and posts a heads-up to Slack when this happens. If the log shows "Claude Code is asking for permission approval", open a terminal, run `claude` once, accept any prompts (in particular re-enabling `--dangerously-skip-permissions` if it asks), then briefings resume on the next 15-minute cycle.

## License

MIT
