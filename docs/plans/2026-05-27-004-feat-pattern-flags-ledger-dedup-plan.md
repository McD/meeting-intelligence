---
title: "feat: Pattern flags + ledger dedup (Phase 4)"
type: feat
status: active
date: 2026-05-27
---

# feat: Pattern flags + ledger dedup (Phase 4)

## Summary

Two related housekeeping features that close out the roadmap. **Pattern flags** scan the ledger for recurring topic tags in the last 60 days and surface the top three in /briefing (filtered by the current meeting's attendees), /follow-up (which patterns the just-finished meeting reinforced), and /digest (a one-line global summary). **Ledger dedup** adds a near-duplicate check to `briefings_mcp.ledger.append` so future /follow-up --force re-runs don't accumulate copies of the same commitment, plus a one-time cleanup script (`scripts/dedup_ledger.py`) that retires the duplicates already in the production ledger (5+ surfaced during Phase 3's live validation).

---

## Problem Frame

The ledger has been silently solving one problem — historical context for briefings — while accumulating noise from two angles. First, recurring themes across meetings aren't being surfaced anywhere; the briefing knows the last touchpoint but doesn't tell you that pricing has come up in six meetings this quarter. Second, /follow-up --force regenerations append duplicate commitment entries (Phase 3's digest displayed three copies of the same Robert action and three of the same Elizabeth action). Phase 4 fixes both: turn pattern detection into a visible signal across all three output surfaces, and stop duplicates at the write boundary while cleaning up the ones already on disk.

---

## Requirements

- R1. A new `briefings_mcp.query.find_patterns(window_days, min_count, limit, attendees, topic_filter)` function returning a list of `(topic_tag, count)` tuples for recurring themes within the window.
- R2. Pattern surface in /briefing: a new `Patterns:` line in the SITREP block (after `Counterparty:`) showing 1–3 cross-meeting echoes filtered by this meeting's attendees. Omit when no patterns meet the threshold.
- R3. Pattern surface in /follow-up: a new `## Pattern flags` section between `## Counterparty read` and `## Source`, showing 1–3 patterns this meeting reinforced (topics it shares with prior entries). Omit-when-empty.
- R4. Pattern surface in /digest: a one-line summary at the top (under the date header) showing the period's top three recurring themes. Omit when no patterns above threshold.
- R5. Ledger dedup-on-write in `briefings_mcp.ledger.append`: when appending a commitment, check the last N entries for the same `source_meeting` + matching `summary` (exact OR first-60-char-prefix); if a match exists, skip the write and return without raising.
- R6. One-time cleanup at `scripts/dedup_ledger.py`: scan the entire ledger for near-duplicate commitments within the same source_meeting, identify dup clusters, keep the EARLIEST by `created_at`, and remove the rest. Dry-run by default; `--apply` to actually write.
- R7. `scripts/verify-v1.sh` gains a new smoke test section (smoke_test_u4p4.py) covering find_patterns + dedup-on-write logic.
- R8. README documents pattern flags (where they appear, what triggers them, how to disable) and the dedup behaviour.

---

## Scope Boundaries

- Pattern detection is topic-tag-based. No NLP, no semantic clustering, no fuzzy matching across differently-tagged entries. The topic tags Step 4 of /follow-up already assigns are the substrate.
- Dedup is conservative: same `source_meeting` + summary match. It does NOT cross meetings; two genuinely-similar commitments from different meetings remain distinct.
- The cleanup script does NOT handle decisions — only commitments. Decisions are inherently less likely to duplicate (a meeting reaches one decision per topic, not multiple drafts of the same one).
- No new MCP tools. find_patterns is internal-use only; not exposed via briefings_mcp.server.
- No new ledger schema fields. Dedup is detection logic, not enforcement.
- No retroactive pattern detection for past briefings/follow-ups. New behaviour applies to new generations only.
- The dedup script is a one-shot artifact. It's not wired into the scheduler. The user runs it manually after install if desired.

### Deferred to Follow-Up Work

- A future enhancement could cross-reference patterns with the actions tracker digest's "Owed to you" — e.g. "Robert has 4 overdue items AND 'pricing' has come up in 5 meetings with him" → suggest a structured pricing conversation. Out of scope now.
- Pattern detection over a longer window (90/180 days) for quarterly review use. Defer.
- Slack-side pattern detection (which topics recurring in your Slack DMs) — same Slack-bot-token blocker as Phase 3's smart pre-marking. Defer.

---

## Context & Research

### Relevant Code and Patterns

- `briefings_mcp/query.py` — current functions: `search_decisions(attendee, topic, type, date_from, date_to, state, limit)`, `get_decision_by_id`, `list_attendees`. Phase 4 adds `find_patterns` as the fourth.
- `briefings_mcp/ledger.py` — `append(entry)` is the only writer. Dedup-on-write check inserts before `_ensure_paths`. The new `update_commitment_state` from Phase 3 stays unchanged.
- `briefings_mcp/schema.py` — every entry has a `topics` field (list of strings) per `REQUIRED_BASE_FIELDS`. No schema changes.
- `commands/briefing.md` — SITREP block currently renders `**Trap:**`, `**Delta:**`, `**Comment:**`, `**Counterparty:**` (conditional). Phase 4 adds `**Patterns:**` after Counterparty.
- `commands/follow-up.md` Step 5 — Phase 1 template ends with Source. Add `## Pattern flags` between Counterparty read and Source.
- `commands/digest.md` Step 4 — current template starts with `# Actions tracker` + date heading + sections. Add a one-line pattern summary between the date heading and `## Yours`.
- `scripts/scheduler.sh` — no changes needed (Phase 4 doesn't add new scheduler tasks).
- `scripts/smoke_test_u3p3.py` (Phase 3) — pattern to follow for the new smoke_test_u4p4.py.
- `~/.briefings/decisions.jsonl` — the live ledger currently has the dups visible in Phase 3's digest validation: same Robert/Elizabeth commitments appearing 3+ times each.

### Institutional Learnings

- The omit-when-empty rule is universal across all three commands and has held through Phase 1–3. Phase 4 inherits it.
- Topic tags in Step 4 are fuzzy: Claude infers 1–3 tags per commitment with no fixed vocabulary. find_patterns leans on lowercase exact matching; "pricing" and "Pricing" are the same pattern, but "pricing-strategy" is a separate tag (deliberate — the user can normalize later if it becomes a problem).
- The ledger is single-writer (commands/follow-up.md) and the dedup-on-write check runs in that writer's process. No coordination across processes needed.

### External References

None required. All work is internal to existing patterns.

---

## Key Technical Decisions

- **`find_patterns` filters at query time, not via index.** The ledger is small enough (low hundreds of entries) that an in-memory scan over `iter_entries(since=window_start)` is fast. No SQLite changes; the existing index is unchanged.
- **Dedup check is by exact-summary OR first-60-char-prefix.** Avoids tripping on minor wording variations while catching the actual duplicates Claude produces on re-extraction (which tend to be near-identical sentences). 60 chars matches the existing `summary_max_chars` truncation in the digest renderer, so the prefix already encodes the meaningful signal.
- **Dedup is silent-skip, not raise.** A `--force` regeneration that produces a duplicate commitment is expected behaviour, not an error. The writer returns without writing; the caller doesn't need to know.
- **The cleanup script is offline and one-shot.** Not part of the scheduler, not part of install.sh, not auto-run on update. Runs as `python3 scripts/dedup_ledger.py [--apply]` from the repo root. Defaults to dry-run so the user can review what will be removed before committing.
- **Patterns in /briefing are attendee-relevant.** "Patterns Robert keeps raising" is the implicit framing — filter find_patterns by attendees-include-Robert before picking the top 3. In /follow-up, the same filter but anchored to this meeting's topics. In /digest, no filter (global view).
- **The Patterns label uses `Patterns:` in /briefing (matches SITREP convention) and `## Pattern flags` in /follow-up (matches Phase 1's heading convention).** Different surfaces, different formats; the underlying data is the same.
- **No retroactive backfill of pattern flags.** Past briefings on disk don't get Patterns lines added. New generations only.

---

## Open Questions

### Resolved During Planning

- *What's the min_count threshold?* 3 entries within the 60-day window. Below that is noise.
- *What's the limit?* Top 3 patterns by count, descending. More than 3 becomes a wall of text.
- *Should find_patterns include decisions?* Yes — decisions also have topic tags and contribute to "what keeps coming up." The function takes a `types` parameter for callers that want commitment-only, but defaults to both.
- *How does the cleanup script handle the case where the duplicate has been modified (e.g. one has `state: "done"` from a Phase 3 reply)?* Preserve the one with the most "recent" state (done/dropped > in-flight > open). The cleanup output explains the tiebreaker for each cluster so the user can review.
- *Does dedup-on-write skip the index update too?* Yes — the dedup check returns BEFORE `_ensure_paths` and the JSON write, so neither the JSONL nor the SQLite index is touched.

### Deferred to Implementation

- The exact wording of the Patterns line in /briefing (e.g. "Patterns Robert keeps raising:" vs "Recurring themes:" vs "Pattern:"). Decide while testing against a real briefing.
- The exact heading style in /follow-up's `## Pattern flags` body — prose vs bullet list. Lean toward 1–3 short bullets.

---

## Implementation Units

- U1. **Add `find_patterns` to briefings_mcp.query**

**Goal:** A pure function that scans the ledger for topic tags appearing at or above a count threshold within a date window, with optional attendee/topic filtering. Returns sorted (topic, count) tuples.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `briefings_mcp/query.py`
- Test: smoke coverage in `scripts/smoke_test_u4p4.py` (U5)

**Approach:**
- Signature: `find_patterns(window_days=60, min_count=3, limit=3, attendees=None, topic_filter=None, types=None)`.
- Internally uses `ledger.iter_entries(since=...)` to stream entries within the window.
- For each entry, optionally filter by `types` (default both `commitment` and `decision`), then optionally filter by attendee intersection (if `attendees` is provided), then optionally filter by topic substring (if `topic_filter`).
- Collect topic tags into a `collections.Counter`. Sort by count desc, take top `limit`.
- Return list of `(topic, count)` tuples; empty list when no topic clears `min_count`.
- Pure function — no I/O beyond `ledger.iter_entries`. Easy to test in isolation against a temp ledger.

**Patterns to follow:**
- `briefings_mcp/query.py` existing functions for shape (parameter ordering, type hints, return value).

**Test scenarios:**
- Happy path: ledger with 5 entries tagged `pricing`, 3 tagged `staffing`, 1 tagged `random` → returns `[("pricing", 5), ("staffing", 3)]`. `random` excluded (below threshold).
- Happy path with attendee filter: same ledger but two `pricing` entries don't include Alice → `find_patterns(attendees=["alice@acme.com"])` returns `pricing: 3` (only Alice-touching entries counted).
- Edge case: empty ledger → returns `[]`.
- Edge case: all topics below threshold → returns `[]`.
- Edge case: window_days=0 → returns `[]` (window excludes everything).
- Edge case: `limit=1` cap — even with 4 patterns above threshold, returns only the top 1.
- Edge case: tie on count — alphabetical order on the tied topics so output is deterministic.

**Verification:**
- The smoke test (U5) runs find_patterns against a fixture ledger and asserts every scenario above.

---

- U2. **Ledger dedup: cleanup script + dedup-on-write**

**Goal:** Two parts: (a) a one-time cleanup script `scripts/dedup_ledger.py` that finds and removes near-duplicate commitments from the existing production ledger, and (b) a dedup-on-write guard inside `briefings_mcp.ledger.append` so future writes don't reintroduce duplicates.

**Requirements:** R5, R6

**Dependencies:** None

**Files:**
- Create: `scripts/dedup_ledger.py`
- Modify: `briefings_mcp/ledger.py`
- Test: smoke coverage in `scripts/smoke_test_u4p4.py` (U5)

**Approach:**

*Dedup-on-write in ledger.append (a small change):*
- Before validation + write, scan recent entries for the same `source_meeting`. "Recent" = last 50 entries via a reverse iteration cap (avoid scanning the whole file on every write).
- For each candidate, check: same `source_meeting` AND `type == "commitment"` AND (`summary == new.summary` OR first 60 chars of summary match). If found, return without writing (silent skip).
- Decisions and the first entry for a meeting are never skipped.
- Document the new behaviour in the module docstring.

*Cleanup script:*
- Read the entire ledger via `ledger.iter_entries()` (no since-filter).
- Group entries by `source_meeting` + `type == "commitment"`. Within each group, find clusters by exact-summary or first-60-char-prefix match.
- For each cluster with size > 1: pick the survivor (earliest `created_at`, tiebroken by most-recent state: `done`/`dropped` > `in-flight` > `open`). Mark the rest for removal.
- Dry-run by default: print a summary of clusters and survivors, exit without writing.
- `--apply` flag: rewrite the ledger atomically via tmp file + os.replace, omitting marked entries. Update the SQLite index by calling `briefings_mcp.index.reset_cache()` and triggering a re-index on next MCP read.

**Patterns to follow:**
- `briefings_mcp/ledger.update_commitment_state` (Phase 3) — same atomic-rewrite pattern (tmp file + os.replace).
- `scripts/smoke_test_u3p3.py` — script structure, PASS/FAIL output, exit codes.

**Test scenarios for dedup-on-write:**
- Happy path: append a commitment, then append an identical one → second append is skipped; ledger has 1 entry.
- Happy path: append a commitment with summary "Send pricing memo to Acme Corp"; then append "Send pricing memo to Acme Corporation today" → first 60 chars don't match → both written.
- Edge case: same meeting, different commitments — both written (different summaries).
- Edge case: same summary, different meeting — both written (source_meeting differs).
- Edge case: decision entries — same source_meeting + same summary still both written (dedup is commitment-only).
- Edge case: empty ledger — first append always writes regardless.

**Test scenarios for cleanup script:**
- Happy path: seed ledger with 1 unique + 2 duplicate clusters → dry-run lists 2 clusters with 2 and 3 entries each, identifies survivors → `--apply` reduces the ledger to 3 entries total (1 + 1 + 1 survivors).
- Edge case: no duplicates → "No duplicates found" message, exit 0, ledger byte-identical.
- Edge case: cluster where one entry has `state: "done"` and the rest are `open` → survivor is the done one (more recent state wins regardless of created_at).
- Edge case: cluster where multiple entries share the most-recent state → tiebreak by earliest created_at.
- Edge case: --apply on empty ledger → no-op, exit 0.

**Verification:**
- The smoke test (U5) covers dedup-on-write.
- `python3 scripts/dedup_ledger.py` (dry-run) against the production ledger prints the existing Robert and Elizabeth dup clusters; `--apply` removes them.

---

- U3. **Pattern flags in /briefing SITREP block**

**Goal:** /briefing's SITREP block grows a new `Patterns:` line after `Counterparty:`. The line shows 1–3 topic tags this meeting's attendees keep raising across recent meetings.

**Requirements:** R2

**Dependencies:** U1

**Files:**
- Modify: `commands/briefing.md`

**Approach:**
- In whichever Step assembles the SITREP block (likely Step 4 or 5 of briefing.md — check during implementation), add a call to `briefings_mcp.query.find_patterns` filtered by the current meeting's attendees.
- Render only if `find_patterns` returns ≥1 result.
- Format: `**Patterns:** <topic1> (<n>), <topic2> (<m>), <topic3> (<k>)` — comma-separated, with the count in parentheses. e.g. `**Patterns:** pricing (5), staffing (3), q3-plan (3)`.
- The label "Patterns:" is the bare convention; matching the existing SITREP labels (Trap/Delta/Comment/Counterparty all use that format).
- Place it directly after the `Counterparty:` line (which is conditional itself; if Counterparty is omitted, Patterns slots in after Comment).
- Update the SITREP closed-set documentation in commands/briefing.md (if any) to reflect the new label.

**Patterns to follow:**
- Existing SITREP label rendering in commands/briefing.md.
- Phase 1's "Counterparty:" conditional rendering pattern.

**Test scenarios:**
- Happy path: a briefing for a meeting with Robert as the external attendee — Robert appears in 4 prior pricing-tagged entries → Patterns line shows `pricing (4)`.
- Edge case: meeting attendees have no recurring topics in last 60 days → Patterns line omitted entirely.
- Edge case: only 1 pattern found → renders one topic, no comma.
- Edge case: more than 3 patterns found → only top 3 shown.

**Verification:**
- Force-regenerate a briefing for a meeting whose attendee has prior ledger entries. The Patterns line appears with at least one topic.

---

- U4. **Pattern flags in /follow-up + /digest**

**Goal:** /follow-up gets a `## Pattern flags` section showing patterns this meeting reinforced; /digest gets a one-line global summary at the top.

**Requirements:** R3, R4

**Dependencies:** U1

**Files:**
- Modify: `commands/follow-up.md`
- Modify: `commands/digest.md`

**Approach:**

*/follow-up:*
- After Step 4's ledger append, call `find_patterns` filtered by THIS meeting's topics (the ones just appended). Pattern hits mean: this meeting's topic recurs in prior entries.
- Insert `## Pattern flags` section in Step 5 template between `## Counterparty read` and `## Source`. Format:
  ```
  ## Pattern flags
  - **pricing** has come up in 5 prior meetings — likely worth a focused discussion
  - **staffing** has come up in 3 prior meetings
  ```
- Render only when `find_patterns` returns ≥1 result for this meeting's topics. Omit-when-empty.

*/digest:*
- After Step 1's commitments fetch, call `find_patterns()` with no attendee filter (global window).
- Insert a one-line summary between the date heading (`**<Day>, ...**`) and `## Yours`:
  ```
  *Period themes: pricing (8), staffing (5), q3-plan (4)*
  ```
- Use italic prose, not a heading — it's contextual scene-setting, not a section.
- Omit when no patterns above threshold.

**Patterns to follow:**
- Phase 1's omit-when-empty convention.
- Phase 3's digest template for /digest insertion point.

**Test scenarios:**
- Happy path /follow-up: meeting with topic "pricing"; ledger has 4 prior pricing entries → Pattern flags section renders with pricing line.
- Happy path /digest: ledger has multiple recurring topics → one-line summary at the top with top 3.
- Edge case /follow-up: meeting topics don't match any pattern → section omitted.
- Edge case /digest: empty-ish ledger (no topics above threshold) → no summary line, digest renders as before.
- Edge case both: same topic appears in /follow-up's Pattern flags AND /digest's top line; that's expected — different surfaces, same underlying data.

**Verification:**
- Force-regenerate a follow-up and a digest after Phase 4 ships. Both surface pattern flags from the user's real ledger.

---

- U5. **smoke_test_u4p4.py + verify-v1.sh section + README**

**Goal:** Add automated coverage for find_patterns and dedup-on-write to the smoke test harness, and document everything in the README.

**Requirements:** R7, R8

**Dependencies:** U1, U2

**Files:**
- Create: `scripts/smoke_test_u4p4.py`
- Modify: `scripts/verify-v1.sh`
- Modify: `README.md`

**Approach:**

*scripts/smoke_test_u4p4.py:*
- Same structure as `scripts/smoke_test_u3p3.py` — temp dir, redirect LEDGER_PATH, PASS/FAIL checks, exit codes.
- Cover the test scenarios listed in U1 (find_patterns) and U2's "dedup-on-write" half.
- Cleanup script tests (U2's "--apply" tests) go in a separate temp-dir block within the same file so the dedup_ledger.py script gets exercised too.

*scripts/verify-v1.sh:*
- Add a new automated section (section 8 — after Phase 3's section 7 U3p3 smoke). Same shape as the existing smoke sections.
- Renumber the manual sections (current 8 briefing → 9, 9 follow-up → 10, 10 digest → 11).
- Update flag-parsing help text if it mentions section numbers.

*README.md:*
- Add a new "Pattern flags" subsection under "Decision ledger and MCP server" (after the "Reply keywords" subsection added in Phase 2).
- Document: where patterns appear (briefing SITREP / follow-up section / digest top line), the threshold (3 entries within 60 days), the cap (top 3), and how to disable (no config switch — they're free; to suppress entirely, remove the find_patterns calls in the three commands).
- Add a separate subsection "Ledger dedup" documenting the dedup-on-write behaviour and the one-time cleanup script. Show the command: `python3 scripts/dedup_ledger.py` (dry-run) and `python3 scripts/dedup_ledger.py --apply` (commit).
- Update the layout block if a new file is created (`scripts/dedup_ledger.py`).

**Patterns to follow:**
- `scripts/smoke_test_u3p3.py` for the test file structure.
- Phase 1 and Phase 2's section-renumbering edits in `scripts/verify-v1.sh`.
- Phase 3's README updates for tone and prose-first style.

**Test scenarios:**
- `bash scripts/verify-v1.sh` runs the new section 8 successfully.
- README documents the new behaviours; a fresh reader can run dedup_ledger.py and understand pattern flags without source-reading.
- Test expectation: documentation reads correctly; smoke test passes 100%.

**Verification:**
- `bash scripts/verify-v1.sh` exits 0 with sequential section numbers 1–11.
- `python3 scripts/dedup_ledger.py` (dry-run) prints duplicate clusters from the production ledger.

---

## System-Wide Impact

- **Interaction graph:** Phase 4 changes are localised to one new query function, one ledger guard, one new script, three command-file edits, one new smoke test, and a verify-v1.sh + README update. No scheduler changes. No MCP tool changes.
- **Error propagation:** find_patterns is a pure read; failures (corrupt ledger lines) propagate as exceptions to the calling command, which logs and continues without pattern flags. Dedup-on-write fails open — if the dedup check fails for any reason, the append proceeds (safer to write a duplicate than to lose data).
- **State lifecycle risks:** The cleanup script is the only Phase 4 surface that mutates the ledger. Safe by default (dry-run); the atomic-rewrite pattern (tmp file + os.replace) matches Phase 3's update_commitment_state. SQLite index is invalidated on apply; rebuilt on next MCP read.
- **API surface parity:** find_patterns is in briefings_mcp.query alongside the existing functions but is NOT exposed via the MCP server (Phase 4 keeps the public MCP surface unchanged — pattern detection is /briefing, /follow-up, /digest implementation detail).
- **Integration coverage:** smoke_test_u4p4.py covers the new logic in isolation. Pattern surfacing in the three commands is exercised when those commands run (verify-v1.sh --with-briefing / --with-followup / --with-digest still pass).
- **Unchanged invariants:**
  - Briefing SITREP shape (verdict heading + Trap/Delta/Comment/Counterparty) stays — Patterns is additive.
  - /follow-up's existing sections all preserved; Pattern flags is new.
  - /digest's three sections (Yours / Owed / Nudge drafts) preserved; the period themes line is above them.
  - Ledger schema unchanged.
  - MCP tool surface unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Pattern flags become noise if the user's ledger has many low-quality topic tags. | The min_count=3 threshold filters out one-offs. The top-3 cap prevents wall-of-text. If the topic tags themselves are too noisy, the fix is in /follow-up's tag inference step (out of Phase 4 scope). |
| Dedup-on-write hides a genuine re-entry the user wants to track separately. | Conservative match (same source_meeting + summary or 60-char-prefix). Dedup never crosses meetings. The user can verify by re-running /follow-up --force and confirming the second invocation doesn't add new ledger entries. |
| The cleanup script destroys data if run with --apply on a ledger the user hasn't reviewed. | Dry-run is the default; --apply is explicit and prints the same cluster report before writing. The atomic-rewrite means a partial failure leaves the original ledger intact. |
| Pattern detection conflates "topic" with "tag" (a noisy substrate). | Acceptable for v1. Future work could add stemming / aliasing (e.g. `pricing` ≈ `prices` ≈ `cost`). Not Phase 4. |
| Performance — find_patterns scans the ledger every time a briefing/follow-up/digest runs. | Ledger is small (low hundreds of entries) and the scan is O(n) over a 60-day window. No optimization needed; if the ledger grows to tens of thousands, revisit with a topic-index column in SQLite. |
| The smoke test smoke_test_u4p4.py reuses LEDGER_PATH monkeypatching; if a parallel test mutates state, both fail. | Existing smoke tests already use this pattern (smoke_test_u3p3.py) without issue. Single-test execution in verify-v1.sh. |

---

## Documentation / Operational Notes

- After merge, `bash update.sh` propagates command file changes and refreshes the runtime venv (so `find_patterns` is importable).
- The cleanup script is NOT run automatically. To clean up the existing duplicates surfaced by Phase 3, run `python3 scripts/dedup_ledger.py` to see what would be removed, then `python3 scripts/dedup_ledger.py --apply` to commit.
- Pattern flags require ≥3 entries with matching topic tags within the last 60 days. A fresh ledger won't show patterns until enough entries accumulate.
- README updates cover the user-facing surface; no internal docs need rewriting.

---

## Sources & References

- Phase 1 plan: `docs/plans/2026-05-27-001-feat-followup-richness-upgrades-plan.md`
- Phase 2 plan: `docs/plans/2026-05-27-002-feat-followup-reply-keywords-plan.md`
- Phase 3 plan: `docs/plans/2026-05-27-003-feat-actions-tracker-digest-plan.md`
- Ledger module: `briefings_mcp/ledger.py`
- Query module: `briefings_mcp/query.py`
- Live duplicate evidence: Phase 3 validation digest at `~/Briefings/2026-05-27-1000-digest.md` (Owed-to-you items 11/14/19 are the same Robert commitment; 13/16/18 are the same Elizabeth commitment).
