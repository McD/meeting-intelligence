---
title: "feat: Actions tracker digest (Phase 3)"
type: feat
status: active
date: 2026-05-27
---

# feat: Actions tracker digest (Phase 3)

## Summary

A new `/digest` slash command fired by the scheduler twice a week (Mon and Thu at 10am local) that reads open commitments from the ledger and emails an actions tracker with three numbered sections: Yours, Owed to you, Nudge drafts. The email invites reply keywords (`done:`, `more:`, `drop:`, `send:`, `cancel`, `extend`) handled by an awaiting-digest branch added to `/follow-up` Step 0's existing dispatch. A small ledger primitive — `update_commitment_state` — is reintroduced for state writes (Phase 2 removed the only previous rewriter, `update_why`). Smart pre-marking searches recent Gmail sent items for likely-done commitments and surfaces them with a `done?` confidence mark.

---

## Problem Frame

The ledger has been accumulating decisions and commitments since v1 shipped, but there's no read surface that surfaces just "what's open right now and what should you do about it." Phase 1 added meeting-level texture; Phase 2 made follow-ups interactive. Phase 3 closes the loop: a regular pulse on outstanding work, with one-tap reply keywords to update state without context-switching out of email. The cadence (Mon at the start of the week, Thu mid-week) matches the user's actual rhythm.

---

## Requirements

- R1. A new `/digest` slash command that, when invoked, produces an actions tracker email + Slack heads-up from the ledger's open commitments.
- R2. The scheduler at `scripts/scheduler.sh` fires `/digest` automatically on Mondays and Thursdays between 10:00 and 10:14 local time, exactly once per day (idempotent against the 15-minute cycle).
- R3. The digest email has three sections, each independently numbered:
  - **Yours** — open commitments where owner is the user (`MY_EMAIL` from `~/.briefings_config`, or aliases like "You", "Mark")
  - **Owed to you** — open commitments from meetings whose attendees include the user, where owner is someone else
  - **Nudge drafts** — pre-written 2–3 sentence reminder emails for overdue items from "Owed to you" (older than 14 days OR past their `due` date)
- R4. Each Yours/Owed item shows meeting name, age in days, due date if set. Each Nudge draft shows recipient + draft text.
- R5. The digest email footer invites reply keywords:
  - `done: 1, 3` — mark Yours #1 and #3 as `state: "done"`
  - `more: 2` — Yours #2 stays open, log "snoozed" (no state change)
  - `drop: 4` — Yours #4 → `state: "dropped"`
  - `send: 2` — fire Nudge draft #2 (send to the owner via Gmail)
  - `cancel` — delete the awaiting-digest file
  - `extend` — reset the 30-day expiry on the awaiting-digest file
- R6. A new `briefings_mcp.ledger.update_commitment_state(entry_id, new_state)` primitive lets the reply handler mutate `state` in place. Append-only is broken intentionally for this one field (same atomic-rewrite shape as the removed `update_why`).
- R7. Smart pre-marking (best-effort): for each Yours commitment, search Gmail sent items between the commitment's `created_at` and now for messages whose subject or body matches keywords from the commitment summary. If a likely match exists, render the item as `1. done? — <summary>` (italic `done?`). When Claude is unsure, no mark is added.
- R8. The "no open commitments" case is handled gracefully: no email, a one-line Slack notice ("Actions tracker: nothing open — clean slate for the week ahead.") if a webhook is configured.
- R9. The awaiting-digest state file follows the established pattern. Fields: `thread_id`, `created_at`, `mine` (UUIDs in display order), `owed` (UUIDs in display order), `nudges` (array of `{to, subject, body}` records for `send: N`).
- R10. `verify-v1.sh` gains a `--with-digest` flag that force-generates a fresh digest and asserts shape (mandatory headings, conditional sections, reply-keyword footer).
- R11. README updated with a new "Actions tracker" section covering cadence, reply keywords, and how to disable.

---

## Scope Boundaries

- Phase 3 does **not** add a separate launchd job. The existing 15-minute cycle is the only timer; scheduler.sh adds a day-of-week + time-of-day check.
- No Slack pre-marking. Smart pre-marking is Gmail-only (sent items) because the existing Slack integration is outbound-webhook-only and reading Slack would require a separate bot token. Deferred.
- No batch/bulk operations on the ledger beyond the new `update_commitment_state` primitive. No bulk done/drop/state-history queries.
- No web UI, no new MCP tools. The digest is email + Slack only.
- No changes to the briefing (`/briefing`) or follow-up (`/follow-up`) commands' core behaviour. /follow-up grows one new branch in Step 0 (awaiting-digest dispatch); everything else stays.
- The "Yours" filter is text-based ("You", "Mark", "Mark McDermott", `MY_EMAIL`). No formal identity resolution — if a commitment's owner is "M McDermott" with a different spelling, it may not match. Pragmatic, not exhaustive.

### Deferred to Follow-Up Work

- **Phase 4:** Pattern flags from ledger history (e.g. "you've raised pricing in 3 meetings this month"). Separate PR.
- **Slack pre-marking:** Requires a Slack bot token + workspace API access. Out of scope; revisit if user adds Slack auth.
- **Per-attendee digest:** A future enhancement could send each external attendee their own "what you owe Mark" digest. Out of scope for v1.
- **Configurable cadence:** Hard-coded to Mon/Thu 10am for now. If the user wants other days/times, surface a `DIGEST_CADENCE` env var in `~/.briefings_config` (deferred).

---

## Context & Research

### Relevant Code and Patterns

- `scripts/scheduler.sh` — every-15-minute cycle with a pre-flight gate (lines ~57–181). The gate sets `NEED_BRIEFING` / `NEED_FOLLOWUP` and exits early if both are 0. Phase 3 adds `NEED_DIGEST`.
- `commands/follow-up.md` Step 0 — three-branch dispatch (retirement / awaiting-reply / transcript-request) added in Phase 2. Phase 3 adds an awaiting-digest branch as the fourth.
- `commands/follow-up.md` Step 2 — five-source transcript search establishes the "use `gws` for Gmail and Drive" pattern. Phase 3's smart pre-marking reuses the Gmail search pattern.
- `commands/follow-up.md` Step 6 awaiting-reply state file creation block — established the awaiting-reply pattern Phase 3's awaiting-digest file mirrors.
- `briefings_mcp/ledger.py` — append() is the only mutator post-Phase 2; the module docstring says "truly append-only" — update Phase 3's docstring to acknowledge state writes.
- `briefings_mcp/query.py` — `search_decisions(attendee, topic, type, date_from, date_to, state, limit)` exists; Phase 3 likely filters results in Python after fetching with `state="open"` (volume is low).
- `briefings_mcp/schema.py` — `COMMITMENT_STATES` already includes `done`, `dropped` (and `open`, `in-flight`). No schema changes needed.
- `scripts/verify-v1.sh` sections 7 (--with-briefing) and 8 (--with-followup) — the gating + force-regen + shape-assertion pattern. Phase 3 adds section 9 (--with-digest) mirroring this.
- `commands/briefing.md` — for the prompt style and structure of a similar Claude-generated artifact.
- The user's `~/.briefings_config` exposes `MY_EMAIL`, `COMPANY_DOMAIN`, `LOOKBACK_DAYS`. Phase 3 reuses `MY_EMAIL` for the "Yours" filter.
- The existing `~/Briefings/*-awaiting-*.md` glob in scheduler.sh line 174 and follow-up.md Step 0 line ~35 catches awaiting-digest files automatically. No glob changes needed.

### Institutional Learnings

- Phase 2's hard-line "truly append-only" framing for the ledger is being deliberately walked back in Phase 3. Document the choice clearly in the ledger.py docstring so future readers don't undo the work.
- The `*-awaiting-*` glob pattern is reusable. Every new state-file shape Phase 1+ has added follows it (transcript, reply, digest). Future phases should continue the pattern.
- Scheduler combines work into one Claude call (`run_claude "briefing+follow-up" ...`) when multiple tasks are pending. Phase 3 may want to add a triple-combined call (`briefing+follow-up+digest`) when all three fire, but practically the digest only fires Mon/Thu 10am, which rarely coincides with a meeting briefing window. Two-way combinations are sufficient.

### External References

None required. All work is internal to existing patterns.

---

## Key Technical Decisions

- **Separate `/digest` slash command rather than extending `/follow-up`.** Different cadence (twice-weekly vs per-meeting), different domain (ledger-wide vs single-meeting), different output shape. Mixing them would bloat /follow-up.
- **Reply-keyword dispatch lives in `/follow-up` Step 0**, not in `/digest`. The /follow-up command runs every 15 minutes via the scheduler's awaiting-file polling; /digest only runs Mon/Thu 10am. Putting the awaiting-digest branch in /follow-up means replies are picked up within 15 minutes, not 3.5 days later.
- **Reintroduce `update_commitment_state` as an atomic-rewrite primitive.** Phase 2 removed `update_why` claiming the ledger is "truly append-only." Phase 3 walks that back deliberately — the ledger has one mutable field (commitment `state`) and the simplest implementation is the same atomic-rewrite pattern Phase 2 deleted. Supersede-event-based alternatives push complexity into every reader for negligible gain at single-writer scale. Update the ledger.py module docstring to reflect the new reality.
- **Per-section numbering with keyword-distinct semantics.** `done: 1` means "Yours #1", `send: 2` means "Nudge drafts #2". No unified numbering — keeps the email readable and the keyword maps unambiguous.
- **Smart pre-marking is Gmail-only and best-effort.** Claude scans the Gmail search results for substring/semantic matches. If unsure, no mark. Failure modes (Gmail search timeout, gws unavailable) degrade gracefully to no marks at all rather than failing the digest.
- **Idempotency by filename, not by lockfile.** The digest output file is `~/Briefings/YYYY-MM-DD-1000-digest.md`. If it exists already, the scheduler's "digest already done today" check skips. Same pattern as briefings and follow-ups.
- **30-day expiry on awaiting-digest state files.** Mirrors awaiting-reply. After 30 days, the file is deleted by Step 0's expiry check.
- **"You" string-matching for ownership.** `MY_EMAIL` from `~/.briefings_config` is the anchor; case-insensitive substring matches against "You", "Mark", "Mark McDermott", and the email itself catch the common cases. Pragmatic — formal identity resolution is overkill for a personal tool.

---

## Open Questions

### Resolved During Planning

- *Should the digest also include `state: "in-flight"` commitments?* Yes, treat them as Yours/open. The `in-flight` state was added in v1 for commitments mid-execution; pragmatically the user wants to see them in the digest.
- *Where does smart pre-marking get its date floor?* The commitment's `created_at`. Search Gmail sent items between created_at and now (or last 90 days if older, to bound the query).
- *What's the keyword for "needs more time"?* `more:`. Logging only (no state change) — the item simply appears again in the next digest. Could later get a `snooze_until` ledger field if needed.
- *Do nudge drafts use the user's voice or a generic template?* Generic for v1: "Hi <name>, following up on <commitment summary> from <meeting> on <date>. Where does this stand?" The user can `send: N` to fire as-is or reply with their own text. Cheap and useful.
- *How does `send: 2` know the recipient?* From the original commitment's `attendees` list intersected with `owner`. If `owner: "Alice"`, scan the meeting's attendees for someone whose name contains "Alice" and pick the first match. If no match, log warning and respond "couldn't determine recipient for nudge #2; please send manually."

### Deferred to Implementation

- The exact wording of the digest email body — draft included in High-Level Technical Design but tune during U2 against real ledger data.
- Whether the Slack heads-up should include the same numbered items or just a count ("4 yours / 2 owed"). Lean toward the latter (Slack channel space is precious), confirm at implementation time.
- Whether to truncate very long commitment summaries in the digest — likely cap at 80 chars with `…` per Phase 1 convention.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### Scheduler flow with Phase 3

```
Every 15 minutes:
  ...existing pre-flight (briefing / followup checks)...

  NEED_DIGEST=0
  if today is Mon or Thu AND time is 10:00–10:14:
    if ~/Briefings/YYYY-MM-DD-1000-digest.md does NOT exist:
      NEED_DIGEST=1

  if NEED_BRIEFING and NEED_FOLLOWUP and NEED_DIGEST:
    claude /briefing all; /follow-up all; /digest
  elif NEED_DIGEST:
    claude /digest
  ...else existing branches...
```

### Digest email shape

```markdown
# Actions tracker
**Mon, 27 May 2026 | 10:00 BST**

## Yours
1. *(open 12 days)* Send pricing memo to Acme — DSS Debrief, 15 May
2. done? *(open 5 days)* Draft 5-page state-of-industry document — SC External Positioning, 20 May
3. *(open 2 days, due 30 May)* Schedule Q3 planning offsite — Exec Sync, 25 May

## Owed to you
1. *(open 18 days)* Robert — Final messaging arc proposal — SC External Positioning, 9 May
2. *(open 7 days)* Elizabeth — Updated "about me" doc — DSS Debrief, 20 May

## Nudge drafts
1. **To: robert@example.com** — Re: SC External Positioning - DSS Debrief

   Hi Robert, following up on your messaging arc proposal from our 9 May SC External Positioning session. Where does this stand?

---

Reply to update:
- `done: 1, 3` — mark Yours items complete
- `more: 2` — keep open, snooze to next digest
- `drop: 4` — abandon a Yours item
- `send: 1` — fire Nudge draft #1
- `cancel` — drop this digest thread
- `extend` — reset the 30-day reply window
```

### Awaiting-digest state file

```
thread_id: <gmail-thread-id-of-the-digest-email>
created_at: 2026-05-27T09:00:00Z
mine: ["uuid-of-yours-1", "uuid-of-yours-2", "uuid-of-yours-3"]
owed: ["uuid-of-owed-1", "uuid-of-owed-2"]
nudges:
  - {"to": "robert@example.com", "subject": "Re: ...", "body": "Hi Robert..."}
```

(Stored as YAML-shaped frontmatter for readability; parsed line-by-line by the awaiting-digest branch the same way other awaiting files are parsed.)

---

## Implementation Units

- U1. **Reintroduce `update_commitment_state` primitive in ledger.py**

**Goal:** Add a single-purpose atomic-rewrite function that updates one commitment entry's `state` field in `~/.briefings/decisions.jsonl`. Validates that the entry is a commitment and the new state is in `COMMITMENT_STATES`. Module docstring updated to reflect that the ledger is no longer "truly append-only" — Phase 3 walked it back deliberately.

**Requirements:** R6

**Dependencies:** None

**Files:**
- Modify: `briefings_mcp/ledger.py`
- Test: `scripts/smoke_test_u3p3.py` (new) — Phase 3 numbering since smoke_test_u3.py was deleted in Phase 2

**Approach:**
- New function `update_commitment_state(entry_id: str, new_state: str) -> bool`:
  - Validates `new_state in schema.COMMITMENT_STATES` (raises `SchemaError` otherwise).
  - Reads the ledger line-by-line, finds the matching `id`, validates `type == "commitment"`, rewrites the `state` field, writes back via tmp file + os.replace (same pattern as the deleted `update_why`).
  - Returns True on match, False on no-match. Raises `FileNotFoundError` if the ledger file doesn't exist.
- Update module docstring: drop the "truly append-only" sentence; add "Mutates commitment state in place via `update_commitment_state` (Phase 3); other fields remain append-only."
- Keep the `_restricted_umask` and `_ensure_paths` helpers untouched.

**Patterns to follow:**
- The deleted `update_why` (visible in Phase 2's commit `43f2610^` diff) — same tmp-file + os.replace shape, different field.

**Test scenarios:**
- Happy path: append a commitment with `state: "open"`, call `update_commitment_state(id, "done")`, read it back via `iter_entries`, confirm state is "done".
- Happy path: update state to each of `open`, `in-flight`, `done`, `dropped` — all four valid.
- Edge case: non-existent entry id returns False; ledger unchanged.
- Edge case: entry exists but is a decision (not a commitment) — raises SchemaError, ledger unchanged.
- Error path: invalid new_state (e.g. "rejected") raises SchemaError, ledger unchanged.
- Error path: ledger file doesn't exist raises FileNotFoundError.
- Integration: append 100 commitments, update entry #50's state, confirm all other entries remain byte-identical to before the rewrite.

**Verification:**
- `python3 scripts/smoke_test_u3p3.py` exits 0.
- `from briefings_mcp.ledger import update_commitment_state` succeeds.

---

- U2. **New `/digest` slash command**

**Goal:** Create `commands/digest.md` — a self-contained slash command that reads the ledger, builds the three-section actions tracker email, sends it via Gmail + Slack, and creates the awaiting-digest state file. Includes Gmail-based smart pre-marking for the Yours section.

**Requirements:** R1, R3, R4, R5 (the footer text), R7, R8, R9

**Dependencies:** None (U1 is needed only for the reply handler in U4)

**Files:**
- Create: `commands/digest.md`

**Approach:**
- Modeled on the structure of `commands/follow-up.md` — numbered Steps, prose for Claude to execute, embedded heredocs for Python.
- Steps:
  - **Step 0: Pre-flight.** Read `MY_EMAIL` and `COMPANY_DOMAIN` from `~/.briefings_config`. Check if today's digest file already exists at `~/Briefings/YYYY-MM-DD-1000-digest.md`; if so, exit (idempotent).
  - **Step 1: Pull open commitments from the ledger.** Use `briefings_mcp.query.search_decisions(state="open", type="commitment")` or iter_entries + filter in Python. Split into "Yours" (owner matches MY_EMAIL or "You" or "Mark" or "Mark McDermott", case-insensitive) and "Owed to you" (everything else where attendees contains MY_EMAIL).
  - **Step 2: Smart pre-marking for Yours.** For each Yours commitment, run a Gmail search via gws: `gws gmail search --query "in:sent after:<created_at>"` plus keyword search for the commitment's key nouns. If a likely match found (Claude judges), mark the item with `done?`. On any gws error, skip pre-marking and continue (best-effort, graceful).
  - **Step 3: Build nudge drafts.** For each Owed-to-you item older than 14 days OR past its `due` date, draft a 2–3 sentence reminder email. Look up the owner's email by intersecting the commitment's `attendees` with `owner` (substring match on name).
  - **Step 4: Assemble the digest markdown.** See High-Level Technical Design for shape. Three sections + reply-keyword footer. Save to `~/Briefings/YYYY-MM-DD-1000-digest.md`, chmod 600.
  - **Step 5: Deliver.** Send via Gmail to `MY_EMAIL` (HTML, same renderer pattern as /follow-up Step 6). Capture `threadId`. Slack heads-up: `:bookmark_tabs: Actions tracker delivered — N yours / M owed.` (or "nothing open" notice if both are empty).
  - **Step 6: Create awaiting-digest state file.** Same pattern as /follow-up Step 6's awaiting-reply file: `~/Briefings/YYYY-MM-DD-1000-awaiting-digest.md` with thread_id, created_at, mine[], owed[], nudges[]. chmod 600.
- Handle the "nothing open" case: send only a one-line Slack notice (if webhook configured), do not create a digest file, do not create awaiting-digest file, return early.

**Patterns to follow:**
- `commands/follow-up.md` overall structure — Steps with embedded heredocs.
- `commands/follow-up.md` Step 6 HTML rendering pattern and Slack mrkdwn conversion.
- `commands/follow-up.md` Step 6 awaiting-reply state file shape.

**Test scenarios:**
- Happy path: ledger has 3 open Yours and 2 open Owed-to-you (1 overdue) → digest file created with 3 Yours, 2 Owed, 1 Nudge draft. Email sent. Awaiting-digest state file present with correct UUIDs.
- Happy path: empty ledger → no email, Slack "nothing open" notice, no digest file.
- Happy path: ledger has only Yours items → digest sent with no Owed-to-you section, no Nudge drafts.
- Edge case: smart pre-marking — commitment "send pricing memo to Acme" has a matching sent email in Gmail → renders as `done? — Send pricing memo to Acme`. Without a match, no `done?` mark.
- Edge case: gws Gmail search fails (timeout, auth) → digest still generated without pre-marking, Slack notice contains a tiny "smart-mark search failed" note.
- Edge case: owner string doesn't match any attendee for a nudge → that nudge entry is omitted from the drafts section, log a one-line warning.
- Edge case: idempotency — second call on the same day finds the existing `*-digest.md` file and exits without re-sending.
- Integration: end-to-end via `bash scripts/verify-v1.sh --with-digest` (U6) → digest file present, awaiting-digest state file present, no exceptions.

**Verification:**
- A single invocation of `/digest` on a non-empty ledger produces a digest file, an awaiting-digest state file, and an email landing in MY_EMAIL within 1–3 minutes.

---

- U3. **Scheduler integration: Mon/Thu 10am branch**

**Goal:** `scripts/scheduler.sh` learns to fire `/digest` when today is Mon or Thu, current local time is between 10:00 and 10:14, and today's digest file doesn't already exist. The existing briefing+follow-up logic is unchanged; the new branch combines into the same `run_claude` call when other work is also pending.

**Requirements:** R2

**Dependencies:** U2 (the command must exist for the scheduler to call)

**Files:**
- Modify: `scripts/scheduler.sh`

**Approach:**
- After the existing pre-flight gate (around line 178 where `NEED_BRIEFING` / `NEED_FOLLOWUP` get evaluated), add:
  - `NEED_DIGEST=0`
  - If `$(date +%u)` is 1 (Mon) or 4 (Thu) AND `$(date +%H:%M)` is between 10:00 and 10:14 AND `~/Briefings/$(date +%Y-%m-%d)-1000-digest.md` does NOT exist → `NEED_DIGEST=1`.
- Extend the run-claude dispatch:
  - If NEED_BRIEFING + NEED_FOLLOWUP + NEED_DIGEST → `run_claude "briefing+follow-up+digest" "Run /briefing all, then /follow-up all, then /digest"`.
  - If NEED_DIGEST + NEED_BRIEFING (no follow-up) → combine accordingly.
  - If NEED_DIGEST + NEED_FOLLOWUP (no briefing) → combine accordingly.
  - If NEED_DIGEST alone → `run_claude "digest" "Run /digest"`.
  - Existing single-task branches unchanged.
- Update the pre-flight exit condition: if all three NEED_* flags are 0, exit early.
- Bump scheduler.sh's `version:` line in the file header to today's date with a one-liner note.

**Patterns to follow:**
- The existing dispatch in scheduler.sh lines ~203–209.

**Test scenarios:**
- Happy path: it's Monday at 10:05 and no digest file exists → NEED_DIGEST=1, /digest fires.
- Happy path: it's Monday at 10:30 → NEED_DIGEST=0 (outside the window, today's digest already happened).
- Happy path: it's Tuesday at 10:00 → NEED_DIGEST=0 (wrong day).
- Edge case: it's Monday at 10:05 but `~/Briefings/2026-05-25-1000-digest.md` already exists (someone ran it manually earlier) → NEED_DIGEST=0, no re-send.
- Edge case: it's Monday at 10:05 AND a meeting briefing is also due → combined Claude call with /briefing first, then /digest.
- Edge case: it's Monday at 09:59 → NEED_DIGEST=0; at 10:00 → NEED_DIGEST=1; at 10:14 → NEED_DIGEST=1; at 10:15 → NEED_DIGEST=0 (next 15-min cycle).

**Verification:**
- Manually set system date/time to a Monday at 10:05 (or wait), confirm /digest fires within the cycle.
- Bash linter clean: `bash -n scripts/scheduler.sh` exits 0.

---

- U4. **Awaiting-digest dispatch in `/follow-up` Step 0**

**Goal:** `/follow-up` Step 0's three-branch dispatch grows a fourth branch: `*-awaiting-digest-*.md` files route to a digest-reply handler that processes the six keywords (`done:`, `more:`, `drop:`, `send:`, `cancel`, `extend`) and updates the ledger or fires nudge emails accordingly.

**Requirements:** R5 (parser/dispatcher side), R6 (uses update_commitment_state)

**Dependencies:** U1 (for update_commitment_state), U2 (state files exist to act on)

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- In the dispatch intro at the top of Step 0, add a fourth bullet: `If the basename contains -awaiting-digest- → **Awaiting-digest branch** below.`
- Insert the new branch between the existing Awaiting-reply and Transcript-request branches.
- Branch logic:
  1. Read state file (5 fields: thread_id, created_at, mine, owed, nudges).
  2. Check 30-day expiry; delete + log if expired.
  3. Fetch Gmail thread by thread_id; skip if no reply yet (only 1 message).
  4. Read last message body; take first non-empty non-quoted line; lowercase the keyword prefix.
  5. Dispatch:
     - `cancel` / `skip` / `no` / `done` (standalone) → delete state file, log, done.
     - `extend` / `wait` / `more time` → rewrite state file with new `created_at`, log, done.
     - `done: N[, M, ...]` → for each index N, look up `mine[N-1]` UUID, call `briefings_mcp.ledger.update_commitment_state(uuid, "done")`. Send a one-line email reply acknowledging the updates: "Marked done: <summaries>". Log.
     - `more: N[, ...]` → no state change; send acknowledgment "Snoozed to next digest: <summaries>"; log.
     - `drop: N[, ...]` → update state to "dropped"; send acknowledgment; log.
     - `send: N` → look up `nudges[N-1]` (to/subject/body), send via `gws gmail +send`, send acknowledgment to the digest thread "Nudge sent to <to>"; log.
     - anything else → one-line "didn't recognize" reply with the keyword list; leave state file.
  6. Leave the state file in place after any of `done:`, `more:`, `drop:`, `send:` so further replies on the same thread are still processed.
- Each acknowledgment email goes to the digest thread (`gws gmail +send --thread-id "$thread_id"`).

**Patterns to follow:**
- The existing Awaiting-reply branch added in Phase 2 — same Gmail thread polling, same first-non-quoted-line extraction, same idempotency on partial reply processing.
- The deleted awaiting-why branch's parsing of `N: <reason>` lines (visible in git history pre-Phase 2) — Phase 3 reuses the parsed-index-into-array idea but with different action semantics.

**Test scenarios:**
- Happy path done: reply `done: 1, 3` → entries at mine[0] and mine[2] go to state "done" in ledger; ack reply sent.
- Happy path more: reply `more: 2` → no ledger change, ack reply "Snoozed item 2 to next digest", state file remains.
- Happy path drop: reply `drop: 4` → mine[3] → "dropped"; ack reply.
- Happy path send: reply `send: 1` → nudges[0] is sent to its `to` field; ack reply "Nudge sent to robert@example.com".
- Happy path cancel: reply `cancel` → awaiting-digest file deleted, no ack reply.
- Edge case: reply contains multiple keywords on separate lines: `done: 1\nmore: 2` → only the FIRST keyword is processed in this cycle (consistent with existing branches' first-line dispatch). The remaining keywords on subsequent lines are ignored on this cycle but the user can re-reply.
- Edge case: out-of-range index (`done: 99` when mine only has 5 items) → log warning, ack reply "Couldn't find item 99 — only 5 in this digest."
- Edge case: case-insensitive keyword (`Done: 1`) → matches.
- Edge case: state file mid-cycle gets corrupted (manual edit, partial write) → log error, skip this cycle, do not delete.
- Edge case: gws send fails on a nudge → ack reply "Couldn't send nudge #1: <error>"; state file remains so user can `cancel` to clear.

**Verification:**
- End-to-end: reply to a real digest email with `done: 1` and wait one scheduler cycle. The ledger entry's state becomes "done"; an ack reply lands; the awaiting-digest state file remains.

---

- U5. **install.sh + update.sh propagation for `/digest`**

**Goal:** Both installers register the new `commands/digest.md` so it lands at `~/.claude/commands/digest.md` for the headless scheduler.

**Requirements:** R1 (installability)

**Dependencies:** U2 (the file exists)

**Files:**
- Modify: `install.sh`
- Modify: `update.sh`

**Approach:**
- `install.sh`: in the section that copies briefing.md and follow-up.md to `~/.claude/commands/`, add `commands/digest.md` to the copy list. Bump install.sh's `version:` header.
- `update.sh`: same change in the equivalent block. Bump update.sh's `version:` header.
- Confirm both still pass the existing "required files exist" guard (which iterates over a hardcoded list near install.sh line ~46 and update.sh line ~46).

**Patterns to follow:**
- Existing copy logic in both scripts.

**Test scenarios:**
- Happy path: `bash install.sh` against a fresh `~/.claude/commands/` → all three command files present.
- Happy path: `bash update.sh` against an existing install with no digest.md yet → digest.md now present.
- Edge case: `bash update.sh` against an existing install with an older digest.md → overwritten with current version.

**Verification:**
- After `bash update.sh`, `ls ~/.claude/commands/` lists briefing.md, follow-up.md, digest.md.

---

- U6. **`verify-v1.sh --with-digest` flag**

**Goal:** New section 9 in `scripts/verify-v1.sh` (gated by `--with-digest`) force-generates a fresh digest and asserts shape: mandatory `# Actions tracker`, `## Yours`, conditional `## Owed to you` / `## Nudge drafts`, the reply-keyword footer, and the awaiting-digest state file's existence.

**Requirements:** R10

**Dependencies:** U2, U3 (something to test)

**Files:**
- Modify: `scripts/verify-v1.sh`

**Approach:**
- Add `WITH_DIGEST=0` to the flag-parsing block. Add `--with-digest` case and `--help` description.
- New section 9 (mirroring Section 8's `--with-followup` pattern):
  - Find today's digest file; if it exists, fail-fast (manual cleanup needed before re-running, OR delete it first via `rm` — recommend documenting that in the section's `info` line).
  - Force-generate: `claude -p --dangerously-skip-permissions "/digest"`.
  - Assert: digest file exists at the expected path; awaiting-digest state file exists.
  - Shape: `# Actions tracker`, `## Yours` present. `## Owed to you` and `## Nudge drafts` are conditional — info-not-fail.
  - Reply-keyword footer: confirm the four core keywords (`done:`, `more:`, `drop:`, `cancel`) appear in the file.
- Update help output and header comment to include the new flag.

**Patterns to follow:**
- `--with-followup` block in section 8.

**Test scenarios:**
- Happy path: ledger has open commitments → `--with-digest` generates a fresh digest, all assertions pass.
- Edge case: no open commitments in ledger → digest file is NOT created; the section reports "no open commitments to digest" as `info` rather than failing.

**Verification:**
- `bash scripts/verify-v1.sh --with-digest` exits 0.

---

- U7. **README updates: Actions tracker section + reply keywords**

**Goal:** README has a new "Actions tracker" section under "What you get" / above "How meetings get classified" explaining the digest cadence, the three sections, the reply keywords, and how to disable.

**Requirements:** R11

**Dependencies:** U2–U6 (describe what shipped, not what's planned)

**Files:**
- Modify: `README.md`

**Approach:**
- Add a new section "Actions tracker" after the "Decision ledger and MCP server" section.
- Cover:
  - Cadence (Mon/Thu 10am local) and how the scheduler decides
  - Three-section structure (Yours / Owed to you / Nudge drafts)
  - Smart pre-marking (Gmail-only, best-effort)
  - Reply keywords (`done:`, `more:`, `drop:`, `send:`, `cancel`, `extend`)
  - The awaiting-digest state file lifecycle (30-day expiry)
  - How to disable: comment out the relevant scheduler.sh block or delete `commands/digest.md` from `~/.claude/commands/`
- Update the file layout block to include `~/Briefings/YYYY-MM-DD-1000-digest.md` and `~/Briefings/*-awaiting-digest-*.md`.
- Update the "What you get" bullets near the top to mention the digest.

**Patterns to follow:**
- Phase 2's README updates to "Decision ledger and MCP server" — prose-first, no em dashes per user preference.

**Test scenarios:**
- Documentation only.
- Test expectation: none — pure documentation.

**Verification:**
- A new reader can read the README and understand the digest cadence + reply keywords without needing to dig into source.

---

## System-Wide Impact

- **Interaction graph:** Phase 3 introduces one new slash command (`/digest`), one new ledger primitive (`update_commitment_state`), and one new branch in `/follow-up` Step 0. The scheduler gains a day-of-week + time-of-day check; no new launchd job. Phase 3 reuses the `*-awaiting-*.md` state-file pattern.
- **Error propagation:** `/digest` is idempotent by filename. The scheduler's combined run_claude calls already log to scheduler.log with structured error detection (auth failures, permission prompts). Smart pre-marking fails gracefully — Gmail search errors are caught and the digest still ships.
- **State lifecycle risks:**
  - The new awaiting-digest state files have 30-day expiry; cleanup is automatic.
  - The new ledger mutation (commitment state) is single-writer, atomic-rewrite (same pattern as the deleted update_why). No locking needed under the existing single-writer guarantee.
  - The digest file (`*-1000-digest.md`) is generated once per Mon/Thu; if a previous one exists from an earlier Mon, the existing 30-day cleanup in scheduler.sh line 30 handles it.
- **API surface parity:** No changes to MCP server tools. `briefings_mcp.query.search_decisions` is used by `/digest` but its signature is unchanged. The ledger's JSONL shape is unchanged (mutating an existing field, not adding new ones).
- **Integration coverage:** U6 adds a `--with-digest` shape assertion mirroring `--with-followup`. The actual reply-keyword flow is harder to automate end-to-end (requires Gmail thread polling); accepted as a known gap, same as Phase 2.
- **Unchanged invariants:**
  - Phase 1 + Phase 2 follow-up behaviour stays identical.
  - SITREP brief shape (`commands/briefing.md`) unchanged.
  - Ledger schema fields, including the historical `why` / `why_notes`, unchanged. Only commitment `state` becomes mutable.
  - Transcript-request and awaiting-reply branches in /follow-up Step 0 unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Reintroducing ledger mutation creates a conceptual regression from Phase 2's "truly append-only" framing. | Documented as a deliberate walk-back in ledger.py's module docstring and in this plan's Key Technical Decisions. The single mutable field (`state`) is the minimum needed; everything else stays append-only. |
| Smart pre-marking could generate false positives (mark something done when it isn't). | The `done?` syntax explicitly signals uncertainty — the user confirms with `done: N`. No state change happens until the user replies. Worst case: a noisy digest the user ignores. |
| Smart pre-marking is slow for users with high Gmail volume. | Bound the search to commitment age + buffer. Gmail's API is generally fast; if it times out, skip pre-marking gracefully. |
| Reply-keyword index drift if the user replies after multiple cycles. | The state file's `mine` / `owed` / `nudges` arrays are fixed at creation. Subsequent digests get fresh state files with fresh indices. The user replying to an old digest still works against that digest's indices. |
| Two scheduler cycles fire within the 10:00–10:14 window (e.g. 10:00 and 10:15 if the cron starts at :00). | The "digest file already exists for today" check guarantees idempotency. The 10:14 cutoff is just for clarity; even a 10:15 fire would skip because the 10:00 file exists. |
| The user is in a different timezone than expected when traveling. | `date +%u` and `date +%H:%M` use local time. The digest fires at 10am wherever the laptop is. Acceptable. |
| The "Yours" string-matching misses commitments where the owner is spelled unusually. | The pragmatic match list (You / Mark / Mark McDermott / MY_EMAIL) covers the common cases. If unusual spellings become a problem, add to the match list. |
| Update.sh propagation gap. | `update.sh` already handles command-file propagation; U5 adds digest.md to the list. Same risk as Phase 1/2, same mitigation. |

---

## Documentation / Operational Notes

- After merge, `bash update.sh` installs `commands/digest.md` at `~/.claude/commands/digest.md` and refreshes the runtime venv (so `update_commitment_state` is importable).
- The first digest fires the next Monday or Thursday at 10am local (whichever comes first). No manual trigger needed.
- To test the digest before waiting for the natural cadence, run `bash scripts/verify-v1.sh --with-digest` or invoke `/digest` interactively in Claude Code.
- Reply-keyword updates show up in `~/.briefings/decisions.jsonl` as updated `state` fields on existing entries. The `briefings_mcp` MCP server returns the updated state on next query.
- If the digest becomes annoying, comment out the Mon/Thu gate block in `scripts/scheduler.sh` or delete `~/.claude/commands/digest.md` — the scheduler falls through to existing briefing/follow-up logic.

---

## Sources & References

- Phase 1 plan (predecessor): `docs/plans/2026-05-27-001-feat-followup-richness-upgrades-plan.md`
- Phase 2 plan (predecessor): `docs/plans/2026-05-27-002-feat-followup-reply-keywords-plan.md`
- Current scheduler: `scripts/scheduler.sh`
- Current /follow-up: `commands/follow-up.md`
- Ledger primitives: `briefings_mcp/ledger.py`, `briefings_mcp/schema.py`
- Phase 4 future scope: pattern flags drawn from ledger history (see Scope Boundaries → Deferred to Follow-Up Work).
