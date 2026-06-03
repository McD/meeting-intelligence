---
date: 2026-05-29
topic: actions-tracker-commitments-only
---

# Actions tracker stays commitments-only

## Summary

The actions tracker remains a tracker of concrete commitments only — things the user owes, or things others owe to the user. Stances and FYI items are not captured anywhere in this system. The four-gate extraction filter and bulk-cleanup reply keywords are the durable enforcement, with a falsifiable escalation path to deterministic code if the prose filter drifts.

---

## Problem Frame

By 2026-05-29 the digest had ~46 open commitments. A discerning read showed three different kinds of content conflated under the single `commitment` type:

1. **Concrete actions** — things with a doer, a deliverable, and a done-state ("Send the vendor contract to legal by Friday"). These are what the tracker exists for.
2. **Stances** — decisions the user made about how to show up in future conversations ("position as Cédric's ally on Pulse", "stick to internal-PMF message in board comms", "keep Board vs Advisor roles separated"). No done-state. No moment when "it's done."
3. **FYI items** — tactical work by other attendees that the user heard but doesn't drive ("Aidan to install Claude-for-Playgrounds and demo to Johnny"). The user is incidentally present, not waiting on the deliverable for their own progress.

A quick triage of the rendered digest classified roughly a third of Yours items as stances and the majority of Owed items as FYI — only ~17% of what the digest surfaced was something the user could realistically chase. The pressure to find a "home" for stances (new schema type, separate doc, briefing surface) is the wrong instinct; the cost of categories the user doesn't reach for is bigger than the cost of letting that texture vanish.

---

## Requirements

**Capture rules**
- R1. Every captured commitment must pass all four extraction gates from `commands/follow-up.md` Step 3: concrete doer, done-state exists, has a deliverable/decision/interaction, worth chasing for the user.
- R2. Stances ("position as X", "stick to Y messaging", "keep roles separated") are excluded from capture. They do not get a new ledger entry type, a separate stance doc, or any other durable home in this system. **Stance-laundering guard** (gate 3 extension): if a deliverable's subject matter is itself a stance, posture, framing, or "how I'll show up" commitment (e.g. "draft my positioning on X", "write up how I'll handle Y"), the wrapper is still a stance and is excluded. The operational test: a real deliverable produces information someone else can use; a stance-wrapped deliverable produces information only the user references.
- R3. FYI items — tactical work by others that the user is incidentally aware of — are excluded from capture by gate 4 (worth chasing for the user). They do not get an alternative surface either.
- R4. Coaching, therapy, self-reflection, and debrief meetings capture **zero commitments by default**. Enforcement is via an **explicit calendar tag**: when the calendar event title contains `[coaching]`, `[debrief]`, `[1:1-introspective]`, or `[therapy]`, `commands/follow-up.md` Step 3 short-circuits before gate 1 and captures nothing. Item-level four-gate filtering is not relied on to enforce R4 — the gates fire per-item, not per-session, and inferring meeting type from transcript shape overlaps too heavily with normal introspective 1:1s. If the user wants exceptions inside a tagged meeting, they prepend `[capture-actions]` to the calendar title alongside the meeting-type tag.

**Schema and surfaces**
- R5. The existing `decision` entry type remains unchanged. Decisions reached in meetings still get a durable ledger row for briefing context, even though they do not appear in the actions tracker. *(See Dependencies / Assumptions: decisions-extraction-discipline is unaudited.)*
- R6. The ledger continues to hold only two entry types: `decision` and `commitment`. No `stance`, `intent`, `posture`, or `fyi` type is added.
- R7. Briefings continue to use the existing Delta and Pattern Flags surfaces, sourced from `decision` + `commitment` entries. No new briefing surface is introduced for stances or FYI.

**Observability**
- R8. Every `/follow-up` run logs each extracted candidate plus the gate decision (kept / dropped-by-gate-N) to `~/Briefings/scheduler.log` (or a per-meeting audit file at `~/Briefings/YYYY-MM-DD-HHmm-followup-audit.jsonl`). The audit log is the visible signal that the four-gate filter is firing correctly; it is the data feed for the steady-state success criterion below and the KD3 escalation trigger.

**Recovery for past noise**
- R9. The bulk-cleanup pattern — marking noise items as `state="dropped"` via `update_commitment_state` — is the recovery mechanism for items captured before the four-gate filter was in place. Today's run (commit `146a5ea`) dropped 15 such items.
- R10. The `not-mine: N`, `drop: N`, `drop-owed: N`, and `done-owed: N` reply keywords on the digest are the user-driven recovery surface for any noise that slips through the gates in future runs. Their use is tracked by the success criteria below — every invocation is a signal of filter drift.

---

## Success Criteria

- **SC1 (qualitative).** The digest renders only items the user could realistically chase someone about (themself for Yours; the named owner for Owed).
- **SC2 (qualitative).** A coaching or self-reflection meeting tagged `[coaching]` / `[debrief]` / etc. produces zero captured commitments by default.
- **SC3 (qualitative).** The user does not have to triage stance-shaped or FYI-shaped items out of the digest manually; they are either not captured, or are quickly cleanable with the existing reply keywords.
- **SC4 (validation, 14-day window).** In the 14 days following 2026-05-29, fewer than 3 commitments captured under the new filter get dropped via `not-mine:` / `drop:` / `drop-owed:` within 7 days of their capture. Exceeding this triggers the KD3 escalation path.
- **SC5 (steady-state, rolling 4-week ratio).** After the initial 14-day window, the rolling 4-week ratio of `drop` / `not-mine` / `drop-owed` reply keywords to total digest items stays below 15%. If it exceeds 15% in any week, the filter has drifted and the KD3 escalation path fires.

---

## Scope Boundaries

- No new ledger entry type (`stance`, `intent`, `posture`, `fyi`, or otherwise).
- No "current stances" or "active postures" doc surfaced in briefings before related meetings.
- No FYI capture for any future surface (briefing-time "what others are up to" callout, etc.).
- No automated backfill of historical follow-ups under the new four-gate filter. Past commitments stay in the ledger until the user marks them `done:` / `drop:` / `not-mine:` / `drop-owed:`, or until a future targeted cleanup script runs.
- No change to the existing `decision` entry type or how it is surfaced.
- **Stance texture is not retrievable in this system.** If a stance later turns out to be worth recalling (e.g. board-prep two months later), the path is a focused query against the raw transcript — `research:` on the original briefing/follow-up thread, or a new transcript-search keyword — not a new ledger entry type. The architectural commitment is: stances may be lost, but if found, they are retrieved via search, never via schema.

---

## Key Decisions

- **KD1. Stances are not decisions either.** A stance ("I'll position as X's ally") sounds like a decision but is a posture, not a binary resolution reached in a meeting. Decisions get `type: "decision"`; stances get nothing. The test: would a third-party reading the meeting record agree "this was decided here" without the user explaining? If no, it is a stance and is excluded. *(See Dependencies / Assumptions for the limit of this test.)*
- **KD2. No home is the right home for FYI.** Capturing FYI under any future surface (briefing context, side panel, etc.) reintroduces the same triage cost the user just escaped from. Briefings already pull cross-source context from Gmail, Drive, Slack, and prior transcripts for each attendee; that path covers "what is this person up to" without recording it as a commitment owed to the user.
- **KD3. The four-gate filter is the lasting fix, not the cleanup — *provisional*.** The cleanup is a one-time recovery; the filter is what keeps the ledger honest going forward. Future regressions on the actions tracker should be traced back to whether the filter is firing correctly, not to whether the schema needs a new type.

  **Escalation trigger.** If SC4 fails (>3 noise items captured in the first 14 days) or SC5 fails (rolling 4-week ratio > 15%), KD3 is invalidated and the filter migrates from prose to a deterministic post-processor in `briefings_mcp/schema.py`'s commitment validator: regex on stance-shaped verbs ("position", "stick to", "keep ... separated", "show up as", "be more X") plus a structural attendee-vs-owner check for gate 4. Until that trigger fires, the prose filter is the canonical enforcement. Audit log from R8 supplies the evidence.

---

## Dependencies / Assumptions

- The four-gate filter in `commands/follow-up.md` Step 3 (committed `146a5ea` on 2026-05-29, extended by the stance-laundering guard in R2 and the calendar-tag short-circuit in R4) is the canonical enforcement. Any future drift on the gate definitions there is the single point of regression; the audit log from R8 is the visibility surface for detecting drift.
- The `update_commitment_state` and `update_commitment_owner` ledger mutators (in `briefings_mcp/ledger.py`) are the recovery surface that the `done:` / `drop:` / `not-mine:` / `drop-owed:` reply keywords depend on.
- The digest's filter for `owner in ("", "unassigned")` continues to suppress items disowned via `not-mine:` from both sections.
- **Decisions-extraction-discipline assumption (unverified).** Decisions are assumed to be extracted with sufficient discipline today and not subject to the over-capture pattern that affected commitments. This is unverified at the time of writing. If the briefing's Delta or Pattern Flags sections start to feel noisy, audit the `decision` entries with the same triage shape used for commitments today (sample a recent run, classify each decision as real / stance / FYI). If the noise rate ≥ 10%, extend the four-gate filter to decisions or add a parallel set of gates tailored to "was a binary resolution actually reached?"
- **KD1 third-party test relies on LLM-simulated reasonableness.** The "would a third-party agree this was decided?" test asks the LLM to simulate a hypothetical neutral reader. That simulation is stable enough for the obvious cases (clear stances are clearly excluded) but degrades on the edge cases (a 1:1 where someone said "yes, let's do X" — agreement reached, but barely a decision). If too many edge-case items show up as decisions in the briefing, consider replacing the test with an operational one: "does the item resolve a question the meeting opened?"

---

## Deferred / Open Questions

### From 2026-05-29 review

*(None deferred this round — all 8 actionable findings were Applied.)*
