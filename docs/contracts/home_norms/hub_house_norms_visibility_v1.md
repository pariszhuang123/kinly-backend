---
Domain: Mobile
Capability: Hub House Norms Visibility
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly Hub House Norms Visibility Contract v1

Status: Proposed (MVP)

Scope: Hub surface visibility and access rules for House Norms.

Audience: Product, design, engineering, AI agents.

Depends on:
- House Norms v1
- Homes v2 (memberships + roles)
- Kinly product philosophy (care, not control)

1. Purpose

The Hub is a shared, low-pressure space for relational context in a home. It
surfaces House Norms to help members understand the home's shared defaults
without creating rules, obligations, or enforcement.

House Norms in Hub are:
- A readable shared starting point.
- Calm and non-urgent.
- Viewable by everyone in the home.

House Norms are not:
- A standard, policy, or compliance instrument.
- A checklist for behavior.
- A progress metric.

2. Eligibility and Visibility

2.1 When the House Norms slot appears
- The Hub MAY show a House Norms slot only when an active House Norms document
  exists for the current home_id.
- If no active House Norms document exists, the Hub MUST show no slot,
  placeholder, or CTA. Absence is intentional.

2.2 Who can see the slot
- All current members of an active home MAY see the House Norms slot.
- The slot is view-only for non-owners.
- The slot MAY show an edit entry point only for the home owner.

2.3 Slot placement and weight
- The slot MUST be visually low-weight (no urgency).
- The slot MUST NOT be positioned or styled like a required setup step.

3. Data Access and APIs

The Hub uses House Norms RPCs (see House Norms v1). No new APIs are required.

- house_norms_get_for_home(home_id, locale)
  - Used to determine if an active norms document exists.
  - Used to fetch content for the detail view.

- members_list_active_by_home(home_id, exclude_self)
  - Optional for contextual member display in the detail view.
  - Not required for House Norms slot eligibility.

4. Hub Slot Presentation

4.1 Visual semantics
- Use a distinct, calm color that is not shared with Bills or Flows.
- Avoid urgency or action signaling.
- Avoid setup-completion semantics.

4.2 Slot copy
- Copy must reinforce understanding, not rules or standards.
- Allowed intent examples:
  - "A shared starting point for living together."
  - "How this home tends to work best."
- Disallowed:
  - "House rules"
  - "Standards"
  - "Compliance"
  - "Expectations checklist"

4.3 Owner semantics
- Ownership MUST NOT be visually emphasized in Hub (no "owner wrote this"
  badge).
- The owner's edit affordance, if present, MUST be subtle (for example,
  overflow menu or small secondary action).
- Non-owners MUST NOT see suggestion, comment, or request-change affordances.

4.4 Slot interaction
- Tapping the House Norms slot MUST navigate to the House Norms detail page for
  the same home_id.
- The detail page MUST be readable by all current members.
- Create and edit actions on the detail page MUST be owner-only.

4.5 Detail page content and actions
- The detail page MUST show the full House Norms document structure:
  - Summary block (`title`, `subtitle`, framing text).
  - Full norms list covering all six directional sections.
- Members (non-owners) are strictly read-only:
  - No edit controls.
  - No publish controls.
  - No suggest/comment/request-change affordances.
- Owner actions on detail:
  - Owner MAY edit draft framing/section text according to House Norms v1.
  - Owner MAY publish from a low-emphasis action at the bottom of the detail
    page.
- Hub card semantics remain low-weight and non-urgent regardless of owner role.

5. Empty States

5.1 Hub empty state
If the Hub contains no gratitude posts, no preference reports, and no house
norms, the surface remains visually empty. A single low-weight explanatory line
MAY be shown. It MUST NOT prompt action or guilt.

Allowed intent:
- "This space reflects moments of care and shared understanding in your home."

5.2 No partial empty indicators
- Do not highlight that House Norms have not been created yet.
- Do not show missing counts, progress rings, or setup nudges.

6. Separation of Concerns

- Hub contains relational artifacts; Explore contains operational systems.
- House Norms must not surface in Explore.
- House Norms must not affect Bills, Flows, permissions, or automation.

7. Non-Goals

- Encouraging compliance
- Ranking or scoring home alignment
- Prompting non-owners to negotiate wording in-app

8. Invariant

House Norms exist to increase shared understanding, not compliance. Any
implementation that violates this principle breaches the contract.
