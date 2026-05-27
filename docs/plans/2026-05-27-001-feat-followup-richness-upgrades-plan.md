---
title: "feat: Follow-up richness upgrades (Phase 1)"
type: feat
status: active
date: 2026-05-27
---

# feat: Follow-up richness upgrades (Phase 1)

## Summary

Layer four new sections onto the existing `/follow-up` output (Notable threads, Source link, Counterparty read, inline confidence callouts) and harden the already-shipping Open questions section. The punchy summary plus action items plus decisions stay at the top untouched; everything new lands below them. All edits live in `commands/follow-up.md` (Steps 3 and 5) with one optional extension to `scripts/verify-v1.sh` so the new follow-up shape gets the same smoke-test treatment as briefings.

---

## Problem Frame

The current follow-up email and Slack message are tight and action-oriented, which is the strength. The cost is that the texture of the discussion is lost. Interesting framings, soft commitments, the offhand insight worth remembering, the unresolved threads, what the other side actually cared about — none of that survives into the artifact. Users either go back to the raw transcript (high friction) or lose the context entirely (more common). Phase 1 closes that gap without disturbing the punchy top of the email.

---

## Requirements

- R1. Add a `## Notable threads` section below Action items that captures 3 to 5 interesting framings, analogies, "X said Y about Z" moments, or soft commitments.
- R2. Add a `## Source` line with a clickable link to the transcript (Gemini doc, Teams recap email, MacWhisper file path) and to the calendar event.
- R3. Ensure `## Open questions` appears reliably whenever the transcript contains unresolved items. Tighten the extraction prompt so it does not silently drop them.
- R4. Add a `## Counterparty read` section for external and mixed meetings only: one or two lines on what the other side seemed to care about most, separate from agreed actions. Skip on internal meetings.
- R5. Mark inline confidence on action items where Claude is unsure of owner or scope. Prefer explicit uncertainty (`owner?`, `scope?`) over silent guessing.
- R6. Keep the punchy top (Summary, Action items, Key decisions) at the top of the artifact and unchanged in shape.
- R7. New sections must render correctly in both email (HTML) and Slack (mrkdwn) without renderer changes. Markdown-driven render in Step 6 should pass through standard sections.
- R8. Extend `scripts/verify-v1.sh` with a `--with-followup` flag that force-regenerates the most recent follow-up and asserts the new shape.

---

## Scope Boundaries

- Phase 1 only touches `/follow-up`. No changes to `/briefing`, the scheduler, the ledger, or the MCP server.
- No schema changes to `~/.briefings/decisions.jsonl`. Ledger schema work is Phase 3.
- No new reply-keyword handlers (`expand:`, `quote:`, status updates) — those are Phase 2 and Phase 3.
- The "Why?" capture flow stays in place for now. Removal is Phase 2.
- No pattern-flag content (cross-meeting echoes from the ledger). That is Phase 4.

### Deferred to Follow-Up Work

- **Phase 2:** Remove "Why?" capture, add `expand:` and `quote:` reply keywords. Separate PR.
- **Phase 3:** Actions tracker digest (Mon and Thu at 10am), status update keywords, smart pre-marking. Separate PR.
- **Phase 4:** Pattern flags drawn from the ledger. Separate PR.

---

## Context & Research

### Relevant Code and Patterns

- `commands/follow-up.md` Step 3 (lines ~256–264) — current extract targets (`Summary`, `Key decisions`, `Action items`, `Open questions`). Notable threads, Source, Counterparty, confidence flags get added here.
- `commands/follow-up.md` Step 5 (lines ~350–384) — current template. New sections insert below Action items / Key decisions, above the existing `## Why?` block.
- `commands/follow-up.md` Step 4 (lines ~280–284) — `is_external` is already computed for the high-stakes flag (any attendee outside `$COMPANY_DOMAIN`). Reuse this for the Counterparty read conditional rather than re-deriving.
- `commands/follow-up.md` Step 2 (lines ~178–210) — five-source transcript search. Capture the source URL or path at the moment the transcript is located, surface in Step 5.
- `commands/follow-up.md` Step 6 (lines ~388–464) — markdown-to-HTML and markdown-to-mrkdwn renderers. Standard headings and lists pass through; no renderer changes needed.
- `scripts/verify-v1.sh` lines ~287–379 — existing SITREP shape assertion for briefings under `--with-briefing`. Mirror this pattern for `--with-followup`.
- `~/Briefings/2026-05-27-1000-followup-sc-external-positioning-dss-debrief.md` — current production output, useful as before-shape reference.

### Institutional Learnings

- The follow-up command is **installed copies live at `~/.claude/commands/follow-up.md`** and do not auto-sync from the repo. After editing `commands/follow-up.md`, `bash update.sh` propagates the change. Per user-memory: scheduler-headless Claude reads the installed copy.
- v1 already established the convention that empty sections are omitted (Step 5 line 371: "Skip any section that has no content"). Inherit this for Notable threads, Counterparty read, and Source — only render when populated.

### External References

None required for this plan. All work is content/template-level and well-bounded by the existing command structure.

---

## Key Technical Decisions

- **Reuse `is_external` from Step 4 for the Counterparty conditional.** Already computed for the high-stakes flag. Avoids re-walking the attendees array.
- **Source link is best-effort, not blocking.** If Step 2 found the transcript via MacWhisper (local `.txt`), the "link" is a `file://` path that only works on the same machine. Render it anyway; it is useful in the email-on-laptop case and harmless in the Slack-on-phone case.
- **Confidence marks are inline, not a separate section.** Format: `[ ] **You?** — send the pricing memo` for an unclear owner, or `[ ] **You** — follow up with Acme *(scope?)*` for an unclear scope. Keeps the punchy top punchy while flagging uncertainty.
- **Notable threads is bounded to 3–5 bullets.** Anything more becomes a transcript dump, defeating the purpose of summarisation. The prompt enforces the ceiling.
- **No new conditional rendering logic in Step 6.** All conditionality lives in Step 3 and Step 5 (whether the section is written into the markdown file at all). Step 6 renders whatever it finds.

---

## Open Questions

### Resolved During Planning

- *What anchors the Source link when only a MacWhisper file is found?* Use `file://<absolute path>`; useful on the laptop, harmless elsewhere.
- *Where do confidence marks visually live?* Inline on the action item bullet itself, using `?` suffix on owner or `*(scope?)*` italic tail on the action.
- *Do new sections need renderer changes in Step 6?* No. Confirmed by reading Steps 388–464; both HTML and Slack renderers handle arbitrary `## Heading` plus bullet/text content.

### Deferred to Implementation

- Exact wording of the Notable threads extraction prompt — needs tuning against a couple of real transcripts during U2 to make sure 3–5 bullets are genuinely interesting and not just a re-summary. First pass in the plan; tighten in implementation.
- Exact verify-v1.sh assertion strings for the follow-up shape (which labels are mandatory vs optional). Will mirror the SITREP assertion pattern once writing the test.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
Follow-up file shape after Phase 1 (omit-when-empty applies throughout):

  # Follow-up: <title>
  **<date | time | duration>**

  ## Summary
  <1–2 sentences>                              ← unchanged

  ## Action items                              ← unchanged shape, new confidence syntax
  - [ ] **You** — <action>
  - [ ] **You?** — <action with unclear owner>
  - [ ] **Alice** — <action> *(scope?)*

  ## Key decisions                             ← unchanged
  - <decision>

  ## Notable threads                           ← NEW (3–5 bullets max)
  - <interesting framing, analogy, soft commitment>

  ## Open questions                            ← already shipping, hardened
  - <unresolved item>

  ## Counterparty read                         ← NEW (external/mixed only)
  <1–2 line read on what the other side cared about>

  ## Source                                    ← NEW
  - Transcript: <link or file path>
  - Calendar: <event link>

  ## Why?                                      ← unchanged (Phase 2 removes)
  ...
```

---

## Implementation Units

- U1. **Capture source URL or path in Step 2**

**Goal:** When Step 2 locates a transcript, capture a reference to its origin (Gemini doc URL, Gmail message URL, MacWhisper file path) and pass it to Step 5.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- In each of Step 2's five branches (A–E), capture a `$TRANSCRIPT_SOURCE` variable next to the transcript text itself: Drive doc link, Gmail thread URL, or absolute `file://` path. Surface in Step 5 as a `## Source` section.
- Also capture the calendar event link (`htmlLink` field on the calendar event) for the same section.
- Omit `## Source` entirely if neither value is available (defence against transcript-text-only paths).

**Patterns to follow:**
- Step 0 already captures `thread_id` from `gws gmail +send` responses. Same pattern for `$TRANSCRIPT_SOURCE`.

**Test scenarios:**
- Happy path: meeting with a Gemini transcript gets `## Source` with a `docs.google.com` link to the Doc and a `calendar.google.com` link to the event.
- Edge case: MacWhisper-only meeting (no Drive doc) renders `## Source` with a `file://` path for the transcript and the calendar event URL.
- Edge case: transcript pasted via email reply (Step 0 transcript-request branch) — `$TRANSCRIPT_SOURCE` set to the Gmail thread URL of the reply, calendar link unchanged.
- Edge case: when no source can be inferred, the `## Source` section is omitted entirely (no empty heading).

**Verification:**
- A re-run of `/follow-up --force "<meeting name>"` against a meeting with a known Gemini transcript produces a `## Source` section in the file with both links present.

---

- U2. **Add Notable threads extraction and rendering**

**Goal:** Extract 3–5 bullets capturing texture from the meeting (framings, analogies, soft commitments, X-said-Y-about-Z moments) and render below Action items.

**Requirements:** R1, R7

**Dependencies:** None

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Extend Step 3's extract list to include `**Notable threads** — 3 to 5 bullets capturing interesting framings, analogies, soft commitments ("you said you'd think about Z"), or memorable moments. Skip generic recap content already covered by Summary.`
- The prompt should explicitly warn against re-summarising Action items or Key decisions.
- Insert `## Notable threads` in the Step 5 template immediately after `## Key decisions`.
- Empty-when-empty: omit the section if Claude returns nothing notable.

**Patterns to follow:**
- The existing extract list in Step 3 lines 256–264.
- The "skip if empty" convention in Step 5 line 371.

**Test scenarios:**
- Happy path: meeting transcript with a memorable analogy ("the legacy vendors are still selling 2010 hardware in 2026 packaging") surfaces it in Notable threads.
- Edge case: transcript with no standout texture (pure status update meeting) renders no Notable threads section.
- Edge case: ceiling — bullet count stays within 3–5 even for a 90-minute deep-dive.
- Edge case: no duplication of Action items or Key decisions content in Notable threads.

**Verification:**
- Force-regenerate a follow-up for the SC External Positioning DSS Debrief fixture (`2026-05-27-1000-followup-...`) and confirm at least three texture bullets that are not re-statements of decisions or actions.

---

- U3. **Harden Open questions extraction**

**Goal:** Make Open questions appear reliably whenever unresolved items exist. Tighten Step 3's prompt so questions raised-but-not-answered are not silently absorbed into Summary or Action items.

**Requirements:** R3

**Dependencies:** None

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Strengthen Step 3 line 262 wording from "Open questions — anything unresolved that needs a follow-up" to something explicit: "Open questions — any question raised in the meeting that did not get a definitive answer, or any topic flagged for later. Include questions that arose during decisions even if those decisions stand."
- Step 5 already renders `## Open questions` (line 367–368). No template change needed.

**Patterns to follow:**
- Existing extract-prompt voice in Step 3.

**Test scenarios:**
- Happy path: meeting where someone says "we'll come back to pricing next week" produces an Open questions bullet covering pricing.
- Edge case: a question that was answered does not appear in Open questions (e.g., "what's the launch date?" → "March 12" — answered, omit).
- Edge case: meeting with no open threads (decision meeting where everything resolved) renders no Open questions section.

**Verification:**
- Force-regenerate three recent follow-ups and confirm Open questions appears in at least one and is omitted (not empty-headinged) in any without unresolved items.

---

- U4. **Add Counterparty read for external and mixed meetings**

**Goal:** For external and mixed meetings only, add a 1–2 line read on what the counterparty (the people outside `$COMPANY_DOMAIN`) seemed to care about most.

**Requirements:** R4, R7

**Dependencies:** None (uses `is_external` already computed in Step 4)

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Extend Step 3's extract list with: `**Counterparty read** (only for external or mixed meetings) — one or two lines on what the people from outside ${COMPANY_DOMAIN} seemed to care about most, separate from agreed actions. Tone, emphasis, what they kept returning to.`
- The conditional lives in the prompt itself — Claude is told to compute it only when at least one attendee is external. As a safety net, Step 5 also checks `is_external` from Step 4 and skips the section if false (defence in depth — same pattern as the high-stakes filter).
- Insert `## Counterparty read` in the Step 5 template between Open questions and Source.

**Patterns to follow:**
- Step 4 already computes `is_external` for the high-stakes filter (lines ~280–284). Pass it forward into Step 5 the same way the high-stakes flag is.

**Test scenarios:**
- Happy path: external meeting with vendor renders `## Counterparty read` with a 1–2 line read on the vendor's emphasis.
- Edge case: internal-only meeting (all attendees `@COMPANY_DOMAIN`) does not render the section at all.
- Edge case: mixed meeting (some internal, some external) renders the section focused on the external attendees only.
- Edge case: external meeting where the counterparty said very little — section gracefully renders something honest like "Limited counterparty signal; meeting was largely a Mark monologue."

**Verification:**
- Force-regenerate a follow-up for one external meeting and one internal meeting from `~/Briefings/`. External produces the section, internal omits it.

---

- U5. **Inline confidence callouts on action items**

**Goal:** Let Claude mark uncertainty on action item owner or scope using a simple inline convention, rather than silently guessing.

**Requirements:** R5, R7

**Dependencies:** None

**Files:**
- Modify: `commands/follow-up.md`

**Approach:**
- Extend Step 3's Action items extract spec: action format becomes `[Person] — [what they need to do]` with two confidence conventions:
  - Unclear owner: `[Person?]` (e.g., `You?` or `Alice?`)
  - Unclear scope: append italic `*(scope?)*` to the action text
- Step 5's Action items template already uses `**Person**` rendering. The convention works naturally: `**You?**` for an unclear owner, `*(scope?)*` italic for unclear scope.
- The HTML renderer (Step 6) already preserves `**bold**` and `*italic*`. Slack mrkdwn renderer converts both. No renderer change needed.
- Crucially: the prompt should make clear that confidence callouts are for genuine uncertainty, not a hedge on every item.

**Patterns to follow:**
- Existing `[ ] **You** — action` formatting.

**Test scenarios:**
- Happy path: action where the transcript says "someone should follow up with Acme" (no name given) renders `[ ] **You?** — follow up with Acme` or `[ ] **Organiser?** — ...`
- Happy path: action where transcript says "Alice will look into pricing" (clear owner, clear ask) renders `[ ] **Alice** — look into pricing` with no `?` and no `*(scope?)*`.
- Edge case: action where scope is vague ("Mark to do something about the website") renders `[ ] **You** — handle the website *(scope?)*`.
- Edge case: no over-application — a meeting full of clear actions does not get peppered with `?` marks.

**Verification:**
- Force-regenerate a follow-up for a meeting known to have a vague action and confirm the confidence mark renders. Force-regenerate a clean meeting and confirm no spurious marks.

---

- U6. **Extend verify-v1.sh with --with-followup flag**

**Goal:** Add a `--with-followup` flag that force-regenerates the most recent follow-up and asserts the new shape (mandatory and conditional sections).

**Requirements:** R8

**Dependencies:** U1–U5 (asserts shapes those units produce)

**Files:**
- Modify: `scripts/verify-v1.sh`

**Approach:**
- Mirror the existing `--with-briefing` section (lines ~287–379). New `--with-followup` flag.
- Force-regenerate the most recent follow-up via `/follow-up --force "<meeting name>"`.
- Assert mandatory shape: `# Follow-up:`, `## Summary`, `## Action items`, `## Key decisions`. (Open questions, Notable threads, Counterparty read, Source are conditional.)
- Assert at least one of the new conditional sections appears (since most real meetings will have at least one).
- For external/mixed meetings, assert `## Counterparty read` appears.
- Mirror the briefing assertion pattern that uses `grep -qF` on label strings.

**Patterns to follow:**
- The `pass`/`info`/`section` helper functions already in `scripts/verify-v1.sh`.
- The SITREP shape assertion at lines ~349–369.

**Test scenarios:**
- Happy path: `bash scripts/verify-v1.sh --with-followup` passes against a freshly regenerated follow-up that exercises U1–U5.
- Edge case: a follow-up for an internal-only meeting passes the shape assertion (Counterparty read omitted, not asserted).
- Failure mode: if Step 3 prompt regresses and Notable threads stops appearing, the conditional assertion fails loudly.

**Verification:**
- `bash scripts/verify-v1.sh --with-followup` exits 0 on a regenerated production-meeting follow-up.

---

## System-Wide Impact

- **Interaction graph:** Phase 1 changes are localised to `commands/follow-up.md`. The slash command is consumed by two callers: the scheduler (headless) at `scripts/scheduler.sh`, and the user interactively via Claude Code. Both consume the same prompt; neither needs changes.
- **Error propagation:** New sections inherit the "omit when empty" pattern, so missing-extraction is silent failure (correct behaviour — the punchy top still ships). Step 6 delivery is unchanged.
- **State lifecycle risks:** None. No new state files, no ledger schema changes, no awaiting-state additions.
- **API surface parity:** The `briefings_mcp` MCP server reads the ledger, not the follow-up files; Phase 1 has no impact on it. The follow-up markdown is consumed by humans in email and Slack only.
- **Integration coverage:** U6 adds a smoke-test path. Combined with the existing `--with-briefing`, the verify script now exercises both directions of the system.
- **Unchanged invariants:**
  - Summary, Action items, Key decisions order and shape at the top of the artifact (R6).
  - Step 4 ledger-write behaviour and `decisions.jsonl` schema.
  - Why? section behaviour (unchanged until Phase 2 removes it).
  - Awaiting-why state file shape and the why-capture parser.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Notable threads becomes a vague re-summary of the meeting rather than texture-specific. | Prompt explicitly forbids restating decisions or actions; ceiling of 5 bullets enforces selectivity. Iterate prompt wording during U2 against real fixtures. |
| Counterparty read leaks across into internal meetings if the prompt-level conditional is missed. | Belt-and-braces: prompt tells Claude the condition AND Step 5 checks `is_external` before emitting the section. |
| Confidence callouts proliferate (Claude marks everything `?`). | Prompt frames callouts as exceptional, not default. U5 verification includes a "clean meeting" check that confirms no spurious marks. |
| `file://` source links break for users reading email on phone. | Acceptable: source link is best-effort; on laptop it works, on phone it's a visible cue that the source is local. |
| Update.sh propagation gap — edits to `commands/follow-up.md` are not active until the user re-runs `bash update.sh`. | Documented in user-memory; call out in the commit message and in `Verification` of U6. |
| Phase 1 sections push the email too long. | New sections are short by design (Notable threads ≤5 bullets, Counterparty read ≤2 lines, Source ≤2 links). Email length grows modestly; the punchy top is still scanable in preview. |

---

## Documentation / Operational Notes

- After merging, run `bash update.sh` to propagate `commands/follow-up.md` to `~/.claude/commands/follow-up.md`. The headless scheduler reads the installed copy.
- Run `bash scripts/verify-v1.sh --with-followup` once after install to confirm the new shape end-to-end.
- README `What you get` and `Layout` sections do not need changes for Phase 1; the artifact's spirit ("automated pre-meeting briefings and post-meeting follow-ups") is unchanged.
- No env var or config file changes (`~/.briefings_config` is untouched).

---

## Sources & References

- Current `/follow-up` slash command: `commands/follow-up.md`
- Current verify script: `scripts/verify-v1.sh`
- Reference production follow-up: `~/Briefings/2026-05-27-1000-followup-sc-external-positioning-dss-debrief.md`
- v1 plan that established the conventions Phase 1 inherits: `docs/plans/2026-05-19-001-feat-sitrep-ledger-counterparty-v1-plan.md`
- v1 requirements: `docs/brainstorms/2026-05-19-sitrep-ledger-counterparty-v1-requirements.md`
- Phase 2–4 future scope: captured in the chat preceding this plan; see Scope Boundaries → Deferred to Follow-Up Work.
