---
title: "feat: SITREP brief + decision ledger + counterparty section (v1)"
type: feat
status: active
date: 2026-05-19
origin: docs/brainstorms/2026-05-19-sitrep-ledger-counterparty-v1-requirements.md
---

# feat: SITREP brief + decision ledger + counterparty section (v1)

## Summary

Ship the three v1 components together as one coherent release: a Python ledger module + FastMCP-based MCP server, follow-up.md changes that write decisions and commitments to the ledger and prompt for *why* via email reply on high-stakes entries, and a briefing.md restructure that outputs the new SITREP shape (verdict + trap + delta + comment + counterparty) reading from the ledger inline.

---

## Problem Frame

The brainstorm doc establishes the situational frame: briefings are atomic, decisions are ephemeral, the system never compounds. This plan addresses the HOW; the WHY lives in `docs/brainstorms/2026-05-19-sitrep-ledger-counterparty-v1-requirements.md`.

---

## Requirements

This plan implements all 17 requirements from the origin document (R1–R17). Key implementation-bearing requirements:

- **R1–R4** — Ledger schema (JSONL at `~/.briefings/decisions.jsonl`, mode 600, decision and commitment entry shapes)
- **R5–R9** — SITREP brief output shape (verdict word set, four/five sections, Delta computed against ledger)
- **R10** — Counterparty section honesty label when data is thin
- **R11–R14** — Why-capture filter, prompt format, reply parsing
- **R15–R16** — Local read-only MCP server, registered via `claude mcp add`
- **R17** — Existing delivery channels and scheduler mechanics unchanged

**Origin actors:** A1 User, A2 Scheduler, A3 `/briefing`, A4 `/follow-up`, A5 MCP consumer, A6 Counterparty.

**Origin flows:** F1 Brief generation against the ledger, F2 Decision + commitment extraction + ledger append, F3 Why-capture via email reply, F4 MCP query against the ledger.

**Origin acceptance examples:** AE1–AE6 are carried through into per-unit test scenarios (see `Covers AE<N>` prefixes in test scenarios below).

---

## Scope Boundaries

Non-goals carried verbatim from the origin's Scope Boundaries (local mic capture, audio briefings, Slack-incoming bot, counterparty-facing sends, team-visible briefings, Strategy.md surfaces, ad-hoc context, decline-or-async, pluggable sources framework, backfill, web UI). Plus plan-local exclusions:

- No automated test suite (pytest, etc.) — the codebase has zero tests today; adding one is a separate initiative.
- No performance benchmarking infrastructure — projections rely on FastMCP and SQLite published characteristics.
- No MCP server uninstall script (TODO note added but not implemented in v1).
- No plugin-manifest-embedded `mcpServers` block — blocked by upstream parser bug [anthropics/claude-code#16143](https://github.com/anthropics/claude-code/issues/16143). Registration uses `claude mcp add` directly.

### Deferred to Follow-Up Work

- **MCP server uninstall** — add `claude mcp remove briefings` step to a future `uninstall.sh`. Not in v1.
- **Per-config-var lookback override** — surfaces in install.sh prompt only if a user asks; v1 ships with `LOOKBACK_DAYS=60` default and supports manual override via `~/.briefings_config` edit.

---

## Context & Research

### Relevant Code and Patterns

- `scripts/scheduler.sh` — pre-flight gate, `notify_slack()` / `log()` helpers, lockfile + trap, embedded Python for calendar parsing, `umask 077`, `.gws_auth_failed` sentinel pattern. The new why-capture flow mirrors the existing `*-awaiting-*.md` polling pattern in Step 0 of `commands/follow-up.md`.
- `commands/follow-up.md` Step 0 — the awaiting-transcript polling logic the new why-capture flow models itself on. Stores `thread_id`, `meeting`, `slug`, `requested_at` in a state file; scheduler poll detects replies.
- `commands/follow-up.md` Step 3 — existing decision and action extraction logic. v1 reuses this without modification; the new work is classification + ledger append AFTER extraction.
- `commands/briefing.md` Step 3 (attendee research) and Step 5 (assembly) — these are the closest existing surfaces to the new SITREP shape. The new prompt extends the assembly section.
- `install.sh` Step 8 (command files) — pattern for landing slash commands. The new install steps follow this shape for the Python package and MCP registration.
- `update.sh` — straight `cp` pattern for keeping live files in sync with the repo. Extends to copy `briefings_mcp/` and re-run `pip install --user` on update.

### Institutional Learnings

- **gws Gmail thread-ID pattern.** `gws gmail +send` returns `threadId`; subsequent reply detection polls `gws gmail users threads get` and checks `messages.length > 1`. The transcript-awaiting flow proves this pattern works reliably under the scheduler. Reused for why-capture.
- **`umask 077` plus `chmod 600`.** All sensitive files (`~/.briefings_config`, `~/.slack_webhook`, briefings, follow-ups) use this combination. The new `~/.briefings/decisions.jsonl` and `~/.briefings/decisions.db` cache file follow suit.
- **gws ships its own OAuth client.** No Google Cloud project setup needed for Gmail/Drive/Calendar — the existing `gws auth login` flow covers the new email-reply parsing too.
- **Claude.ai connectors flow through keychain to headless `claude -p`.** Continues to apply for the new SITREP brief generation. No new auth surface.

### External References

- [Claude Code MCP docs (code.claude.com)](https://code.claude.com/docs/en/mcp) — `claude mcp add` is the canonical 2026 registration path.
- [FastMCP updates (gofastmcp.com)](https://gofastmcp.com/updates) — recommended Python MCP framework. Pin to `>=2.11,<3`; 3.x adds auth/OpenTelemetry that are unnecessary for a local single-user server.
- [Inline mcpServers bug in plugin.json (#16143)](https://github.com/anthropics/claude-code/issues/16143) — confirms `claude mcp add` is the correct registration path over plugin-manifest embedding.
- [MCP stdio SIGTERM lifecycle (#40207)](https://github.com/anthropics/claude-code/issues/40207) — Claude Code spawns stdio MCP servers on-demand and may SIGTERM on cold start; persist the SQLite index to disk so startup is sub-second.
- [SQLite over JSONL append-only ingest](https://sqlite.org/forum/info/8455e73e3948b80ab8cb5ef471d6205c03c26932616ba490fedd1a0f336045d2) — bulk `executemany()` plus `orjson` parses ~270K rows/sec, well above projected scale.

---

## Key Technical Decisions

- **MCP runtime: Python via FastMCP 2.x.** Matches the existing embedded Python in `scripts/scheduler.sh`. No new toolchain (avoids TypeScript/Node from `@notionhq/notion-mcp-server`-style npx pattern; avoids Rust build burden). Install via `pip install --user 'fastmcp>=2.11,<3'`. Pin range is conservative; 3.x's auth/telemetry features are unnecessary for a local single-user server and introduce churn.
- **MCP registration via `claude mcp add` writing to `~/.claude.json`.** Bypasses the known parser bug [#16143](https://github.com/anthropics/claude-code/issues/16143) that drops inline `mcpServers` in `.claude-plugin/plugin.json`. User-scoped registration so the server is available across all Claude Code projects.
- **JSONL canonical, SQLite as derived in-memory index, cached to disk.** Avoids the trap of switching the primary store to SQLite (which would lose append-from-bash, git-friendliness, human-readability). The index file `~/.briefings/decisions.db` is rebuilt from JSONL on mtime change; cold starts read the cache instead of re-parsing the full ledger. Acceptable to projected scale (~50K rows).
- **Three narrow MCP tools, not one mega-tool.** `search_decisions(filters)`, `get_decision_by_id(id)`, `list_attendees()`. Flat JSON Schema 2020-12. Claude picks narrow tools better than it fills optional parameters.
- **Briefing reads ledger inline; only OTHER agents go through MCP.** `commands/briefing.md` is privileged enough to read `~/.briefings/decisions.jsonl` directly via embedded Python — no need for an MCP roundtrip to query its own data. The MCP server exists so Claude Desktop and future agents can query the corpus.
- **Why-capture mirrors the awaiting-transcript file pattern.** New `~/Briefings/*-awaiting-why-<slug>.md` files carry `thread_id` + pending entry IDs. Scheduler's existing Step-0 polling loop extends to handle them — one new branch in an existing pattern, not a new pattern.
- **Email reply parsing: strip quoted lines, match `^\s*(\d+):\s+(.+)$`.** Robust across Gmail/Apple Mail/Outlook/phone clients because they all prefix quoted text with `>`. The prompt instructs the user to reply `N: <reason>` per line, which the parser maps back to pending entry IDs via the awaiting-why state file.
- **Delta lookback: 60 days, configurable via `LOOKBACK_DAYS` in `~/.briefings_config`.** 30 misses quarterly-cadence cycles; 90 surfaces stale context. Config-var lets power users tune without code changes.
- **Multi-touchpoint tie-breaker for Delta: rank by topic-overlap count then recency.** Surface up to 2 prior touchpoints in the `Delta:` section to keep briefings scannable.
- **Hard-coded high-stakes filter (not config-driven) in v1.** Per origin Key Decision. Filter triggers on verdict ∈ {`DECIDE-TODAY`, `DECLINE`, `PREP-HARD`} OR meeting is external/mixed OR an attendee has 5+ prior ledger entries.

---

## Open Questions

### Resolved During Planning

- **MCP server runtime** → Python (FastMCP 2.x). See Key Technical Decisions.
- **MCP registration path** → `claude mcp add briefings --scope user -- python -m briefings_mcp`. See Key Technical Decisions.
- **Index strategy** → JSONL canonical, SQLite in-memory + disk cache. See Key Technical Decisions.
- **Email reply parsing** → quoted-line strip + `^\s*(\d+):\s+(.+)$` per line. See Key Technical Decisions.
- **Lookback window** → 60 days default, configurable. See Key Technical Decisions.
- **Multi-touchpoint tie-breaker** → topic-overlap then recency, top-2. See Key Technical Decisions.

### Deferred to Implementation

- **`pip install --user` vs `pipx`/`uv tool install`**: `pip install --user` is the lowest-friction path on macOS but may collide with system Python. `uv tool install` would create an isolated environment but adds a tool dependency. Decide during U6 based on what's already present on the user's machine (uv is widely installed in this environment per the methodology profile).
- **Tagging `topics:` array from extraction**: the existing follow-up.md extraction produces prose; tags need to be either inferred by Claude during extraction (cheap, fuzzy) or normalised post-hoc (expensive, brittle). Pick fuzzy-Claude-inferred during U2; revisit if topic-tag drift becomes a query problem.
- **Verdict assignment in `commands/briefing.md`**: which signals drive verdict selection? Probably a combination of agenda content + attendee history + open commitments. Final prompt heuristics need iteration against real meetings during U5; ship with a conservative default and tune.
- **`briefings_mcp` package install location**: site-packages vs editable install pointing at the repo. For `update.sh` to keep the package in sync without manual re-install, editable (`pip install -e`) is cleaner. Decide during U6.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
                       ┌─────────────────┐
                       │  Claude Code    │
                       │  (interactive)  │
                       └────────┬────────┘
                                │ MCP stdio
                                ▼
       ┌──────────────────────────────────────────────┐
       │  briefings_mcp/server.py (FastMCP)           │
       │   • search_decisions(filters)                │
       │   • get_decision_by_id(id)                   │
       │   • list_attendees()                         │
       └────────┬─────────────────────────────────────┘
                │ read-only
                ▼
       ┌──────────────────────────────────────────────┐
       │  briefings_mcp/index.py + query.py           │
       │   • SQLite in-memory index                   │
       │   • cached to ~/.briefings/decisions.db      │
       │   • rebuilt on JSONL mtime change            │
       └────────▲─────────────────────────────────────┘
                │ reads (canonical)
                │
      ┌─────────┴───────────┐                  ┌─────────────────────┐
      │ ~/.briefings/       │ ◄── append ──── │  /follow-up         │
      │   decisions.jsonl   │                  │  (commands/         │
      │   (mode 600)        │                  │   follow-up.md)     │
      └─────────▲───────────┘                  └─────────┬───────────┘
                │ reads inline                            │
                │                                         │ writes
      ┌─────────┴───────────┐                  ┌─────────▼───────────┐
      │  /briefing          │                  │  *-awaiting-why-    │
      │  (commands/         │                  │   <slug>.md         │
      │   briefing.md)      │                  │  (state file)       │
      │   • SITREP output   │                  └─────────▲───────────┘
      │   • Delta from JSONL│                            │ polls
      │   • Counterparty    │                  ┌─────────┴───────────┐
      └─────────────────────┘                  │  scheduler.sh       │
                                               │  Step 0 (existing)  │
                                               │  + why-capture branch
                                               └─────────────────────┘
```

The MCP server is **only on the read path for external agents**. `/briefing` reads JSONL directly; `/follow-up` writes JSONL directly. This keeps the v1 substrate single-writer (no concurrency design needed).

---

## Implementation Units

- U1. **Ledger schema and Python helper module**

**Goal:** Define the v1 ledger schema in code and provide a single small Python module (`briefings_mcp/ledger.py`) that other parts of the system call to append entries and read filtered entries.

**Requirements:** R1, R2, R3, R4.

**Dependencies:** None.

**Files:**
- Create: `briefings_mcp/__init__.py` (empty)
- Create: `briefings_mcp/ledger.py`
- Create: `briefings_mcp/schema.py` (entry shape constants, valid state values, the high-stakes filter rule)

**Approach:**
- `ledger.py` exposes `append(entry: dict) -> None` (validates against `schema.py`, writes JSONL line, fsyncs) and `iter_entries(since: date | None = None) -> Iterator[dict]` (streams the file).
- `schema.py` is the single source of truth for valid `type` values (`decision`, `commitment`), commitment states (`open`, `in-flight`, `done`, `dropped`), and the high-stakes filter function `is_high_stakes(verdict, is_external, attendee_history_count) -> bool`.
- Ledger file location: `~/.briefings/decisions.jsonl`. Created with `umask 077` so file inherits mode 600. Directory created with mode 700.

**Patterns to follow:**
- `umask 077` set early, matching `scripts/scheduler.sh` line 13.
- Single-source-of-truth constants like the verdict word set live in `schema.py` so changes propagate consistently.

**Test scenarios** (smoke, manual):
- Happy path: append a decision entry; read JSONL back; entry matches what was written including all required fields.
- Happy path: append a commitment with state `open`; verify state is preserved.
- Edge case: appending an entry missing `summary` raises a validation error from `schema.py`; no JSONL line is written.
- Edge case: file is created with mode 600; directory `~/.briefings/` is created with mode 700.
- Integration: `is_high_stakes(verdict='DECIDE-TODAY', is_external=False, attendee_history_count=0)` returns `True`. `is_high_stakes(verdict='LOW-STAKES', is_external=False, attendee_history_count=2)` returns `False`. `is_high_stakes(verdict='LOW-STAKES', is_external=False, attendee_history_count=7)` returns `True`. Covers R12.

**Verification:** Module is importable from outside the package (`python -c "from briefings_mcp.ledger import append, iter_entries"`). A throwaway script can append and read entries against a temporary directory without errors.

---

- U2. **`commands/follow-up.md` writes to ledger; composes why-prompted email; creates awaiting-why state**

**Goal:** Modify the follow-up slash command to classify each extracted item, append to the ledger via U1's module, attach why-prompts in the email body for high-stakes entries, and create the awaiting-why state file mirroring the existing awaiting-transcript pattern.

**Requirements:** R1–R4 (write side), R11, R12, R13.

**Dependencies:** U1.

**Files:**
- Modify: `commands/follow-up.md` (Step 3 extracts decisions/commitments → call `briefings_mcp.ledger.append` for each; Step 5 email composition → add why-prompts for high-stakes entries only; new substep creates `~/Briefings/<slug>-awaiting-why.md`)

**Approach:**
- After the existing Step 3 extracts items, the command classifies each as `decision` or `commitment`, computes `is_high_stakes`, appends to ledger.
- Email body (plain-text portion of the multipart) renders why-prompts as numbered lines: `1: Why? <summary excerpt>`. The instruction line at the end of the email body says: *"Why? Reply to this thread with one line per entry: `N: <reason>`. Skip any you don't want to capture."*
- Awaiting-why state file: `~/Briefings/<slug>-awaiting-why.md` with frontmatter `thread_id:`, `meeting:`, `slug:`, `pending_entry_ids:` (array of ledger entry UUIDs), `created_at:`. Format mirrors `*-awaiting-*.md`.
- Verdict (from briefing.md) is read from the briefing file at follow-up time if it exists; otherwise the follow-up classifies the meeting independently to derive the verdict.

**Patterns to follow:**
- `commands/follow-up.md` Step 0 awaiting-transcript file structure (`thread_id`, `meeting`, `slug`, `requested_at`).
- `gws gmail +send` returning `threadId` from the existing send pattern.
- The existing `umask 077` already at the top of `commands/follow-up.md`.

**Test scenarios** (smoke, manual):
- **Happy path / Covers AE4.** Run `/follow-up` on a recent meeting with 3 extracted items where item 2 has a high-stakes verdict and item 3 is from a meeting with 7+ prior ledger entries; verify the email body contains why-prompts for entries 2 and 3 only, not entry 1.
- Happy path: after the follow-up runs, `~/.briefings/decisions.jsonl` contains one line per extracted item with all required fields including `source_meeting`.
- Edge case: when no items are extracted from the transcript, no awaiting-why file is created; existing follow-up email behavior unchanged.
- Error path: if `briefings_mcp.ledger.append` raises (e.g. write permission failure), the follow-up logs the error and continues — the email is still sent without why-prompts on the failed entries. Better to deliver a degraded follow-up than to skip it entirely.
- Integration: the awaiting-why file is created in `~/Briefings/` with mode 600 and contains the correct `thread_id` from the send response.

**Verification:** After running `/follow-up all` on a fixture meeting, the ledger file has appended entries; the email body shows the expected why-prompt format for high-stakes entries only; the awaiting-why state file exists with correct content.

---

- U3. **Scheduler-side why-reply capture**

**Goal:** Extend the existing scheduler Step-0 polling to detect replies on awaiting-why threads, parse the numbered prefixes, update the corresponding ledger entries, and clear the pending state.

**Requirements:** R14.

**Dependencies:** U1, U2.

**Files:**
- Modify: `commands/follow-up.md` Step 0 (or factor out to `scripts/why_capture.py` if Step 0 grows too long — decide during implementation based on readability)
- Optionally create: `scripts/why_capture.py` if extraction proves cleaner as a helper

**Approach:**
- The existing Step 0 in `commands/follow-up.md` already polls `*-awaiting-*.md` files. Extend the file glob pattern or add a sibling branch for `*-awaiting-why-*.md`.
- For each awaiting-why file: read it, look up the Gmail thread via `gws gmail users threads get`, find new messages beyond the original.
- Parse the reply body: split on newlines, drop lines starting with `>` (quoted text), match each remaining line against `^\s*(\d+):\s+(.+)$`.
- For each match, look up the pending entry ID by index, update its `why` field via a ledger helper, clear from the pending list.
- When the pending list is empty (or after 7 days, matching the existing awaiting-transcript expiry pattern), delete the awaiting-why file.
- Unmatched prose lines in the reply append to a `why_notes` field on the most-recently-prompted entry from that thread.

**Patterns to follow:**
- `commands/follow-up.md` Step 0 transcript polling logic — same shape, different state file pattern and reply parsing.
- 7-day expiry logic from the existing `requested_at` check.

**Test scenarios** (smoke, manual):
- **Happy path / Covers AE5.** Reply to a follow-up thread with `2: Q2 burn higher than forecast\n3: They need it before quarter close`; verify the ledger entries 2 and 3 have their `why` fields populated and the awaiting-why file is deleted.
- Edge case: reply contains only quoted text (`> 2: ...`); parser correctly skips the quoted line; no ledger updates; awaiting-why file remains.
- Edge case: reply contains `1: skip` for an item; the entry's `why` is set to `skip`. (User explicitly opted out; this is not magic-keyword behavior, just literal capture.)
- Edge case: reply contains free-form prose ("they were anxious about Q3") with no numbered prefix; the prose is appended to `why_notes` on the most-recently-prompted entry.
- Edge case: awaiting-why file older than 7 days with no reply — file is deleted; ledger entries retain empty `why` fields.
- Error path: reply contains `999: <reason>` (entry index out of range); the parser logs a warning, the line is ignored, other valid lines are processed.

**Verification:** Sending a test reply to a follow-up thread results in the ledger being updated correctly on the next 15-minute scheduler cycle; the awaiting-why file is removed when the pending list empties.

---

- U4. **MCP server: `briefings_mcp` package with FastMCP**

**Goal:** A local, read-only MCP server exposing the ledger to external agents (Claude Code, Claude Desktop, future MCP consumers).

**Requirements:** R15, R16.

**Dependencies:** U1.

**Files:**
- Create: `briefings_mcp/server.py` (FastMCP entry point)
- Create: `briefings_mcp/query.py` (filter resolution, result shaping)
- Create: `briefings_mcp/index.py` (SQLite index build, mtime-based cache invalidation)
- Create: `briefings_mcp/__main__.py` (so `python -m briefings_mcp` works)

**Approach:**
- `server.py` registers three FastMCP tools:
  - `search_decisions(attendee: str | None, topic: str | None, type: 'decision' | 'commitment' | None, date_from: str | None, date_to: str | None, state: 'open' | 'in-flight' | 'done' | 'dropped' | None, limit: int = 50)` → returns list of matching entries.
  - `get_decision_by_id(id: str)` → returns one entry or null.
  - `list_attendees(limit: int = 100)` → returns array of attendee emails ordered by entry-count desc.
- On first tool call (lazy load), `index.py` checks `~/.briefings/decisions.db` mtime against `~/.briefings/decisions.jsonl` mtime. If JSONL is newer or DB is missing, rebuild: open in-memory SQLite, `executemany()` INSERT all entries from JSONL, write DB to disk.
- `query.py` translates the flat MCP filter inputs into the SQLite query.
- **stdio rule:** all logging via Python `logging` to `stderr` (configured in `__main__.py`). Never `print()`. Per FastMCP docs, this is critical — stdout is JSON-RPC.
- All filter fields are flat (no nested objects). JSON Schema 2020-12 default.

**Patterns to follow:**
- FastMCP `@mcp.tool()` decorator pattern (verified in U6 by reading actual install behavior).
- The `umask 077` and mode-600 pattern for the DB cache file.

**Test scenarios** (smoke, manual):
- **Happy path / Covers AE6.** Append 5 ledger entries with topic tag "pricing" via U1's helper; query `search_decisions(topic="pricing", date_from="2026-02-19")`; verify all 5 are returned. Then query with `type="commitment"`; verify only commitment-typed entries returned.
- Happy path: `get_decision_by_id` returns a single entry by UUID; returns null for an unknown id.
- Happy path: `list_attendees` returns attendees in entry-count-desc order.
- Edge case: query against an empty ledger returns `[]`, not an error.
- Edge case: JSONL is modified between queries — second query reflects the new entries (mtime-based invalidation works).
- Edge case: SQLite cache file is corrupted/truncated — server detects this on load (catch exception, log to stderr, rebuild from JSONL).
- Integration: server starts, registers tools, accepts an MCP `list_tools` request and returns the three tools with their schemas. No `print()` calls reach stdout (would corrupt protocol).

**Verification:** `python -m briefings_mcp` starts the server on stdio. Running `claude mcp list` after registration (in U6) shows `briefings`. From Claude Code, "what did I decide about X in the last 90 days" returns ledger-grounded answers.

---

- U5. **`commands/briefing.md` SITREP restructure: verdict, trap, delta, comment, counterparty**

**Goal:** Restructure the briefing output to the SITREP shape. The briefing reads `~/.briefings/decisions.jsonl` inline (via embedded Python in the command, matching the existing scheduler.sh embedded-Python pattern), computes Delta against prior touchpoints, and renders the new sections in order.

**Requirements:** R5, R6, R7, R8, R9, R10.

**Dependencies:** U1 (ledger schema), U2 (so the ledger is being populated by the time U5 reads from it).

**Files:**
- Modify: `commands/briefing.md` (Step 4 and Step 5 — extend the assembly to render the new SITREP block above the existing "Detail" body)

**Approach:**
- The brief's first line is the meeting title prefixed with a single-word verdict from the closed set: `DECIDE-TODAY`, `DELEGATE`, `DEFER`, `DECLINE`, `PREP-HARD`, `LOW-STAKES`, `MOVE-ASYNC`. Verdict is chosen by Claude based on agenda signals + attendee history + open commitments touching this meeting. Conservative default `LOW-STAKES` if the signals are thin.
- Below the verdict, four labeled sections rendered in order: `Trap:`, `Delta:`, `Comment:`. For external/mixed meetings only, add `Counterparty:`. Internal meetings omit the Counterparty section entirely.
- `Delta:` is computed by reading `~/.briefings/decisions.jsonl` and filtering for entries with (a) attendee overlap with the current meeting AND (b) `created_at` within the last `LOOKBACK_DAYS` (default 60, read from `~/.briefings_config`). Rank matches by (topic-overlap-count desc, then created_at desc). Surface up to 2 in the Delta section. When no matches: render the literal text "No prior touchpoints with these attendees."
- `Counterparty:` when data is thin (defined as: fewer than 3 Gmail threads with this attendee AND zero prior transcripts mentioning them): render the literal label "Limited counterparty signal — first known interaction; role assumptions only" followed by role-based assumptions only. Do not invent specific detail.
- The existing attendee/document/transcript context still appears beneath the SITREP block as a "Detail" body. The SITREP block is what scans in 30 seconds; Detail is for the curious moment.
- Verdict word set lives as a constant in `briefings_mcp/schema.py` (added in U1). Briefing.md references it explicitly so the closed set is visible to Claude when composing.

**Patterns to follow:**
- `scripts/scheduler.sh` embedded-Python pattern (heredoc + `python3 <<'PYEOF'` block) for the inline ledger read.
- Existing `commands/briefing.md` `MY_EMAIL` / `COMPANY_DOMAIN` config-read pattern for the new `LOOKBACK_DAYS` read.

**Test scenarios** (smoke, manual):
- **Happy path / Covers AE1.** Run `/briefing` for an upcoming external meeting; verify the file opens with `<VERDICT> — <Meeting title>` and contains `Trap:`, `Delta:`, `Comment:`, `Counterparty:` in that order.
- **Happy path / Covers AE2.** Pre-populate the ledger with an entry "Acme pricing memo to be delivered by 2026-05-15 (state: open)" dated 2026-04-30; run `/briefing` for the next Acme meeting; verify the `Delta:` section references the prior commitment and its open state, not a from-scratch description.
- **Happy path / Covers AE3.** Run `/briefing` for a meeting with `unknown@vendor.com` and no Gmail/Drive/transcript history; verify the `Counterparty:` section begins with the literal label "Limited counterparty signal — first known interaction; role assumptions only".
- Edge case: internal-only meeting (all `@COMPANY_DOMAIN` attendees) renders without the `Counterparty:` section.
- Edge case: ledger is empty; `Delta:` renders "No prior touchpoints with these attendees."
- Edge case: ledger has 5+ matching entries; only the top 2 (by topic-overlap then recency) appear in Delta.
- Integration: the verdict word in the rendered output is always from the closed set; no free-form verdicts.

**Verification:** Generated brief files include verdict line + four (or five for external) labeled sections. Delta references real ledger entries when they exist. Counterparty section honesty label appears verbatim for thin-data cases.

---

- U6. **`install.sh` and `update.sh` plumbing; smoke-test helper**

**Goal:** Install the Python package and its dependencies, register the MCP server, initialise the ledger location and config defaults, and provide a smoke-test script that the user can run after install or update to verify the v1 surface end-to-end.

**Requirements:** R15 (registration), R16 (local-only), all v1 wiring.

**Dependencies:** U1, U2, U3, U4, U5 (all the code that install/update needs to land).

**Files:**
- Modify: `install.sh`
- Modify: `update.sh`
- Create: `scripts/verify-v1.sh` (smoke-test entry point)

**Approach:**
- `install.sh` additions:
  - New Step: detect Python 3 (already present per existing scheduler.sh dependency); install FastMCP via `pip install --user 'fastmcp>=2.11,<3'` (or `uv tool install` if `uv` is detected on the user's machine — decide based on environment scan).
  - New Step: `mkdir -p ~/.briefings && chmod 700 ~/.briefings && touch ~/.briefings/decisions.jsonl && chmod 600 ~/.briefings/decisions.jsonl`.
  - New Step: append `LOOKBACK_DAYS=60` to `~/.briefings_config` if not already present.
  - New Step: copy the `briefings_mcp/` package to the install target (editable install: `pip install --user -e $SCRIPT_DIR` so subsequent `update.sh` runs propagate code changes without re-install).
  - New Step: register MCP server: `claude mcp add briefings --scope user -- python -m briefings_mcp` (idempotent: check `claude mcp list | grep briefings` first; skip if present).
- `update.sh` additions:
  - Reuse the editable-install model: changes to `briefings_mcp/` after `git pull` are picked up automatically. No re-install needed unless `fastmcp` itself is updated.
  - Re-source the new `commands/follow-up.md` and `commands/briefing.md` (already covered by existing logic).
- `scripts/verify-v1.sh`:
  - Append 3 fixture entries to the ledger (one decision, one commitment, one with topic="test").
  - Query the MCP server in three ways via `claude mcp` debug commands; verify expected matches.
  - Generate a briefing for a fixture meeting; verify the output contains SITREP-shape sections.
  - Send a test follow-up email to `$MY_EMAIL`; instruct the user to reply with a fixture format; on next scheduler run, verify the `why` field is populated.
  - Print PASS/FAIL per step; exit 0 only if all pass.

**Patterns to follow:**
- `install.sh` idempotent Step 8 (commands install) pattern — check if installed, skip if so.
- `scheduler.sh` `notify_slack`/`log` helper shape for the verify script's output.

**Test scenarios** (smoke, manual):
- Happy path: fresh `install.sh` on a clean machine completes all new steps without error; `claude mcp list` shows `briefings`; `~/.briefings/decisions.jsonl` exists with mode 600; `~/.briefings_config` contains `LOOKBACK_DAYS=60`.
- Happy path: `update.sh` after a `git pull` that modified `briefings_mcp/server.py` results in the running MCP server picking up the change on next session start (editable install).
- Edge case: re-running `install.sh` after the v1 install is idempotent — `claude mcp add` is skipped because the server is already registered; `decisions.jsonl` is not truncated.
- Edge case: `pip install fastmcp` fails (network out); install.sh exits with a clear error message instructing the user how to retry, not a silent partial install.
- Integration: `scripts/verify-v1.sh` runs end-to-end on a fresh install and prints PASS for all checks.

**Verification:** After install on a clean machine, `verify-v1.sh` exits 0. A new briefing generated post-install lands with the SITREP shape and reads from the empty ledger correctly. The MCP server responds to a query from Claude Code.

---

## System-Wide Impact

- **Interaction graph:** the new ledger touches both `commands/follow-up.md` (write side) and `commands/briefing.md` (read side). The MCP server is a third reader. The scheduler now polls awaiting-why files in addition to awaiting-transcript files.
- **Error propagation:** ledger append failures in `/follow-up` are non-fatal (log and continue, deliver the follow-up without why-prompts on failed entries). MCP server errors surface to the calling Claude session as MCP errors. Brief generation reads JSONL directly and falls back to "No prior touchpoints" if the read fails.
- **State lifecycle risks:** the awaiting-why file pattern inherits the same 7-day expiry from the existing awaiting-transcript flow. Stale awaiting-why files are auto-deleted. SQLite cache file is regenerable from JSONL — corruption or deletion is recoverable.
- **API surface parity:** the verdict word set in `briefings_mcp/schema.py` is the single source of truth. Briefing.md, follow-up.md, and the high-stakes filter all reference it. Adding a new verdict in v2 requires touching one constant.
- **Integration coverage:** the end-to-end loop (briefing → meeting → follow-up → ledger append → next briefing's Delta) is what `scripts/verify-v1.sh` exercises. Unit-level smoke tests alone don't prove the loop.
- **Unchanged invariants:** the launchd cadence, pre-flight gate, log rotation, lockfile, and Slack webhook flow are all untouched. The existing `*-awaiting-*.md` file convention is extended, not replaced.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| FastMCP 2.x API churn or 3.x migration pressure | Pin to `>=2.11,<3` in install.sh. Plan a separate v2 upgrade if 3.x features become needed. |
| Reply parsing failure across email clients (Gmail/Outlook/iPhone) | Quoted-line strip + numbered-prefix match is robust to standard `>` quoting. Edge cases logged as warnings, not failures. Manual reply test as part of `verify-v1.sh`. |
| SQLite cold-start cost > 10s could trigger Claude Code MCP_TIMEOUT | Cache the index to disk (`~/.briefings/decisions.db`); cold start reads cached DB. Per FastMCP best practices, lazy-load on first tool call, not at import time. |
| Schema lock-in if v1 misses a field needed in v2 | All future fields are additive (new keys, never renamed). JSONL line-by-line nature tolerates schema additions without migration. |
| Topic-tag fuzziness causes query miss in `search_decisions(topic=...)` | Topic extraction during follow-up is Claude-inferred (fuzzy). MCP search uses substring match, not exact match. Revisit with normalization pass if drift becomes a query problem. |
| MCP server is the first Python dependency outside scheduler embedded snippets | Editable install via `pip install -e` means the package is one directory; `update.sh` doesn't need to re-install on most changes. Pin transitive deps via `requirements.txt` only if drift becomes a problem. |
| User has multiple Python installations and `pip install --user` lands in the wrong one | Detect `uv` first; fall back to `python3 -m pip install --user`. Document the resolution path in install.sh output so failure modes are diagnosable. |
| Existing follow-up extraction logic mis-classifies items (decisions as commitments or vice versa) | This is the existing extraction's responsibility; v1 trusts it. If classification proves brittle, the schema permits "type": "decision" with `resolved: false` to model deferred-decision-as-commitment-like state — softening the edge. |
| Why-capture has low capture rate in practice (asking too rarely OR too noisily) | Track manually: count high-stakes entries in the ledger vs entries with non-empty `why` after 60 days. If <70%, revisit the filter rule or move to Slack DM channel (already planned as v2 fallback). |

---

## Documentation / Operational Notes

- `README.md` updates: a new "What context Claude pulls" subsection covering the ledger and MCP server, plus an "After update" section pointing at `scripts/verify-v1.sh`.
- `CHANGELOG.md` (new file) entry for v1: "Adds decision ledger, SITREP brief shape, counterparty section, local MCP server."
- The plugin manifest at `.claude-plugin/plugin.json` version bumps from `0.1.0` to `0.2.0`.
- No automated rollout/monitoring — operational reality is single-user (Mark) plus collaborator (mhmcdermott). Failure detection is via the existing scheduler.log + Slack notify path.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-19-sitrep-ledger-counterparty-v1-requirements.md](../brainstorms/2026-05-19-sitrep-ledger-counterparty-v1-requirements.md)
- **Upstream ideation:** [docs/ideation/2026-05-19-next-level-ideation.md](../ideation/2026-05-19-next-level-ideation.md)
- Existing scheduler pattern: `scripts/scheduler.sh`
- Existing slash commands: `commands/briefing.md`, `commands/follow-up.md`
- External: [Claude Code MCP docs](https://code.claude.com/docs/en/mcp), [FastMCP updates](https://gofastmcp.com/updates), [Inline mcpServers bug #16143](https://github.com/anthropics/claude-code/issues/16143), [MCP stdio SIGTERM #40207](https://github.com/anthropics/claude-code/issues/40207).
