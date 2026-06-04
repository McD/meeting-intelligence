# Changelog

All notable changes to meeting-intelligence are noted here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions track the
`.claude-plugin/plugin.json` manifest.

## Unreleased

### Added

- **`MY_NAME` config field** — optional entry in `~/.briefings_config`. Widens the
  `/digest` "Yours" matcher so commitments recorded under your display name
  (e.g. "Jane Doe") get attributed correctly. Falls back to the local-part of
  `MY_EMAIL` if absent. `install.sh` prompts for it as a third question.
- **`not-mine: N` and `not-mine: N → <name>` digest reply keywords** — disown
  a Yours item the extractor over-attributed to you, optionally reassigning to
  a named person. Backed by a new `briefings_mcp.ledger.update_commitment_owner`
  mutator with the same atomic-rewrite shape as `update_commitment_state`.
- **`drop-owed: N` digest reply keyword** — drop an Owed-to-you item that was
  captured as a commitment but is actually FYI noise. Symmetric counterpart to
  `drop: N` for the other section.
- **Per-section digest cap** — `## Yours` and `## Owed to you` are now sorted
  newest-first and capped at 15 items each. The overflow count is surfaced in
  an italic "…and N more older items hidden" line so suppressed items remain
  visible-by-inference. Older items become visible as you prune the recent
  ones with `done:` / `drop:` / `not-mine:` / `drop-owed:`.
- **Slack done-detection** — `/digest` Step 2's pre-marking now also searches
  Slack via the `slack_search_public_and_private` MCP tool, in addition to
  the existing Gmail sent-items search. Applies to both `mine` items (looks
  for the user's own Slack messages mentioning the commitment's keywords) and
  `owed` items (looks for the owner's Slack messages). Mirrors the cross-
  source signal that `/briefing` already uses for attendee context.
- **Upcoming-meeting cross-reference** — `/digest` Step 2 now fetches the
  user's calendar for the next 14 days in one call, and annotates each item
  with `next_meeting: {name, date}` when one of its attendees has an event
  with the user in that window. Renders as an indented italic
  `*Next: <event> on <DD Mon>*` line below the item, giving the user a
  natural in-person moment to act on it.
- **`done-owed: N` digest reply keyword** — symmetric counterpart to `done: N`
  for the Owed-to-you section. Pairs with the new Slack pre-marking: the
  digest flags `*done?*` on an Owed item, the user confirms via
  `done-owed: N`, ledger entry transitions to `state: "done"`.
- **`research: <query>` reply keyword on every outbound email** — briefings,
  follow-ups, and digests now all accept a `research:` reply that runs web
  research via the `WebSearch` / `WebFetch` MCP tools and replies with a
  200–800 word synthesized answer on the same Gmail thread (mirrored to
  Slack). Works without a transcript — the right tool for "tell me more about
  this company / topic / person" replies that `expand:` could not service.
- **Briefings now create an awaiting-reply state file** at
  `~/Briefings/YYYY-MM-DD-HHmm-awaiting-reply-briefing-<slug>.md`, mirroring
  the existing follow-up state-file shape. The dispatcher in
  `commands/follow-up.md` Step 0 handles briefing-thread replies without
  modification (the `-awaiting-reply-` basename check matches both filenames).
  Pre-meeting replies asking for context now have a place to land.
- **Consistent HTML renderer across all three email types.**
  `commands/briefing.md` Step 7 was upgraded to the same renderer used by
  follow-ups and digests — italic, numbered lists, bulleted lists, links,
  bold all render identically across every email this system sends. Reply
  footers use the same `---` separator and bullet shape across briefing,
  follow-up, and digest.
- **`expand:` and `quote:` fail gracefully on briefing threads** (which have
  no transcript). The dispatcher now responds with a one-line nudge
  suggesting `research:` instead, rather than the older "transcript no longer
  available" wording that implied the transcript had been deleted.
- **`docs/README.md`** — short note framing the `docs/` folder as build-time
  working notes rather than authoritative product documentation.

### Changed

- **Genericised hardcoded identity strings** in `commands/digest.md` and
  `commands/follow-up.md`. The matcher now reads `MY_NAME` from config instead
  of literal first-name fallbacks; example strings in the bot-vs-user
  disambiguation and Teams transcript notes use generic placeholders. No
  behaviour change for installs that set `MY_NAME` to their actual full name.
- **Tighter `/follow-up` action-item extraction.** Step 3's prompt now
  explicitly excludes personal logistics, generic intentions, and passing
  mentions from action items, and explicitly assigns `owner` to the doer rather
  than to whoever's name appears in the action body. Step 4's ledger-write
  block repeats the owner rule at the durable boundary. Past extractions are
  cleanable via `not-mine:` / `drop-owed:`; the prompt change reduces the
  inflow of those items at source.
- **Digest filter skips unassigned owners.** Items with `owner` empty or equal
  to `"unassigned"` are filtered out of both Yours and Owed-to-you (kept in
  the ledger for audit; suppressed from the rendered digest).

### Fixed

- **Digest numbering resets across items in the rendered email.** The
  `md_to_html` renderer closed the `<ol>` on every indented continuation line
  (e.g. `*Next: …*`) and every blank line inside a list, so each numbered
  item with a continuation — and every Nudge draft, which has blank lines
  between header and body — became its own `<ol>` starting at 1. Reply
  keywords like `done: 3` therefore couldn't reliably target an item.
  Indented non-list lines now fold into the preceding `<li>` with a `<br>`
  separator, and blank lines inside a list defer the close until a heading
  or unindented prose is reached.
- **Digest meeting names render cleanly from `meeting_title`.** Commitments
  now persist the calendar event's original `summary` (e.g.
  `"AI Proposal Review (Data Tools)"`, `"1:1 Mark / Cedric"`) as
  `meeting_title` on the ledger entry. `/digest` uses this verbatim when
  rendering the `<meeting name>` slot, instead of slugifying or relying on
  LLM judgement to invert the slug back into a readable title. A new
  `briefings_mcp.format.pretty_meeting_title` helper handles the fallback for
  legacy entries written before `meeting_title` was captured — strips the
  date prefix, converts kebab to spaces, restores common acronyms (`AI`,
  `SC`, `McD`, `ScreenCloud`), and folds `1 1` into `1:1`.

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
