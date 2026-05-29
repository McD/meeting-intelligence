---
title: "feat: Enforce commitments-only via calendar tag + extraction audit log"
type: feat
status: active
date: 2026-05-29
origin: docs/brainstorms/2026-05-29-actions-tracker-commitments-only-requirements.md
---

# feat: Enforce commitments-only via calendar tag + extraction audit log

## Summary

Implements R4 (calendar-tag short-circuit for coaching/debrief/therapy meetings) and R8 (per-meeting audit log of four-gate decisions) from the requirements doc. Both changes live in `commands/follow-up.md`; no Python modules change. The KD3 escalation post-processor is deliberately deferred until SC4 or SC5 actually fails.

---

## Requirements

- R1. **Calendar-tag enforcement of R4.** When the calendar event title contains `[coaching]`, `[debrief]`, `[1:1-introspective]`, or `[therapy]`, `/follow-up` Step 3 captures zero action items. Decisions, summary, and transcript extraction proceed normally — only commitments are suppressed.
- R2. **Explicit override.** When the calendar event title additionally contains `[capture-actions]`, normal action-item extraction runs. Lets the user keep one real action surfaced from an otherwise coaching-shaped meeting.
- R3. **Per-meeting audit log for the four gates.** Every `/follow-up` run emits one JSON Lines record per candidate evaluated against the gates, to `~/Briefings/YYYY-MM-DD-HHmm-followup-audit.jsonl` (mode 600). Record shape: `{timestamp, source_meeting, candidate_summary, kept (bool), gate_dropped (null or 1-4), reason (string)}`.
- R4. **Audit log feeds SC4/SC5 evaluation.** The JSONL files are the data feed for the 14-day validation (SC4) and the rolling 4-week ratio (SC5) in the requirements doc. This plan does not include automation for those queries — `grep` / `jq` against the audit files is sufficient until usage shows the cost.

*Origin trace:* R1 carries origin R4 (capture rules → coaching default). R2 is a refinement implied by origin R4's "if the user wants exceptions inside a tagged meeting" clause. R3 carries origin R8 (observability). R4 carries origin SC4/SC5 (success criteria).

---

## Scope Boundaries

- No KD3 escalation post-processor in `briefings_mcp/schema.py` — that fires only when SC4 or SC5 actually fails. Speculative work until then.
- No decisions-type extraction audit (the unverified-assumption flag in origin Dependencies). Defer until briefing surfaces show noise.
- No automated SC4/SC5 ratio-computation script. Manual `grep` / `jq` against the JSONL audit logs is sufficient.
- No backfill of historical follow-ups to re-extract under the new gates — explicit non-goal in origin Scope Boundaries.
- No changes to the `decision` entry type or how briefings consume it.
- No changes to `commands/digest.md` — the existing reply keywords (`drop`, `not-mine`, `drop-owed`, `done-owed`) plus the digest filter for `owner in ("", "unassigned")` already provide the recovery surface required by origin R9 and R10.

---

## Context & Research

### Relevant Code and Patterns

- `commands/follow-up.md` Step 1 (line ~360) — already reads `gws calendar events` and extracts the matching event's title. Calendar-tag detection extends this step with a simple substring check.
- `commands/follow-up.md` Step 3 (line ~469) — current four-gate filter prose (gates 1-4 enumerated in lines ~481-491). The short-circuit branches off the top of Step 3; the audit log emits per-candidate inside Step 3.
- `briefings_mcp/ledger.py` `_restricted_umask` context manager + `chmod 600` after write (lines 39-48, 189-196) — established pattern for writing mode-600 files via Python from `commands/follow-up.md` heredocs.
- `scripts/scheduler.sh` `log()` function (line 28) — the existing logging pattern for non-audit log lines (cycle start, ERROR, WARN). The per-meeting audit JSONL is separate from `scheduler.log` to keep `scheduler.log`'s 500KB rotation policy clean.
- `scripts/scheduler.sh` 30-day cleanup gate (lines 43-47) — the existing sweep that removes old files from `~/Briefings/`. **Note: the cleanup uses `-name "*.md"` and does NOT match `*.jsonl` files** — see Risks & Dependencies.

### Institutional Learnings

- **State-file rewrites use atomic tmp+rename** (`briefings_mcp/ledger.py:189-196`). The audit log uses append-only writes (no rewrite), so the simpler `open(..., "a")` + `fsync` pattern applies — no tmp file needed.
- **Escalate slash-command prose to code for security/correctness guards** (Mark's feedback memory). KD3's prose-only enforcement is the next candidate for that escalation when SC4/SC5 trigger.

### External References

- None. The work is entirely codebase-local.

---

## Key Technical Decisions

- **Audit log goes to a per-meeting file, not `scheduler.log`.** Keeps `scheduler.log`'s 500KB rotation policy simple, makes the audit feed grep-able per meeting (`cat 2026-05-29-1100-followup-audit.jsonl | jq`), and matches the existing per-meeting `*-followup-*.md` and `*-awaiting-reply-*.md` naming convention.
- **`COACHING_MODE` is a shell variable, not a state file.** Step 1 sets it; Step 3 reads it; nothing else needs it. Persisting it to a file would be over-engineering for a single-cycle flag.
- **The short-circuit fires inside Step 3, not before it.** Steps 1 and 2 run unchanged (calendar fetch, transcript discovery); the user still gets a follow-up email with decisions + summary even from a coaching meeting. Only commitment extraction is suppressed. This preserves transcript-side value (research, expand replies) without polluting the actions tracker.
- **In coaching mode, the audit log emits a single per-meeting record, not per-candidate.** Matches U1's "skip extraction entirely" semantics — the LLM doesn't enumerate candidates, so there's nothing to write per-item. SC5's rolling ratio treats the presence of a `reason: "coaching-mode-short-circuit"` record as "policy-suppressed entire meeting" rather than per-candidate suppression. This was a doc-review-surfaced ambiguity between U1's "skip" and U2's "enumerate even when suppressed" — resolved by deferring to U1's simpler semantics.
- **`gate_dropped` is `null` when an item is kept, `1-4` when dropped by a specific gate.** Lets a downstream query distinguish "kept" from "dropped at gate N" in one field rather than two booleans.
- **Audit files at mode 600 is deliberate hardening, not cargo-cult.** Audit records contain transcript-derived candidate summaries that may include strategic / personal content (e.g., a coaching session's verbatim stance language, or a pre-meeting positioning note that didn't reach the deliverable threshold). Mode 600 matches `~/.briefings/decisions.jsonl` and follows the same threat model: a multi-user machine should not expose the user's working notes to other accounts.
- **`SOURCE_MEETING` is hoisted to Step 1, not recomputed per step.** Step 1's dedup check at lines 374-375 already constructs the slug; hoisting it into a shell variable gives Steps 3 (audit log) and 4 (ledger append) a single source of truth. Recomputing in Step 3 would re-derive the same value via a slightly different path and create a regression vector.

---

## Implementation Units

- U1. **Calendar-tag short-circuit for R4 enforcement + `SOURCE_MEETING` hoist**

  **Goal:** When the calendar event title contains a meeting-class tag (`[coaching]`, `[debrief]`, `[1:1-introspective]`, `[therapy]`), `/follow-up` Step 3 captures zero commitments unless the override tag `[capture-actions]` is also present. Also hoist the per-meeting slug into a `SOURCE_MEETING` shell variable established in Step 1, so Steps 3 (audit log) and 4 (ledger append) share a single source of truth.

  **Requirements:** R1, R2 (this plan); origin R4.

  **Dependencies:** None.

  **Files:**
  - Modify: `commands/follow-up.md` Step 1 (hoist `SOURCE_MEETING=$(date +%Y-%m-%d)-$(meeting-time)-followup-<slug>` from its current site in Step 4's heredoc; add tag-detection prose); Step 3 (read both `SOURCE_MEETING` and `COACHING_MODE`, short-circuit when coaching is set); Step 4 (use the hoisted `SOURCE_MEETING` rather than recomputing).

  **Approach:**
  - Step 1 already constructs the meeting slug for its dedup check at lines 374-375 (`ls ~/Briefings/YYYY-MM-DD-HHmm-followup-SLUG.md`). Hoist that slug into a `SOURCE_MEETING` shell variable so it's reachable from Steps 3 and 4. Single source of truth, no recomputation.
  - Step 1 also extracts the calendar event title for each recently-ended meeting. Add prose: parse the title for any of the meeting-class tags; if present AND `[capture-actions]` is *not* also present, set `COACHING_MODE=1` for that meeting's processing scope. Otherwise leave it unset.
  - Step 3 reads `COACHING_MODE` at the top. When set, skip the action-items extraction entirely (gates 1-4 do not run) and emit **one single audit record** to the audit JSONL — not one record per candidate — with the shape `{kept: false, gate_dropped: null, reason: "coaching-mode-short-circuit", candidate_summary: "<all candidates suppressed by policy>"}`. The LLM does not enumerate candidates in coaching mode; this matches U1's "skip extraction" semantics cleanly. Decisions, summary, key topics, and Notable threads still extract normally.
  - Tag matching is case-insensitive and substring-based — `[Coaching]`, `[ coaching ]`, and `[coaching]` all match. Trailing/leading whitespace tolerated.

  **Patterns to follow:**
  - The existing calendar-data extraction in Step 1 + the `is_external` boolean derivation in Step 4 (line ~518) — same pattern: derive a per-meeting boolean from the event metadata, carry it through subsequent steps.

  **Test scenarios:**
  - *Happy path* — A `/follow-up` regenerate against a calendar event titled `[coaching] 1:1 with Mark and Tim` produces zero new commitments in `~/.briefings/decisions.jsonl` for that meeting. The follow-up `.md` file still renders with summary + decisions + transcript link.
  - *Override* — Title `[coaching] [capture-actions] 1:1 with Mark and Tim` extracts commitments normally (the override beats the meeting-class tag).
  - *Untagged* — Title `1:1 with Mark and Cédric` (no tag) runs the normal four-gate filter — no change from current behavior.
  - *Case + whitespace* — Title `[ Coaching ] Strategy chat` triggers the short-circuit (case-insensitive, whitespace tolerated).
  - *Multiple tags* — Title `[debrief] [coaching] Retro` triggers the short-circuit (any one of the four class tags is sufficient).
  - *Integration* — The decisions section still appears in the follow-up email for a tagged meeting if the transcript actually contains a decision. Verifies that only commitment extraction is suppressed, not the rest of Step 3.

  **Verification:**
  - Add a `[coaching]` tag to one of today's existing calendar events, force-regen the follow-up via the existing `verify-v1.sh --with-followup` path, and confirm the resulting `decisions.jsonl` appends zero commitment entries for that meeting and the audit JSONL contains one line with `reason: "coaching-mode-short-circuit"`.

---

- U2. **Per-meeting four-gate audit log for SC4/SC5 evaluation + `.jsonl` cleanup hook**

  **Goal:** Every `/follow-up` run emits one JSON Lines record per candidate evaluated against the four gates, to a per-meeting audit file. Output is the data feed for SC4 (14-day validation) and SC5 (rolling 4-week ratio). The `scripts/scheduler.sh` 30-day cleanup is also extended to sweep `.jsonl` audit files, so they don't accumulate indefinitely.

  **Requirements:** R3, R4 (this plan); origin R8.

  **Dependencies:** U1 (uses the hoisted `SOURCE_MEETING` variable; coaching-mode short-circuit emits exactly one record per the U1 spec, not per-candidate).

  **Files:**
  - Modify: `commands/follow-up.md` Step 3 (add audit-log emission after each candidate is evaluated against gates 1-4)
  - Modify: `scripts/scheduler.sh` (add a second `find` invocation in the existing 30-day cleanup block at lines 43-47, filtered to `-name '*-audit.jsonl'`, so audit files sweep on the same cadence as the `.md` files)

  **Approach:**
  - At the top of Step 3, derive the audit-file path: `~/Briefings/${SOURCE_MEETING}-audit.jsonl`. `SOURCE_MEETING` is hoisted to Step 1 by U1; Step 3 just reads it.
  - For each candidate the LLM identifies as a potential commitment **in non-coaching mode**, before deciding to append-or-drop, emit a JSONL record: `{"timestamp": "<ISO>", "source_meeting": "<slug>", "candidate_summary": "<140-char truncated>", "kept": <bool>, "gate_dropped": <1|2|3|4|null>, "reason": "<short>"}`.
  - In coaching mode (U1's `COACHING_MODE=1` short-circuit), emit exactly one record per the U1 spec — not per-candidate. The audit file for a coaching-tagged meeting contains a single line confirming the short-circuit ran. SC5's rolling ratio interprets the presence of a coaching-mode record as "policy-suppressed entire meeting" rather than per-candidate suppression. This is the explicit trade-off per Finding-resolution in this round's doc review.
  - Write via the existing Python heredoc pattern in Step 3/4. Use `_restricted_umask()` from `briefings_mcp.ledger` so the file lands at mode 600 (deliberate hardening — audit files contain transcript-derived candidate summaries that may include sensitive content); subsequent writes append. The file is created on first write within a meeting's processing; multiple runs against the same meeting append rather than truncate.
  - When a candidate is kept, emit `{"kept": true, "gate_dropped": null, "reason": "passed-all-gates"}`. When dropped at gate N, emit `{"kept": false, "gate_dropped": N, "reason": "<gate-name>"}` where gate-name is one of `concrete-doer`, `done-state`, `deliverable-or-decision-or-interaction`, `worth-chasing-for-user`.
  - In `scripts/scheduler.sh` lines 43-47, add a second `find` call alongside the existing `*.md` sweep: `find "$BRIEFING_DIR" -name "*-audit.jsonl" -mtime +30 -delete`. Same 30-day window, same `-delete` semantics — audit files sweep on the same cadence as briefings and follow-ups.

  **Patterns to follow:**
  - The Python heredoc pattern in `commands/follow-up.md` Step 4 (line ~498) — same `os.environ` + `from briefings_mcp import ledger` import shape.
  - `briefings_mcp/ledger.py:39-48` (`_restricted_umask`) — the mode-600 file-write pattern.

  **Test scenarios:**
  - *Happy path* — Force-regen a follow-up against an untagged meeting; confirm a `~/Briefings/<slug>-audit.jsonl` file exists at mode 600 with one line per candidate evaluated. Each line is valid JSON.
  - *Dropped at gate* — For a transcript known to contain a stance-shaped item, confirm the audit record for that item has `kept: false, gate_dropped: 3, reason: "deliverable-or-decision-or-interaction"`.
  - *Kept item* — A clean action-shaped item gets `kept: true, gate_dropped: null, reason: "passed-all-gates"`.
  - *Coaching short-circuit (integration with U1)* — A `[coaching]`-tagged meeting produces an audit file containing exactly **one** line: `{kept: false, gate_dropped: null, reason: "coaching-mode-short-circuit", candidate_summary: "<all candidates suppressed by policy>"}`. No per-candidate enumeration in coaching mode.
  - *Append on re-run* — Force-regen the same untagged meeting twice; confirm the audit file contains records from both runs (no truncation). Each line has a distinct `timestamp`.
  - *File mode* — `stat -f '%Lp' ~/Briefings/<slug>-audit.jsonl` returns `600`.
  - *Cleanup* — After 30 days, the audit file is swept by `scripts/scheduler.sh`'s extended cleanup. Verify by touching an audit file with `touch -t 202604010000 ~/Briefings/test-audit.jsonl`, running a scheduler cycle, and confirming the file is gone.

  **Verification:**
  - After `verify-v1.sh --with-followup`, the audit file exists, is mode 600, contains at least one valid JSONL record per candidate, and the candidates' `kept` / `gate_dropped` values match the rendered follow-up's action-items list (kept items appear; dropped items don't).
  - A one-line `jq` query against the file returns sensible counts: `jq -s 'group_by(.kept) | map({kept: .[0].kept, n: length})' <audit.jsonl>` returns `{kept: true, n: K}` and `{kept: false, n: M}` matching the user's read of the follow-up.

---

## Open Questions

### Resolved During Planning

- **Q: Where does the calendar-tag short-circuit fire — Step 1 or Step 3?** A: Step 1 detects and sets `COACHING_MODE`; Step 3 reads the flag and short-circuits action-item extraction. Decisions, summary, and transcript still extract normally.
- **Q: Where does the audit log live — appended to `scheduler.log` or a separate file?** A: Per-meeting JSONL file at `~/Briefings/<slug>-audit.jsonl`. Keeps `scheduler.log`'s 500KB rotation simple; makes per-meeting `jq` queries trivial.
- **Q: How are SC4 and SC5 computed?** A: Manually via `jq` or `grep` against the audit files in this plan's scope. Automated tripwires are future work — only built if manual checking becomes burdensome.

### Deferred to Implementation

- **Exact Python heredoc shape for the audit-log writer.** Match the existing pattern in Step 3/4 (`os.environ` + import `briefings_mcp.ledger`) at implementation time; the precise variable names will be obvious once `commands/follow-up.md` is open.
- **Whether to also include the candidate's `attendees` array in the audit record.** Out of scope as defined; revisit only if SC4/SC5 evaluation needs attendee-level filtering.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Audit JSONL files accumulate over time and bloat `~/Briefings/` | U2 extends `scripts/scheduler.sh` lines 43-47 with a second `find` invocation filtered to `-name '*-audit.jsonl'`, so audit files sweep on the same 30-day cadence as the existing `.md` files. The `-name "*.md"`-only cleanup gap that the original plan assumed was already closed is closed by U2 explicitly. |
| Calendar tag collision with normal meeting titles (e.g., a meeting literally titled "Coaching session for new hires" without intent to suppress) | Tag detection requires the `[brackets]` form. Plain prose like "Coaching session" is ignored. If a future regression slips through, fix is one prose line in Step 1. |
| Per-candidate audit emission requires the LLM to faithfully report each item it considered before gates ran, not just the items it kept. There is no mechanism to verify the LLM didn't silently skip emitting an audit record for a candidate it dropped | SC4/SC5 will under-count gate drops if the LLM compresses its enumeration. Mitigation: phrase the audit-emission prose in Step 3 to emphasize completeness ("for every candidate you considered, even those you decided not to capture") and treat any drift visible in `jq` counts as a signal to migrate the audit emission from prose to a deterministic post-processor — same escalation shape as origin KD3 for the gates themselves. |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-29-actions-tracker-commitments-only-requirements.md](docs/brainstorms/2026-05-29-actions-tracker-commitments-only-requirements.md)
- Related code: `commands/follow-up.md` (Steps 1, 3, 4), `briefings_mcp/ledger.py:39-48` (mode-600 write pattern), `scripts/scheduler.sh:28,42` (logging + cleanup patterns)
- Related prior plans: [docs/plans/2026-05-27-004-feat-pattern-flags-ledger-dedup-plan.md](docs/plans/2026-05-27-004-feat-pattern-flags-ledger-dedup-plan.md) — the most recent four-gate-related plan; this plan extends the noise-prevention work started there.
