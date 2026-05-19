---
date: 2026-05-19
topic: next-level
focus: where the meeting-intelligence product goes next level — new context sources, output formats, triggers, automation built on top, team compounding, strategy-loop closure
mode: repo-grounded
---

# Ideation: Where meeting-intelligence goes next level

## Grounding Context

**Product as of 2026-05-19:** personal Mac tool, launchd-driven, runs every 15 minutes. Generates pre-meeting briefings pulling Gmail/Drive/Slack/transcripts, post-meeting follow-ups extracting actions and decisions from Gemini/Teams/MacWhisper transcripts. Delivered to inbox + private Slack. ~700 LOC bash + markdown. Pre-flight gate skips ~90% of cycles. File-based state. Public at github.com/McD/meeting-intelligence (MIT). Solo user (Mark, CPO ScreenCloud) + one colleague (Cédric).

**Gap in the landscape (2026):** No shipped product runs autonomous, multi-source, scheduled briefings AND closes the decision-outcome loop into later briefings.

- **Granola** ($1.5B Series C, March 2026): pivoting from notetaker to context infrastructure with MCP server. Stated direction: "other AI tools can query Granola rather than compete with it."
- **Limitless** absorbed by Meta (Dec 2025) — always-on capture is platform-layer now.
- **Clockwise** shut down March 2026.
- **alfred_** closest to overnight unattended briefing but no cross-source aggregation.
- **Glean**: 1.9x preference vs ChatGPT on enterprise queries; bet is corpus quality beats model capability.

**Doctrinal analogies cited as design references:**
- Military SITREP — brief not report; bottom line up front; delta not state dump.
- Intelligence brief vs report — brief leads with assessment, inverted pyramid.
- Trading-desk pre-market — freshness rule (always fetch, never reuse summaries).
- FCO/State diplomatic cable — Comment block quarantines interpretation from reporting.

**Failure modes to design around:**
- Engagement collapse (skim the brief instead of think; AI does the thinking).
- Missing the "why" (decisions captured without political context).
- Self-censorship in recorded meetings.
- Six-month falloff (impressive first brief, noise by the 40th).
- "Should have been an email" — tools that make pointless meetings feel productive are net-negative.

**Subject identity (do not pivot away):** tool that helps an exec prepare for and follow up on meetings, compounding into team intelligence over time.

## Ranked Ideas

### 1. Decision Ledger + Why-Capture, exposed via MCP
**Description:** Append every follow-up's decisions to `~/.briefings/decisions.jsonl` (date, attendees, topic tags, source meeting, *why* — captured via a 60-second Slack prompt after each follow-up). Next briefing's pre-flight queries the ledger to surface prior decisions touching the same attendees/topics. Expose the ledger as a local MCP server so Claude Code / Claude Desktop / future agents can query "what did Mark commit to about pricing in the last 90 days?"
**Warrant:** `external:` Granola's March 2026 $1.5B Series C was priced explicitly on this pivot — notetaker → context infrastructure with MCP. Co-founder: "other AI tools can query Granola rather than compete with it."
**Rationale:** Converts existing throwaway markdown into a permanent asset. Fights the six-month falloff directly: brief #1 says "Sarah heads sales"; brief #40 says "Sarah pushed back on EMEA hiring in Feb, agreed to revisit Q2, quiet on the pricing change you flagged last week." Defensibility lives in the corpus, which is private.
**Downsides:** Why-capture requires 60s × N follow-ups of discipline. Schema migration becomes real at scale. MCP server is one more local service to maintain.
**Confidence:** 90%
**Complexity:** Medium
**Status:** Explored

### 2. Decline-or-Async Meeting Recommendation
**Description:** Health-check before every briefing. If the agenda's unclear, the goal is status-only, or the same decision was already made in Slack, draft a decline-with-async-alternative into the user's email drafts folder. The brief becomes the fallback. Success metric flips from "meetings prepared" to "meetings avoided."
**Warrant:** `direct:` Failure mode from research: "A pre-meeting brief that makes a pointless meeting feel productive is net-negative."
**Rationale:** Every other meeting product is incentivised to make meetings feel important. A personal tool isn't. The product that occasionally tells you to skip is the product you trust on the meetings you do attend. Strongest positioning against alfred_, Granola, every notetaker.
**Downsides:** Wrong declines are socially expensive. Detection needs guardrails — don't auto-decline the CEO.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

### 3. Restructure the Brief: Verdict + Trap + Delta + Comment
**Description:** SITREP-shape, not report-shape. Lead with a one-word verdict (`DELEGATE`, `DECIDE-TODAY`, `LOW-STAKES`). Then the *trap* — the single thing most likely to derail this meeting based on prior turn history. Then the *delta* — what changed since the last touchpoint, not a state dump. Finally a labeled `Comment:` block separating interpretation from reporting (FCO cable style). Optional T-15-minute "radio call" Slack DM, full text on click.
**Warrant:** `external:` Three doctrines from research — military SITREP ("delta, not state dump"), Armada Corporate Intelligence's 21-year format (BLUF + 3-5 developments + implication + next steps), FCO/State cable Comment-block discipline.
**Rationale:** Current AI briefings are reports — comprehensive, chronological, methodology visible. Grounding explicitly named this as the structural error. SITREP-shape is the cheapest possible change (prompt rewrite) with the highest expected impact on engagement.
**Downsides:** Verdict line forces an opinion the system may not deserve. Wrong verdicts erode trust fast. Comment quarantining requires the system to know what's opinion vs fact (the actual hard problem).
**Confidence:** 80%
**Complexity:** Low
**Status:** Explored

### 4. Ad-Hoc Context on Demand
**Description:** Mac hotkey + Slack slash command (`/brief @thread`, `/brief @person`, `/brief topic:hiring`) — same-shape briefing in under 60 seconds against any thread URL, email, name, or topic.
**Warrant:** `direct:` Named gap from internal scan — "Calendar-only triggering. No ad-hoc context-on-demand."
**Rationale:** Calendar is a narrow slice of actual decision moments. Most exec context-switching happens in Slack and email, not in meetings. 10x daily relevance without changing the product's identity.
**Downsides:** On-demand can't be pre-staged — latency budget tightens. Slash commands invite "how do I phrase this?" friction.
**Confidence:** 80%
**Complexity:** Low-Medium
**Status:** Unexplored

### 5. Counterparty Modeling
**Description:** Every external-facing briefing gets a "What they probably want" subsection. Same sources, different perspective — their objective, their last commitment, what they'll likely raise. V2 (later): generate a counterparty-facing briefing and optionally send it to them the night before.
**Warrant:** `reasoned:` Every meeting is two minds aligning. A briefing modelling only one side is a half-briefing. Built from data already pulled — purely a prompt perspective flip.
**Rationale:** Reframes meetings from transmission to negotiation. V1 is immediate value. V2 is a defensible category move — no current product arms the other side.
**Downsides:** V1 risks generic guesses when counterparty data is thin. V2 is socially loaded — delightful or unnerving depending on relationship.
**Confidence:** 75%
**Complexity:** Low (v1), Medium (v2)
**Status:** Explored

### 6. Strategy.md and OKR Docs as Read-Through Surfaces
**Description:** `briefings:` block at the top of strategy docs / OKR docs / board narratives declaring a decision-ledger query (e.g. `topic:pricing since:2026-Q1`). On open or nightly, the block is auto-replaced with the matching decisions. Strategy docs stop drifting from operational reality because they read it.
**Warrant:** `external:` Grounding's named gap — "no product closes the loop from operational data → strategy work." WorkBoard's John/Sofia attempt this from the enterprise direction; nothing from the personal-tool direction.
**Rationale:** Moves from "tool the exec uses" to "infrastructure the org depends on." Once the quarterly board pack reads from the ledger, removing the briefings system breaks board prep. Pulls the product upstream into where a CPO's actual leverage lives.
**Downsides:** Depends on #1 shipping first. Requires strategy docs to live somewhere readable+writable. Risk of strategy docs becoming auto-generated and stop being thought.
**Confidence:** 80% (conditional on #1)
**Complexity:** Medium
**Status:** Unexplored

### 7. Team-Visible Briefings + Shared Corpus
**Description:** Default-public-within-team briefings posted to a `#meeting-intel` Slack channel (per-meeting confidentiality opt-out). When a second exec installs, their ledger merges with yours (consent-gated, attendee-scoped). Each new user adds graph nodes; each shared meeting becomes a higher-confidence edge.
**Warrant:** `direct:` Subject identity is "compounding into team intelligence over time." Private-by-default actively works against the stated identity. Product is already correctly parameterised for non-Mark users.
**Rationale:** Network compounding kicks in at N=2. Two independent decision extractions on the same meeting create higher-signal data, especially their disagreements.
**Downsides:** Public-by-default is a culture decision before a feature decision. Self-censorship risk inverts. Consent + access controls become first-class — crosses into methodology retrofit rules (CI, Sentry, security review).
**Confidence:** 70%
**Complexity:** Medium-High
**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| F1.5 | Local mic transcript capture | Privacy/consent non-trivial in corporate setting; future opt-in not default |
| F3.7 | Voice-out / audio briefing | Format change is downstream — content shape needs to be right first |
| F3.8 | Suppress harmful briefings | "Harmful" hard to define; better as ce-brainstorm variant than shipped feature |
| F4.7 | Pluggable sources framework | Premature abstraction — 4 sources today; framework cost outpaces cadence |
| F4.8 | Pre-flight gate that learns | Gate at 91% skip; ML on a working primitive is diminishing returns |
| F5.2 | Problem-oriented SOAP | Subsumed by #1 — the ledger surfaces active problems naturally |
| F5.3 | D&D campaign bible | Subsumed by #1 — the latent corpus IS the bible if #1 ships |
| F5.7 | Court ripeness | Folds into #3 as a "ripe decisions" section; not enough to stand alone |
| F6.2 | Real-time refresh on open | Engineering cost outpaces freshness benefit |
| F6.4 | $1k/month value-tracking | Meta-feature, better as implementation recommendation than separate idea |
| F6.5 | Ambient read-everything | Consent/scope concerns; defer until core needs more sources |
| F6.6 | 100 AIs disagreement map | Folded into #3 as the Comment / dissent layer |
| F1.6 + F2.2 + F5.5 | Closed-loop actions / drafts / strip-marking | Real, smaller than top 7; worth doing after #1 ships (ledger = state machine) |
| F1.8 + F3.4 + F6.8 | Day-shape / morning digest / week-ahead | Cadence variants — fold into #3 once verdict format exists |

## Combined Brainstorm Seed (chosen 2026-05-19)

Ideas **#1 + #3 + #5** are being brainstormed together as one v1 package. They interlock structurally:

- **#3 (Restructured Brief)** is the new *output shape* — verdict + trap + delta + comment.
- **#1 (Decision Ledger + MCP)** is the new *substrate* the brief reads from (to compute "delta" since last touchpoint, to surface prior commitments) and writes to (each follow-up appends to the ledger).
- **#5 (Counterparty Modeling)** is a *section inside* the new brief, drawing on the same ledger from the other party's perspective.

Combined pitch: *"SITREP-shape brief that reads from and writes to a queryable decision ledger, with a counterparty section."*

This combined seed is the brainstorm input for `ce-brainstorm`.
