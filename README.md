# meeting-intelligence

Automated pre-meeting briefings and post-meeting follow-ups, powered by Claude Code and your Google Workspace account.

Every 15 minutes a background scheduler checks your calendar. About two hours before a meeting, it generates a briefing (attendees, recent email threads with externals, prior call transcripts, related Drive docs, prep notes) and delivers it to your inbox and a private Slack channel. Within 75 minutes of a meeting ending, it finds the Gemini, Teams, or MacWhisper transcript, extracts actions and decisions, and sends a follow-up. If no transcript is found, it emails you a request that you can reply to with the transcript, "cancel", or "extend".

## What you get

- `/briefing` and `/follow-up` slash commands inside Claude Code
- A `scheduler.sh` that runs every 15 minutes via launchd and decides whether there's any work to do before invoking Claude (skips about 90% of cycles)
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
git clone https://github.com/<your-user>/meeting-intelligence.git
cd meeting-intelligence
bash install.sh
```

The installer asks for two things: the email address briefings should be sent to, and your company's email domain (used to classify meetings as internal vs external). Both are saved to `~/.briefings_config`.

## Update

```bash
cd meeting-intelligence
bash update.sh
```

`update.sh` pulls the latest commands from git, re-applies your saved config, and replaces `~/.claude/commands/briefing.md`, `~/.claude/commands/follow-up.md`, and `~/Briefings/scheduler.sh`. The launchd job keeps running.

## Layout

```
meeting-intelligence/
├── install.sh              # Installs prerequisites, templates, scheduler
├── update.sh               # Pulls latest, re-installs without re-asking config
├── templates/
│   ├── briefing.md         # /briefing slash command, with {{COMPANY_DOMAIN}}
│   ├── follow-up.md        # /follow-up slash command
│   └── scheduler.sh        # The 15-minute scheduler with pre-flight gate
└── README.md
```

After install, files land here:

```
~/.claude/commands/briefing.md         # Substituted copy of the template
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

## How meetings get classified

Each meeting is tagged internal, external, or mixed based on attendee domains.

- **Internal**: every attendee has an `@COMPANY_DOMAIN` address
- **External**: at least one attendee is outside that domain
- **Mixed**: treated as external

External briefings include Gmail thread history, prior call transcripts, and Drive doc context for each external attendee. Internal briefings focus on Slack context and shared docs.

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

## License

MIT
