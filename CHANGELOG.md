# Changelog

All notable changes to meeting-intelligence are noted here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions track the
`.claude-plugin/plugin.json` manifest.

## [0.2.0] — 2026-05-19

### Added

- **Decision ledger.** Append-only JSONL at `~/.briefings/decisions.jsonl` (mode 600
  inside a mode-700 directory) records decisions and commitments coming out of every
  follow-up. Single source of truth for "what did we last decide with these people".
- **SITREP brief shape.** `/briefing` now opens with a single-word verdict heading
  (`DECIDE-TODAY`, `DELEGATE`, `DEFER`, `DECLINE`, `PREP-HARD`, `LOW-STAKES`,
  `MOVE-ASYNC`) followed by `Trap:`, `Delta:`, `Comment:`, and — for external/mixed
  meetings only — `Counterparty:` sections. The fuller attendee/document/transcript
  detail follows underneath as a `## Detail` body. Designed to scan in 30 seconds.
- **Counterparty honesty label.** When Gmail/Drive/transcript signal is thin, the
  Counterparty section opens with the literal label *"Limited counterparty signal —
  first known interaction; role assumptions only"* rather than inventing detail.
- **Why-capture loop.** `/follow-up` now classifies extracted items as decisions or
  commitments, appends them to the ledger, and for high-stakes entries attaches a
  numbered "Why?" prompt to the follow-up email. The scheduler polls Gmail for replies
  on `*-awaiting-why-*.md` state files, parses `N: <reason>` lines (quoted text
  stripped), and folds the reasons back into the ledger.
- **Read-only MCP server.** `briefings_mcp` exposes three tools — `search_decisions`,
  `get_decision_by_id`, `list_attendees` — over stdio so Claude Desktop, Claude Code
  in unrelated projects, and other MCP consumers can query the corpus. Registered via
  `claude mcp add briefings --scope user`. SQLite cache at `~/.briefings/decisions.db`
  rebuilds on JSONL mtime change; cold start is sub-second.
- **`LOOKBACK_DAYS` config.** New entry in `~/.briefings_config` controls the
  `Delta:` section's lookback window. Default 60 days; surfaces quarterly cycles
  without dredging up stale context.
- **`scripts/verify-v1.sh`.** End-to-end smoke test covering file-system layout,
  package import, MCP registration, U3 + U4 unit smoke tests, and a fixture-ledger
  MCP-query roundtrip. `--with-email` flag adds a follow-up reply test against
  `MY_EMAIL`.

### Changed

- **`install.sh`** adds a new Step 10 that installs Python (via Homebrew if no
  Python ≥3.10 is on PATH), creates a dedicated runtime venv at
  `~/.briefings/venv`, editable-installs the `briefings_mcp` package so
  `git pull` propagates code changes without re-install, initialises the ledger
  file and `LOOKBACK_DAYS=60` config entry, and registers the MCP server. All
  new steps are idempotent — `~/.briefings/decisions.jsonl` is never truncated
  on re-run, the LOOKBACK_DAYS line is never double-appended, and
  `claude mcp add` is skipped if the server is already registered.
- **`update.sh`** refreshes the editable install after `git pull` and re-validates
  the MCP registration.

### Notes

- Runtime layout: a dedicated venv at `~/.briefings/venv` rather than
  `pip install --user` (PEP 668 blocks it on brew Python) or `uv tool install`
  (uv isn't yet a baseline dependency). Editable install means `update.sh`
  doesn't have to re-install on every code change.
- Schema additions are additive only: future fields can be added without breaking
  the JSONL ledger, and the SQLite index regenerates from JSONL on demand.

## [0.1.0] — 2026-04-13

- Initial release: `/briefing` and `/follow-up` slash commands, a `scheduler.sh`
  fired by launchd every 15 minutes, multi-source context (Gmail, Drive, Slack,
  prior transcripts), and email + Slack delivery.
