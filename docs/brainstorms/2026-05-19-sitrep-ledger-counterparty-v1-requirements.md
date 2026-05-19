---
date: 2026-05-19
topic: sitrep-ledger-counterparty-v1
---

# SITREP brief + decision ledger + counterparty section (v1)

## Summary

Add a queryable decision/commitment ledger to the briefings system, restructure the briefing output to a SITREP shape (verdict + trap + delta + comment) that reads from the ledger, and include a counterparty-perspective section for external meetings.

---

## Problem Frame

The current briefings system is solo, atomic, and ephemeral. Each briefing is built from scratch against the user's data sources, then becomes a markdown file nobody queries. Each follow-up extracts decisions and actions into a file that is never read again. By brief #40 the system feels like noise — none of the prior 39 briefings informs this one, and none of the decisions made in them is surfaced when it matters.

In parallel, the current brief output shape (comprehensive, chronological, methodology-visible) is the *report* shape that intelligence agencies abandoned decades ago. Executives scan; they don't read. The headline at 9:55am should be a verdict, not a five-section essay.

The cost shape is invisible. The system works, briefs land, follow-ups extract — but the compounding effect that distinguishes "tool" from "infrastructure" never fires.

---

## Actors

- A1. **User (exec).** Receives briefings + follow-ups, makes decisions/commitments through meetings, replies to email prompts with the *why* behind decisions.
- A2. **Scheduler.** The launchd-driven `scripts/scheduler.sh`. Pre-flight gates, invokes Claude Code for briefing/follow-up generation, drives the email-reply detection loop.
- A3. **`/briefing` slash command.** Generates the new SITREP-shape brief. Reads from the ledger. Writes nothing to the ledger.
- A4. **`/follow-up` slash command.** Extracts decisions + commitments from transcripts. Appends to the ledger. Composes the follow-up email with *why* prompts attached to high-stakes entries.
- A5. **MCP consumer.** External AI tool (Claude Code, Claude Desktop, future agents) querying the ledger. Read-only access.
- A6. **Counterparty.** The other party in an external meeting. Modeled in the brief but not yet a direct recipient.

---

## Key Flows

- F1. **Brief generation against the ledger**
  - **Trigger:** scheduler detects a qualifying meeting starting within the next 2 hours.
  - **Actors:** A2, A3.
  - **Steps:**
    1. Scheduler invokes `/briefing all`.
    2. `/briefing` builds attendee + topic list from the calendar event.
    3. `/briefing` queries the ledger for prior decisions + open commitments touching these attendees/topics.
    4. Claude composes SITREP-shape output (verdict + trap + delta + comment + counterparty section if external/mixed).
    5. `/briefing` writes the briefing file, sets mode 600, delivers to inbox + Slack.
  - **Outcome:** Briefing reflects cross-meeting context, not just the current meeting in isolation.
  - **Covered by:** R1, R2, R5, R6, R7, R8, R9.

- F2. **Decision + commitment extraction and ledger append**
  - **Trigger:** transcript found for a recently-ended meeting (or transcript reply lands via the existing awaiting-* path).
  - **Actors:** A2, A4.
  - **Steps:**
    1. `/follow-up` extracts decisions + commitments from the transcript using existing logic.
    2. For each entry, classify type (`decision` or `commitment`) and significance (high-stakes or routine).
    3. Append each entry to `~/.briefings/decisions.jsonl` as a structured record.
    4. Write the follow-up markdown file as today.
    5. Compose the follow-up email with a *why* reply prompt appended only to high-stakes entries.
    6. Send the email; store the thread ID for reply detection.
  - **Outcome:** Ledger grows with each follow-up; high-stakes entries have a pending *why* request.
  - **Covered by:** R1, R2, R3, R4, R10, R11, R12.

- F3. **Why-capture via email reply**
  - **Trigger:** scheduler poll detects a user reply on a follow-up thread that has pending *why* requests.
  - **Actors:** A2, A1.
  - **Steps:**
    1. Scheduler reads the reply body, parses numbered-prefix responses (`N: <reason>`).
    2. For each prefix that maps to a pending entry, update the ledger entry's `why` field and clear the pending state.
    3. Append unmatched prose to a freeform `why_notes` field on the relevant entries.
  - **Outcome:** Ledger entries get their `why` field populated, typically within hours of the meeting.
  - **Covered by:** R13, R14.

- F4. **MCP query against the ledger**
  - **Trigger:** an external AI tool calls the MCP server (e.g. "what did Mark commit to about pricing in the last 90 days?").
  - **Actors:** A5.
  - **Steps:**
    1. MCP server receives a structured query (filter by attendee, topic, type, date range, state).
    2. Reads `~/.briefings/decisions.jsonl`.
    3. Returns matching entries with all fields including `why`.
  - **Outcome:** Other AI tools can read the ledger without going through the briefing/follow-up flow.
  - **Covered by:** R15, R16.

---

## Requirements

**The ledger**
- R1. The system maintains a single append-only JSONL file at `~/.briefings/decisions.jsonl`, mode 600.
- R2. Each entry has: `id` (uuid), `created_at` (ISO timestamp), `type` (`decision` or `commitment`), `summary` (≤140 chars), `attendees` (array of email addresses), `topics` (array of free-text tags), `source_meeting` (filename of the follow-up that produced it), `why` (string, may be empty), `why_notes` (string, may be empty).
- R3. Commitment entries additionally have: `owner` (email), `due` (ISO date, may be empty), `state` (`open` / `in-flight` / `done` / `dropped`, default `open`).
- R4. Decision entries additionally have: `resolved` (boolean — `true` unless the decision was explicitly deferred at the meeting). Deferred decisions appear in the ledger as `resolved: false` to signal "still open."

**The SITREP brief output shape**
- R5. The brief's first line is the meeting title prefixed with a single-word verdict in caps from the closed set: `DECIDE-TODAY`, `DELEGATE`, `DEFER`, `DECLINE`, `PREP-HARD`, `LOW-STAKES`, `MOVE-ASYNC`.
- R6. Below the verdict line, the brief contains four labeled sections in order: `Trap:` (one risk most likely to derail the meeting), `Delta:` (what has changed since the last touchpoint with overlapping attendees/topics), `Comment:` (system interpretation, explicitly separated from reporting).
- R7. For external and mixed meetings only, a fifth section `Counterparty:` is rendered. For internal meetings it is omitted entirely.
- R8. The existing attendee/document/transcript context still appears in the brief beneath the SITREP sections, as a collapsible "Detail" body. The SITREP block is what scans in 30 seconds; Detail is for the curious moment.
- R9. The `Delta:` section is computed against the ledger. When the ledger has no relevant entries (e.g. first meeting with these attendees), Delta renders the literal text "No prior touchpoints with these attendees."

**Counterparty section behavior**
- R10. When counterparty data is thin (fewer than 3 Gmail threads AND zero prior transcripts with this attendee), the section is rendered with the literal label "Limited counterparty signal — first known interaction; role assumptions only" followed by role-based assumptions only. Do not silently skip; do not fabricate detail.

**Why-capture**
- R11. After each follow-up, the follow-up email is composed with a *why* prompt only for entries classified as high-stakes.
- R12. An entry is high-stakes when ANY of: the meeting's verdict is in {`DECIDE-TODAY`, `DECLINE`, `PREP-HARD`}, the meeting is external/mixed, OR the meeting has an attendee with 5+ prior ledger entries.
- R13. Each why-prompted entry in the email is rendered with a numbered prefix in plaintext (so it survives rich-text replies), and the email body ends with the instruction: *"Why? Reply to this thread with one line per entry: `N: <reason>`. Skip any you don't want to capture."*
- R14. When the user replies to the follow-up thread, the scheduler matches `N:` prefixes back to pending entry IDs, populates the `why` field, and clears the pending state. Unmatched prose is appended to `why_notes` on the most-recently-prompted entry from that follow-up.

**MCP server**
- R15. The system exposes a local MCP server (read-only) over the ledger. It supports query by attendee, topic, type, date range, and state. Returns matching entries as structured JSON including all fields.
- R16. The MCP server is local-only (no network exposure). It is registered in the user's MCP config by `install.sh` and removed by an `uninstall.sh` path (not yet implemented; flagged for ce-plan).

**Delivery and infrastructure**
- R17. Existing email and Slack delivery channels are unchanged. The new SITREP shape applies to both. The launchd cadence, pre-flight gate, log rotation, and lockfile mechanics are unchanged.

---

## Acceptance Examples

- AE1. **Covers R5, R6, R7.** Given a 10am Acme renewal meeting with two external attendees, when `/briefing` runs, the resulting `~/Briefings/2026-05-19-1000-acme-renewal.md` opens with a verdict line (e.g. `DECIDE-TODAY — Acme renewal`) and contains `Trap:`, `Delta:`, `Comment:`, and `Counterparty:` sections in that order.

- AE2. **Covers R9.** Given a ledger entry "Acme pricing memo to be delivered by 2026-05-15 (state: open)" from a follow-up dated 2026-04-30, when `/briefing` runs for the 10am Acme meeting, the `Delta:` section references "Pricing memo committed Apr 30, still open as of today" rather than describing the meeting from scratch.

- AE3. **Covers R10.** Given an 11am meeting with `unknown@vendor.com` and no prior Gmail, Drive, or transcript signal, when `/briefing` runs, the `Counterparty:` section opens with the literal text "Limited counterparty signal — first known interaction; role assumptions only" and contains only role-based assumptions, not invented detail.

- AE4. **Covers R11, R12.** Given a follow-up has extracted three entries — entry 1 (commitment from a routine 1:1 with low-stakes verdict), entry 2 (decision from a `DECIDE-TODAY`-verdict meeting), entry 3 (commitment from a meeting with an external attendee with 7 prior ledger entries) — when the follow-up email is sent, entries 2 and 3 each carry a `N: <reason>` why-prompt and entry 1 does not.

- AE5. **Covers R14.** Given the follow-up email contained why-prompts for entries 2 and 3, when the user replies "2: Q2 burn higher than forecast\n3: They need it before quarter close", then ledger entry 2's `why` is set to "Q2 burn higher than forecast" and entry 3's `why` to "They need it before quarter close". The pending state on both is cleared.

- AE6. **Covers R15.** Given the user asks Claude Code "what did I commit to about pricing in the last 90 days", when Claude queries the MCP server, it returns all `type: commitment` ledger entries with at least one topic tag matching "pricing" and `created_at` within the last 90 days, including the `state` and `why` fields.

---

## Success Criteria

- The user can ask Claude Code "what did I decide about X" or "what did I commit to with Y" and get a grounded answer in under 10 seconds, sourced entirely from entries the system captured itself.
- After 60 days of normal use, at least 70% of high-stakes ledger entries have their `why` field populated.
- Briefing #40 surfaces at least one prior commitment or decision that would not have been surfaced by briefing #1 (i.e. the compounding effect is observably present).
- `ce-plan` can produce an implementation plan from this doc without inventing product behavior. Schema, verdict word set, high-stakes filter, and email-reply parsing semantics are all named here.

---

## Scope Boundaries

- Local mic transcript capture (privacy/consent work needed; future opt-in)
- Audio briefings / voice-out delivery
- Voice-memo *why*-capture (Mac hotkey + Whisper)
- Slack-incoming bot for *why*-capture (deferred to v2 if email-reply capture rate is too low)
- Counterparty-facing briefings sent to the other party (v2)
- Team-visible briefings + shared corpus (separate larger initiative — survivor #7 in the parent ideation doc)
- `Strategy.md` / OKR doc read-through surfaces (separate; depends on ledger maturity — survivor #6)
- Ad-hoc context on demand (`/brief @thread`) (separate initiative — survivor #4)
- Decline-or-async meeting recommendation (separate initiative — survivor #2)
- Pluggable sources framework (premature for a 4-source product)
- Backfilling old follow-up markdown files into the ledger (ledger starts empty and populates forward)
- Schema versioning / migration strategy (defers to `ce-plan`)
- Specific MCP server library / runtime choice (defers to `ce-plan`)
- A web UI or dashboard over the ledger

---

## Key Decisions

- **All three pieces ship as one v1 package, not sequentially.** The SITREP brief's `Delta:` and `Counterparty:` sections need the ledger to populate; a brief-only v1 would feel hollow. The user accepted the longer build window over a faster but hollow ship.
- **Verdict frame: action-recommendation, not prep-intensity, stance, or meeting-type.** The verdict's job is to change what the user does in the next 5 minutes; action-recommendation is the most operational of the four candidates considered.
- **Why-capture via email reply, filtered to high-stakes only.** Reuses the existing awaiting-* email-reply mechanism in `follow-up.md`; no new Slack-incoming infrastructure. Filtering to high-stakes prevents *why*-fatigue (asking too often is the dominant capture-failure mode).
- **Ledger captures decisions + commitments — not positions.** Positions add curation burden without enough value at v1 scale. The state machine on commitments (`open`/`in-flight`/`done`/`dropped`) plus deferred-decision state (`resolved: false`) covers the open-thread cases that "positions" would address.
- **MCP server is read-only in v1.** Writes flow exclusively through `/follow-up` to keep one ingest path and avoid concurrency. External writes can be revisited if a real use case appears.
- **Counterparty section on thin data: render with explicit honesty label.** Silently skipping fails the user (they don't know what's missing); fabricating fails the principle that the brief earns trust by being honest about its limits.

---

## Dependencies / Assumptions

- The existing `follow-up.md` transcript-extraction logic (Steps 3-4) correctly identifies decisions and commitments. v1 reuses this; no new extraction logic in scope.
- Email-reply detection reuses the existing `*-awaiting-*.md` mechanism (`threadId` + scheduler poll). This is assumed reliable based on its current usage for transcript replies.
- `gws gmail +send` returns a `threadId` per send, which the scheduler can later poll via `gws gmail users threads get` (per the `gws gmail` memory).
- The user's MCP config file lives at a path `install.sh` can edit safely (existing pattern from Cédric/Notion setup).
- The JSONL ledger remains under the size where in-memory load+filter from bash/Python is acceptable. Projected: under ~50K entries within the horizon this brainstorm covers.

---

## Outstanding Questions

### Resolve Before Planning

(none — all product-shape decisions resolved during the brainstorm)

### Deferred to Planning

- [Affects R9][Technical] Lookback window for "prior decisions/commitments touching these attendees/topics" — 30, 60, or 90 days? Calibrate against representative meeting cadence during planning.
- [Affects R9][Technical] When multiple ledger entries could be "the prior touchpoint" for a meeting, which one anchors `Delta:` — most recent, most topic-relevant, or both?
- [Affects R15][Technical] MCP server runtime: bash, Python, TypeScript, or another? Existing scheduler uses Python for the pre-flight gate, which suggests Python is the path of least resistance, but worth checking against current Claude Code MCP server conventions.
- [Affects R15][Needs research] Index strategy for the JSONL ledger — straight grep at small scale, sqlite-over-jsonl in the middle, or upgrade to sqlite as the primary store? Acceptable to defer the decision; needs an explicit threshold rule.
- [Affects R13][Technical] Email body composition — how the *why*-prompts are rendered across the HTML and plaintext multipart bodies such that the numbered-prefix parsing in F3 stays reliable when the user replies from Gmail, Apple Mail, Outlook, or a phone.
- [Affects R12][Technical] Should the high-stakes filter rule be hard-coded in `follow-up.md` (simple, opinionated) or made configurable via `~/.briefings_config`? Lean simple/hard-coded for v1; revisit if other installers ask.
