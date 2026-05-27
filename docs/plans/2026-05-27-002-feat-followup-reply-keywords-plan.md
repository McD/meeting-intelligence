---
title: "feat: Replace Why? capture with expand/quote reply keywords (Phase 2)"
type: feat
status: active
date: 2026-05-27
---

# feat: Replace Why? capture with expand/quote reply keywords (Phase 2)

## Summary

Remove the Why? capture loop entirely (its prompt, its state files, its parser module, and its smoke tests) and replace it with a more useful reply-keyword model: every follow-up email now invites four reply keywords (`expand:`, `quote:`, `cancel`, `extend`) and the scheduler polls a new `*-awaiting-reply-*.md` state file per follow-up. `expand:` re-fetches the transcript via Phase 1's `$TRANSCRIPT_SOURCE` and runs Claude with the user's specific ask; `quote:` extracts 3–6 direct quotes about a topic. The ledger schema is unchanged — historical `why`/`why_notes` data on past entries stays in place; only the loop that populated them is retired.

---

## Problem Frame

The Why? capture loop assumed the user would reply to high-stakes follow-ups with rationale lines like `1: <reason>`, and that rationale would compound into future briefings. In practice the user doesn't engage with it — the prompts add email clutter without delivering value. Meanwhile, the same email-reply channel could be used for something the user *does* want: asking the meeting for more. "Write up Mark's industry overview as a one-pager." "Give me Robert's quotes on Pulse positioning." Phase 2 reuses the existing reply-polling infrastructure but pointed at a useful interaction.

---

## Requirements

- R1. Stop emitting the `## Why?` section in any follow-up. No conditional, no high-stakes gate, just gone.
- R2. Stop creating `~/Briefings/*-awaiting-why-*.md` state files.
- R3. Stop importing `briefings_mcp.why_capture` from `commands/follow-up.md`. Delete the parser module.
- R4. Existing `*-awaiting-why-*.md` files on disk (from before the upgrade) must be cleanly retired by Step 0 — log once and delete, do not crash the scheduler.
- R5. Every follow-up email (low- or high-stakes — the distinction disappears in Phase 2) gets a short reply-keyword footer explaining `expand:`, `quote:`, `cancel`, `extend`.
- R6. Every follow-up creates a `~/Briefings/YYYY-MM-DD-HHmm-awaiting-reply-slug.md` state file with fields `thread_id`, `meeting`, `slug`, `transcript_source`, `created_at`. Expires after 30 days.
- R7. Step 0's awaiting-file dispatch gets a new `*-awaiting-reply-*.md` branch with four keyword handlers:
  - `expand: <request>` — re-fetch transcript from `transcript_source`, run Claude with the request, email the result back to the same thread (and Slack-mirror if webhook configured)
  - `quote: <topic>` — re-fetch transcript, return 3–6 direct quotes about that topic
  - `cancel` / `skip` — delete the awaiting-reply state file
  - `extend` — bump `created_at` to reset the 30-day expiry
- R8. Phase 1 sections (Notable threads, Source, Counterparty read, confidence callouts, hardened Open questions) are preserved exactly.
- R9. Ledger schema fields `why` and `why_notes` stay in `briefings_mcp/schema.py` `FIELDS` and in the SQLite index columns — historical entries already use them.
- R10. `scripts/verify-v1.sh` continues to pass end-to-end: U3 smoke test section is removed, remaining sections renumbered, `--with-email` repurposed (or removed) since it currently exercises why-capture.

---

## Scope Boundaries

- No changes to `briefings_mcp` MCP server tools (`search_decisions`, `get_decision_by_id`, `list_attendees`). The query surface is untouched.
- No changes to the ledger format. `why` and `why_notes` remain valid fields on existing entries; new entries simply leave them as empty strings.
- No changes to the briefing side (`commands/briefing.md`, SITREP shape, verdict heading). The high-stakes verdict reading in current Step 4 reads briefings, not vice versa — and only to populate is_high_stakes, which goes away.
- No changes to the transcript-request awaiting flow in Step 0 (the existing branch that handles `cancel`/`extend`/`<transcript>` for `*-awaiting-<slug>.md` files). That continues to do its job for meetings without a Gemini/Teams transcript.
- No new MCP tools. The `expand:` and `quote:` keyword handling is in-process in `commands/follow-up.md` Step 0; not an MCP roundtrip.

### Deferred to Follow-Up Work

- **Phase 3:** Twice-weekly actions tracker digest (Mon and Thu at 10am), status reply keywords (`done:`, `more:`, `drop:`), smart pre-marking from Gmail/Slack signals. Separate PR.
- **Phase 4:** Pattern flags drawn from ledger history. Separate PR.
- **Ledger schema cleanup:** A future major-version migration could drop `why`/`why_notes` from `FIELDS` and the SQLite columns. Not in scope now — existing entries would still need a backfill or accommodation. Defer indefinitely; the cost of carrying two unused fields is negligible.

---

## Context & Research

### Relevant Code and Patterns

- `commands/follow-up.md`:
  - Step 0 lines ~46–98 — "Why-capture branch" (delete)
  - Step 0 lines ~100–148 — "Transcript-request branch" (keep, use as the shape template for the new awaiting-reply branch)
  - Step 4 lines ~268–344 — high-stakes flag computation + heredoc that calls `schema.is_high_stakes` and writes `why`/`why_notes` defaults (rip out the is_high_stakes call; the entries still get appended to the ledger, just without the high-stakes path)
  - Step 5 lines ~384–395 — Why? section emission (delete)
  - Step 6 lines ~466–483 — awaiting-why state file creation (replace with awaiting-reply state file creation, scope expanded to all follow-ups)
- `briefings_mcp/why_capture.py` — entire module deletes (108 lines)
- `briefings_mcp/schema.py` lines ~99–111 — `is_high_stakes` function deletes; `FIELDS` list with `why`/`why_notes` stays
- `briefings_mcp/ledger.py` lines ~69–123 — `update_why` function deletes (only caller was why_capture.py); the file-rewrite primitive could be kept for `extend`'s `created_at` bump on the awaiting-reply file, but that's a different file shape and a simpler in-shell edit — no need to repurpose `update_why`. Delete cleanly.
- `briefings_mcp/index.py` lines ~38–72 — `why`, `why_notes` columns in SQLite index stay (existing entries still have them). No changes.
- `scripts/smoke_test_u3.py` — entire file deletes (202 lines, tests the parser being deleted)
- `scripts/scheduler.sh` lines ~139–174 — uses `*-awaiting-*` glob which naturally catches both transcript-awaiting and the new reply-awaiting files. No changes needed.
- `scripts/verify-v1.sh`:
  - Lines ~136–157 (Section 4: U3 smoke test) — delete
  - Section numbering 5–10 — renumber to 4–9
  - Lines ~382–414 (Section 9: `--with-email`) — currently sends a fixture follow-up with "1: <reason>" reply instructions. Repurpose to send a fixture follow-up exercising `expand:` (or simply remove the flag; the live `--with-followup` already exercises real `/follow-up`).
- `README.md`:
  - Line 58 — `--with-email` flag description (update or remove)
  - Line 132 — file layout mentions `*-awaiting-why-*.md` (replace with `*-awaiting-reply-*.md`)
  - Line 180 — Decision ledger and MCP server section mentions "High-stakes entries get a numbered 'Why?' prompt..." (replace with the new reply-keyword model)
  - Line 205 — How the scheduler decides... mentions "pending transcript or why-capture replies" (update wording)

### Institutional Learnings

- Phase 1 set the pattern of capturing `$TRANSCRIPT_SOURCE` in Step 2 (Phase 1 commit 7a2f2ff). That value is what makes `expand:`/`quote:` possible — re-fetch lazily rather than store transcript content on disk.
- The `*-awaiting-*` state-file pattern is reusable: every state file the scheduler needs to poll lives under a shared glob. Phase 2 follows the same naming pattern (`*-awaiting-reply-*`) so the scheduler glob continues to work without changes.
- The existing transcript-request branch in Step 0 already handles the `first-non-quoted-line` keyword parsing pattern (cancel/extend/transcript). The new awaiting-reply branch mirrors that pattern — same Gmail-thread polling, same first-non-quoted-line extraction.
- Per user memory: edits to `commands/follow-up.md` propagate via `bash update.sh` to `~/.claude/commands/follow-up.md`. The headless scheduler reads the installed copy.

### External References

None required. All work is internal to the repo's existing patterns.

---

## Key Technical Decisions

- **Every follow-up gets an awaiting-reply file, not just high-stakes ones.** The high-stakes distinction goes away with the Why? loop. Reply-keyword interaction is a universal affordance, not a high-stakes one. Cost is one small markdown file per meeting; cleanup is automatic after 30 days.
- **Replicate, don't repurpose, the awaiting-transcript handler.** The transcript-request branch has its own state-file shape (`thread_id`, `meeting`, `slug`, `requested_at`) and a fixed keyword set (cancel/extend/anything-else-is-transcript). The new awaiting-reply branch has a *different* shape (`thread_id`, `meeting`, `slug`, `transcript_source`, `created_at`) and a different keyword set (expand/quote/cancel/extend). Mixing them into one handler creates dispatch ambiguity. Keep them parallel and distinct.
- **`expand:` and `quote:` lazily re-fetch the transcript.** Don't cache transcript text on disk; the Source URL captured in Phase 1 is the single source of truth. If the transcript becomes unreachable (Gemini doc deleted, MacWhisper file gone), the reply handler responds with "Sorry — original transcript no longer available at <url>" rather than failing silently.
- **Backward-compat cleanup is a one-time graceful retirement, not a migration.** Step 0 finds any `*-awaiting-why-*.md` files, logs `"Retiring Phase 1 awaiting-why file: [slug] — feature replaced in Phase 2"`, and deletes them. The ledger entries those files pointed at are kept untouched. No fancier migration is warranted.
- **`extend` resets `created_at` rather than introducing a separate `expires_at` field.** Mirrors the transcript-request branch's behaviour. One field, one mental model.
- **Keep `why` and `why_notes` in the schema.** Removing them would be a breaking change to existing ledger entries. The cost of carrying two unused fields is negligible; the cost of a schema migration just to clean up is real. Decision: never remove them unless a future major version explicitly migrates.
- **`--with-email` in verify-v1.sh is dropped.** The flag was a manual harness for the why-capture path. With why-capture gone, `--with-followup` (Phase 1) is the canonical follow-up shape verification, and the new awaiting-reply machinery can be exercised manually by replying to a real follow-up. Removing the flag avoids dead code.

---

## Open Questions

### Resolved During Planning

- *What happens to existing `~/.briefings/decisions.jsonl` entries with populated `why`/`why_notes` values?* Stay as-is, untouched. Schema fields remain valid.
- *Does the scheduler's `*-awaiting-*` glob need updating?* No — both the new `*-awaiting-reply-*.md` and the existing `*-awaiting-<slug>.md` (transcript) match the glob.
- *Where does `expand:`'s output get sent?* Email reply to the same Gmail thread + Slack message if `~/.slack_webhook` is configured (same channels and pattern as the original follow-up).
- *How does `quote:` know which quotes to surface?* Claude reads the full transcript and extracts 3–6 direct quotes where the speaker discusses or references the topic. Topic matching is fuzzy (substring + semantic), not strict.
- *Is there a way for `expand:` to chain* (reply to an expand reply)? Out of scope for Phase 2. The awaiting-reply file points at one Gmail thread (the original follow-up). Replies to `expand:` outputs land in the same thread and are caught on the next poll; the keyword parser runs on the latest unprocessed message either way. If chaining becomes a problem, revisit in Phase 3+.

### Deferred to Implementation

- The exact wording of the Step 3 / Step 5 prompts that produce `expand:` and `quote:` results — tune against a real meeting fixture during U4 implementation.
- The exact footer copy on the follow-up email — draft included in this plan, polish during U3 implementation.
- Whether `expand:` outputs should also be saved to `~/Briefings/YYYY-MM-DD-HHmm-expand-N-slug.md` for archive. Likely yes for parity with the follow-up artifact pattern, but TBD during U4 — adds complexity, may not be needed.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
Step 0 dispatch (after Phase 2):

  for each ~/Briefings/*-awaiting-*.md file:
    basename contains "-awaiting-why-"     → log + delete (retirement of Phase 1 artifact)
    basename contains "-awaiting-reply-"   → reply-keyword branch (NEW)
    otherwise (basename "-awaiting-<slug>") → transcript-request branch (UNCHANGED)

Reply-keyword branch logic:

  Read state file: thread_id, meeting, slug, transcript_source, created_at
  If created_at > 30 days ago: delete + log expiry, skip
  Fetch Gmail thread by thread_id
  If only 1 message in thread: skip (no reply yet)
  Read last message body
  Take first non-empty, non-quoted line, lowercase, strip
  Dispatch:
    "cancel" / "skip"     → delete state file, log, done
    "extend" / "wait"     → bump created_at to now, log, done
    "expand: <request>"   → fetch transcript via transcript_source,
                             run Claude with the request as prompt,
                             send result as email reply + Slack mirror,
                             leave state file in place (further replies OK)
    "quote: <topic>"      → fetch transcript via transcript_source,
                             extract 3–6 direct quotes about <topic>,
                             send as email reply + Slack mirror,
                             leave state file in place
    anything else         → log "unrecognized reply for [meeting]: <line>", leave state file
```

Awaiting-reply state file shape (mirrors awaiting-<slug>):

```
thread_id: <gmail-thread-id>
meeting: <Meeting Title>
slug: YYYY-MM-DD-HHmm-slug
transcript_source: <url-or-file-path>
created_at: 2026-05-27T11:00:00Z
```

Follow-up email footer (added in U3, every follow-up):

```
---
Reply to this thread to dig deeper:
- `expand: <request>` — re-runs against the transcript (e.g. "expand: write up Mark's industry overview as a one-pager")
- `quote: <topic>` — pulls direct quotes about that topic
- `cancel` — drops the reply thread for this meeting
- `extend` — keeps the thread open another 30 days
```

---

## Implementation Units

- U1. **Rip Why? out of the follow-up assembly pipeline**

**Goal:** Remove all Why? emission from `commands/follow-up.md` Steps 4, 5, and 6. The output template no longer contains `## Why?`, Step 4 no longer computes `is_high_stakes`, Step 6 no longer creates `*-awaiting-why-*.md` state files. Ledger writes still happen (without the high-stakes gating; entries are written as-is).

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Step 4: drop the three-part high-stakes computation (verdict + is_external + attendee_history_count). Keep the items-list build + ledger.append loop in the heredoc. Drop the `IS_EXTERNAL` env var passing if not needed elsewhere — `is_external` is still computed for the Counterparty read conditional in Step 5 (Phase 1), so keep the variable in scope but stop passing it to the Python heredoc. Drop the `MEETING_VERDICT` env var entirely. Replace the `high_stakes = schema.is_high_stakes(...)` line and its downstream use.
- Step 4 Python heredoc: simplify return value from `{"high_stakes": bool, "results": [...]}` to just `{"results": [...]}`. Step 5 and Step 6 must be updated to not expect the high_stakes key.
- Step 5: delete the "Why? section" paragraph (lines ~384–395 of current file) and the `## Why?` block from the template. The Phase 1 template (Summary / Action items / Key decisions / Notable threads / Open questions / Counterparty read / Source) is preserved exactly.
- Step 6: delete the awaiting-why state file creation block (~lines 466–483). U3 will add awaiting-reply state file creation in its place (separate unit for atomic commits).

**Patterns to follow:**
- Phase 1's Counterparty conditional (Step 5) shows the pattern for using `is_external` without passing it through Python.

**Test scenarios:**
- Happy path: force-regenerate a follow-up via `/follow-up --force "<meeting>"` — output file does not contain `## Why?` heading.
- Happy path: external/high-stakes meeting still produces all Phase 1 conditional sections; only Why? is gone.
- Edge case: internal/low-stakes meeting follow-up file produces no `## Why?` (this was already the case but confirm regression-free).
- Edge case: Step 4 ledger.append still runs and entries land in `~/.briefings/decisions.jsonl` with `why=""` and `why_notes=""` defaults — schema unchanged.

**Verification:**
- `bash scripts/verify-v1.sh --with-followup` passes. The conditional-sections report no longer expects Why?
- A `grep -c '## Why?' ~/Briefings/<latest-followup>.md` returns 0 after regeneration.

---

- U2. **Replace Step 0 Why-capture branch with a stray-file cleanup branch**

**Goal:** Step 0's dispatch loop no longer routes to a Why-capture branch. Instead, any `*-awaiting-why-*.md` file found on disk is logged and deleted as a Phase 1 artifact retirement. The transcript-request branch remains unchanged.

**Requirements:** R3 (partial), R4

**Dependencies:** U1 (no new awaiting-why files will be created)

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Step 0 dispatch: keep the `*-awaiting-*.md` glob. Inspect each basename:
  - Contains `-awaiting-why-` → log `"Retiring Phase 1 awaiting-why file: [slug] — feature replaced in Phase 2"` to `~/Briefings/scheduler.log` and delete the file. Do not touch the underlying ledger entry; do not crash.
  - Contains `-awaiting-reply-` → fall through to U4's new branch (added in a later unit; if U4 hasn't landed yet, log "unrecognized awaiting type" and skip).
  - Otherwise → existing transcript-request branch (unchanged).
- Delete the existing Why-capture branch prose (~lines 46–98) entirely.

**Patterns to follow:**
- Existing transcript-request branch dispatch shape.

**Test scenarios:**
- Happy path: drop a fake `~/Briefings/2026-01-01-1000-awaiting-why-test.md` file, run `/follow-up all`, confirm the file is deleted and a log line appears in `~/Briefings/scheduler.log`.
- Happy path: a normal transcript-awaiting file is still routed to the transcript-request branch.
- Edge case: no awaiting files at all — Step 0 falls through to Step 1 without error.
- Error path: an awaiting-why file with unreadable permissions — log the error, do not crash, continue.

**Verification:**
- `/follow-up all` runs cleanly with a stray awaiting-why file in `~/Briefings/`; the file is gone afterward and the log has the retirement line.

---

- U3. **Add reply-keyword footer + awaiting-reply state file creation in Step 6**

**Goal:** Every follow-up email gets a reply-keyword footer; every follow-up creates an `~/Briefings/YYYY-MM-DD-HHmm-awaiting-reply-slug.md` state file with `thread_id`, `meeting`, `slug`, `transcript_source`, `created_at`.

**Requirements:** R5, R6

**Dependencies:** U1 (the high-stakes gating is gone, so awaiting-reply is unconditional)

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Step 5 template: append a `---` separator after the existing sections (the Phase 1 shape ends with `## Source` and the Why? block is now gone). Below the separator, add the reply-keyword footer (see High-Level Technical Design for exact copy).
- Step 6: replace the deleted awaiting-why creation block with awaiting-reply creation. Same `umask 077` + `cat > file` + `chmod 600` pattern. Fields:
  - `thread_id: $THREAD_ID` (captured from `gws gmail +send`, same as before)
  - `meeting: <Meeting Title>`
  - `slug: YYYY-MM-DD-HHmm-slug`
  - `transcript_source: $TRANSCRIPT_SOURCE` (Phase 1 capture; empty string is acceptable — expand/quote will respond honestly)
  - `created_at: <ISO timestamp>`
- Skip awaiting-reply file creation when `$THREAD_ID` is empty (log a WARN as in the existing pattern).
- The footer is part of the markdown file that gets HTML-converted in Step 6, so the renderer already handles it.

**Patterns to follow:**
- Step 6 awaiting-why creation block (the one being replaced) — same structure, different fields.
- Step 5 omit-when-empty convention.

**Test scenarios:**
- Happy path: force-regenerate a follow-up, confirm `~/Briefings/YYYY-MM-DD-HHmm-awaiting-reply-slug.md` exists with all five fields populated.
- Happy path: the email-rendered follow-up has the footer with four keyword bullets.
- Happy path: the Slack-rendered follow-up has the footer (mrkdwn-converted).
- Edge case: meeting where `$TRANSCRIPT_SOURCE` couldn't be determined — `transcript_source:` line is empty string, file still created.
- Edge case: `$THREAD_ID` empty (email send failed to return a threadId) — no awaiting-reply file created, WARN logged.
- Edge case: low-stakes internal meeting still gets the footer and the state file (high-stakes distinction is gone).

**Verification:**
- Force-regenerate a follow-up. State file present with five fields. Email body ends with the footer.

---

- U4. **Add awaiting-reply dispatch in Step 0 (expand/quote/cancel/extend)**

**Goal:** Step 0's awaiting-* dispatch grows a new branch for `*-awaiting-reply-*.md` files that handles the four keywords against Gmail thread replies.

**Requirements:** R3 (complete), R7

**Dependencies:** U2 (dispatch shape), U3 (state files exist to act on)

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Add the awaiting-reply branch to Step 0 dispatch, after the awaiting-why retirement check, before the transcript-request branch:
  1. Read state file (five fields).
  2. Check expiry: if `created_at` > 30 days ago, delete file + log expiry, skip.
  3. Fetch Gmail thread by `thread_id` via `gws gmail users threads get`.
  4. If only 1 message in thread: skip (no reply yet, scheduler will retry on next cycle).
  5. Read last message body via `gws gmail +read --message-id "[id]"`.
  6. Take first non-empty non-quoted line, lowercase, strip.
  7. Dispatch on prefix:
     - `cancel` / `skip` → delete file, log, done
     - `extend` / `wait` / `more time` → rewrite file with `created_at` = now (preserve other fields), log, done
     - `expand:` (with content after the colon) → fetch transcript content via `transcript_source` (Google Doc via `gws drive`, Gmail thread via `gws gmail`, or read local `file://` path), run a focused Claude prompt with the user's request plus the transcript, format output as markdown, send as Gmail reply + Slack mirror, log, leave file in place for further interactions
     - `quote:` (with content) → fetch transcript, extract 3–6 quotes matching the topic (Claude prompt), send as Gmail reply + Slack mirror, log, leave file in place
     - anything else → log `"Unrecognized reply for [meeting]: <first line>"`, leave file
  8. Process every awaiting-reply file before falling through to Step 1.

**Patterns to follow:**
- Existing transcript-request branch (Step 0 lines ~100–148) — same Gmail thread polling, same first-non-quoted-line extraction, same first-class `cancel`/`extend`.
- Phase 1's `$TRANSCRIPT_SOURCE` capture (Step 2) — same five-branch shape mirrored when fetching.

**Test scenarios:**
- Happy path expand: reply with `expand: write up Mark's industry overview as a one-pager` → email reply lands in the thread with a one-pager generated from the transcript; awaiting-reply file remains for further interaction.
- Happy path quote: reply with `quote: pulse positioning` → email reply lists 3–6 direct quotes mentioning Pulse positioning; awaiting-reply file remains.
- Happy path cancel: reply with `cancel` → awaiting-reply file deleted; no email reply sent.
- Happy path extend: reply with `extend` → `created_at` bumped; awaiting-reply file remains; 30-day clock reset.
- Edge case: `transcript_source` is empty string → expand/quote respond with "Sorry — original transcript not available, cannot expand", email reply sent, state file remains so the user can `cancel` to clear.
- Edge case: `transcript_source` points at a Google Doc that's been deleted → fetch fails, expand/quote respond with "Sorry — original transcript no longer available at <url>", same handling as above.
- Edge case: `transcript_source` is a `file://` path on the same machine; file no longer exists → same handling.
- Edge case: keyword with no argument (`expand:` alone) → reply "Specify what to expand on: e.g. `expand: write up the industry overview`"; state file remains.
- Edge case: keyword case-insensitivity — `Expand: foo` and `EXPAND: foo` both match.
- Edge case: multiple awaiting-reply files in a single Step 0 cycle — each processed independently.
- Edge case: expand: text contains quoted email signature — quoted-line stripping (`>` prefix) applied before keyword detection, same pattern as transcript-request branch.

**Verification:**
- Send yourself a follow-up via `/follow-up --force`. Reply with `quote: <some topic from the meeting>`. Within 15 minutes (next scheduler cycle), a reply email lands with 3–6 quotes.

---

- U5. **Delete why_capture.py, smoke_test_u3.py, update_why, is_high_stakes**

**Goal:** Remove the parser module, its tests, the ledger update helper that only it called, and the schema helper function that only follow-up.md called.

**Requirements:** R3 (parser delete), R9 (schema fields stay)

**Dependencies:** U1, U2 (last in-repo callers go away before deletion)

**Files:**
- Delete: `briefings_mcp/why_capture.py`
- Delete: `scripts/smoke_test_u3.py`
- Modify: `briefings_mcp/ledger.py` (remove `update_why` function and its docstring lines in the module-level docstring)
- Modify: `briefings_mcp/schema.py` (remove `is_high_stakes` function; keep `FIELDS` list including `why` and `why_notes`)

**Approach:**
- Delete the two files.
- In `ledger.py`: remove the `update_why` function definition. Edit the module-level docstring (lines ~7–9) to drop the "with one exception: `update_why`..." sentence since the file is now truly append-only again.
- In `schema.py`: remove the `is_high_stakes` function (lines ~99–end). The `FIELDS` constant including `why` and `why_notes` stays.

**Patterns to follow:**
- N/A — this is pure deletion.

**Test scenarios:**
- Happy path: `python3 -c "import briefings_mcp"` succeeds.
- Happy path: `python3 -c "from briefings_mcp import ledger, schema, query, index, server"` succeeds. No reference to `why_capture` survives.
- Happy path: `python3 -c "from briefings_mcp.schema import FIELDS; assert 'why' in FIELDS and 'why_notes' in FIELDS"` succeeds (fields preserved).
- Error path: `python3 -c "from briefings_mcp import why_capture"` fails with ImportError (module is gone).
- Error path: `python3 -c "from briefings_mcp.schema import is_high_stakes"` fails with ImportError.
- Error path: `python3 -c "from briefings_mcp.ledger import update_why"` fails with ImportError.
- Edge case: existing `~/.briefings/decisions.jsonl` entries with populated `why`/`why_notes` values still read cleanly via `query.search_decisions`.

**Verification:**
- `bash scripts/verify-v1.sh` passes (with U6 already in place to drop the U3 smoke test section).
- A spot check `query.search_decisions(attendee="<known>")` returns historical entries including any with populated `why` fields, and the `why` content is still surfaced in the result dict.

---

- U6. **Update verify-v1.sh — remove U3 smoke test section, renumber, drop --with-email**

**Goal:** The verify harness no longer references the deleted parser or smoke test. Section numbering is clean. `--with-email` (which exercised why-capture) is removed.

**Requirements:** R10

**Dependencies:** U5 (smoke_test_u3.py must be gone)

**Files:**
- Modify: `scripts/verify-v1.sh`

**Approach:**
- Delete section 4 (U3 smoke test, lines ~136–157).
- Renumber subsequent sections: 5 (U4 smoke test) → 4, 6 (U4 stdio boot) → 5, 7 (MCP-query roundtrip) → 6, 8 (--with-briefing) → 7, 9 (--with-email) → delete entirely, 10 (--with-followup) → 8.
- Remove the `--with-email` flag handling at the top of the file (the loop that reads `$@`).
- Update the `--help` output to drop `--with-email`.
- Update header comment block at the top (lines ~1–18) to remove the `--with-email` description.
- Final assertions in the summary block (PASS_COUNT / FAIL_COUNT messaging) don't need changes.

**Patterns to follow:**
- The Phase 1 `--with-followup` block already in place (gated, mirrors `--with-briefing` shape).

**Test scenarios:**
- Happy path: `bash scripts/verify-v1.sh --help` shows the new flag list (no `--with-email`).
- Happy path: `bash scripts/verify-v1.sh` (no flags) runs cleanly with the new section numbering, all PASS lines.
- Happy path: `bash scripts/verify-v1.sh --with-briefing --with-followup` exercises sections 7 and 8 with the new numbering.
- Error path: `bash scripts/verify-v1.sh --with-email` prints "Unknown arg" warning (still warns rather than failing, consistent with current loose-arg-handling).

**Verification:**
- `bash scripts/verify-v1.sh` exits 0 with sequential section numbers 1–8 (or 1–6 with --with-briefing and --with-followup both skipped).

---

- U7. **Update README — replace Why-capture documentation with reply-keyword model**

**Goal:** Four locations in the README that mention Why? get updated to describe the new reply-keyword model.

**Requirements:** R5 (footer is the user-visible surface), R10

**Dependencies:** U1–U6 (describe what shipped, not what's planned)

**Files:**
- Modify: `README.md`

**Approach:**
- Line 58 area (Update section): remove the `--with-email` flag description from the Optional flags list since that flag is gone. Replace with a short sentence about the reply keywords being live: "Replies to any follow-up email with `expand: <request>`, `quote: <topic>`, `cancel`, or `extend` are picked up by the scheduler on the next 15-minute cycle."
- Line 132 area (file layout block): change `~/Briefings/*-awaiting-why-*.md   # Why-capture state, awaiting email reply` to `~/Briefings/*-awaiting-reply-*.md  # Reply-keyword state (expand/quote/cancel/extend), 30-day expiry`.
- Line 180 area (Decision ledger and MCP server): replace the Why?-related paragraph with: "Every follow-up invites four reply keywords on its email thread: `expand: <request>` re-runs Claude over the transcript with your specific ask, `quote: <topic>` returns direct quotes from the meeting, `cancel` drops the thread, `extend` keeps it open another 30 days. The scheduler polls these threads every 15 minutes via the `*-awaiting-reply-*.md` state files. The decision ledger stores commitments and decisions extracted at follow-up time and feeds the next briefing's `Delta:` section — historical entries from before Phase 2 may still carry `why`/`why_notes` data, which the briefing reads naturally."
- Line 205 area (How the scheduler decides): change "pending transcript or why-capture replies" to "pending transcript or reply-keyword replies".

**Patterns to follow:**
- Existing README voice (prose-first for narrative sections, bullets in layout block, no em dashes per user preference).

**Test scenarios:**
- Documentation review only (no behavioural assertion).
- Test expectation: none — pure documentation update.

**Verification:**
- A new reader can follow the README and understand the reply-keyword model without any reference to Why? capture.
- `grep -c -i "why?" README.md` returns 0 (or only matches unrelated uses if any survive).

---

## System-Wide Impact

- **Interaction graph:** Phase 2 changes are localised to `commands/follow-up.md` (the slash command), two `briefings_mcp/*.py` files (`ledger.py`, `schema.py`), and one deletion under `briefings_mcp/why_capture.py`. The scheduler at `scripts/scheduler.sh` is unaffected because the `*-awaiting-*` glob continues to match both the existing transcript-awaiting files and the new reply-awaiting files. The MCP server tool surface is unchanged.
- **Error propagation:** New failure modes in U4 (transcript no longer reachable, unrecognized keyword, expand: with no argument). All surface as user-visible email replies, not as crashes. The state file is retained so the user can `cancel` or `extend` after a failed interaction.
- **State lifecycle risks:**
  - Existing `*-awaiting-why-*.md` files: handled by U2's retirement branch (log + delete, ledger untouched).
  - New `*-awaiting-reply-*.md` files: 30-day TTL, deleted on `cancel`, refreshed on `extend`. No risk of unbounded growth.
  - Ledger entries: `why`/`why_notes` data on historical entries preserved; new entries get empty strings. No migration needed.
- **API surface parity:** No changes to `briefings_mcp` MCP tools. No new MCP tools. No changes to ledger JSONL shape or SQLite index columns.
- **Integration coverage:** The new awaiting-reply flow is exercised manually by replying to a real follow-up; `verify-v1.sh --with-followup` (Phase 1) continues to assert follow-up file shape end-to-end. No automated test of the Gmail-reply polling cycle (scheduler-driven, requires real Gmail thread — same gap exists for the existing transcript-request branch, accepted in Phase 1).
- **Unchanged invariants:**
  - Phase 1 sections (Notable threads, Source, Counterparty read, confidence callouts, hardened Open questions) stay exactly as they are.
  - Step 4 still appends to the ledger via `briefings_mcp.ledger.append`; entry shape unchanged.
  - Transcript-request branch in Step 0 is unchanged.
  - SITREP brief shape (`commands/briefing.md`) is unchanged.
  - MCP server tools (`search_decisions`, `get_decision_by_id`, `list_attendees`) unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `expand:` outputs are unbounded — Claude could write a 5000-word response that floods the email thread. | Footer prompt frames expand as "a specific ask, not 'tell me everything'". The implementing prompt in U4 imposes a soft ceiling (e.g. "respond in 200–800 words unless asked for more"). User can always reply `cancel` to escape. |
| `transcript_source` URLs go stale (Gemini Doc deleted, MacWhisper file moved). | U4 handles fetch failures gracefully: email reply explains the source is gone; state file remains for `cancel`. No retry storm. |
| A user replies with a typo (`expnd: foo`). Step 0's default branch logs unrecognized and leaves the state file, but no feedback is sent — user thinks the system is broken. | U4's unrecognized-keyword branch sends a one-line email reply: "Didn't recognize 'expnd:' — try `expand:`, `quote:`, `cancel`, or `extend`." Same Gmail thread. |
| Existing `*-awaiting-why-*.md` files have ledger-pointing UUIDs that look like they should be backfilled. | They shouldn't. The Why? loop's job was to fill `why` fields; if the user never replied, the field stays empty, and that's fine. The retirement log line in U2 doesn't claim data was lost, just that the feature is replaced. |
| Phase 2 ships, but the user has an old follow-up email open and replies with `1: <reason>` (Phase 1 muscle memory). | The `awaiting-reply` branch's unrecognized-keyword fallback catches this. The user gets a one-line reply explaining the new keywords. No data corruption, no silent failure. |
| `update.sh` propagation gap. Edits to `commands/follow-up.md` and any `briefings_mcp/*.py` need both the file copy AND `pip install -e .` in the runtime venv. | `update.sh` already handles both (Phase 1 confirmed). Call it out in the commit message + verification step of U5. |
| Deleting `update_why` could break a downstream consumer the grep missed. | Grep against the full repo (Python + shell + markdown) confirmed only `why_capture.py` calls it. Worst case, the test suite or `verify-v1.sh` catches an unexpected ImportError. |

---

## Documentation / Operational Notes

- After merge, run `bash update.sh` to propagate `commands/follow-up.md` to `~/.claude/commands/follow-up.md` and refresh the runtime venv editable install of `briefings_mcp` (so the deletion of `why_capture.py` and `is_high_stakes` is reflected).
- Run `bash scripts/verify-v1.sh` (without `--with-email` — that flag is gone) to confirm the new shape end-to-end.
- Run `bash scripts/verify-v1.sh --with-followup` to validate Phase 1 + Phase 2 together: follow-up shape correct, no `## Why?` section, awaiting-reply state file created.
- Existing `~/Briefings/*-awaiting-why-*.md` files will be retired by the next scheduler cycle after install — no manual cleanup needed.
- No env var or config file changes (`~/.briefings_config` is untouched).
- The plan note about why/why_notes staying in the schema is important for any future contributors who might be tempted to "clean up" — preserve the comment in `briefings_mcp/schema.py` `FIELDS` so the decision is durable.

---

## Sources & References

- Phase 1 plan (predecessor): `docs/plans/2026-05-27-001-feat-followup-richness-upgrades-plan.md`
- v1 plan (Why? capture origin): `docs/plans/2026-05-19-001-feat-sitrep-ledger-counterparty-v1-plan.md`
- Current `/follow-up` slash command: `commands/follow-up.md`
- Modules to be deleted or trimmed: `briefings_mcp/why_capture.py`, `briefings_mcp/schema.py`, `briefings_mcp/ledger.py`, `scripts/smoke_test_u3.py`
- Phase 3–4 future scope: documented in Scope Boundaries → Deferred to Follow-Up Work.
