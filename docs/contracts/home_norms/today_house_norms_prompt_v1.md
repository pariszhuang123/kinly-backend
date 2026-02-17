---
Domain: Mobile
Capability: Today House Norms Prompt
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly Today House Norms Prompt Contract v1

Status: Proposed (MVP)

Scope: Visibility, tone, and navigation rules for the owner-only Today prompt
that starts House Norms creation.

Audience: Product, design, engineering, AI agents.

Depends on:
- House Norms v1
- House Norms API v1
- Homes v2 (memberships + roles)
- Kinly product philosophy (care, not control)

1. Purpose

The Today surface may offer a low-pressure owner prompt to start House Norms
when a home has no norms document yet.

This prompt exists to start shared understanding, not to enforce rules.

2. Eligibility and Visibility

2.1 Show condition (all required)
- Current user is authenticated.
- Current user is a current member of the active home.
- Current user role is `owner`.
- `house_norms_get_for_home(home_id, locale)` returns:
  - `"ok": true`
  - `"house_norms": null`

2.2 Hide conditions
- Any non-owner role.
- Any response where `house_norms` exists (published or out_of_date).
- Home inactive or user not a current member.

2.3 Canonical frontend signal
- `house_norms == null` is the canonical signal for showing the Today prompt.
- Frontend must not infer missing state from other entities or heuristics.

2.4 API binding
- The prompt contract binds to existing API `house_norms_get_for_home`.
- No Today-specific RPC is required in v1.

3. Prompt Presentation

3.1 Tone and semantics
- Prompt must be calm and non-urgent.
- Prompt must not use setup-completion metaphors (no progress rings/checklists).
- Prompt must not imply compliance, enforcement, or obligations.

3.2 Placement
- Prompt appears in Today among low-pressure contextual cards.
- Prompt must not dominate primary operational tasks.

4. Interaction

4.1 Primary action
- CTA opens House Norms onboarding/capture flow for the same home.
- On successful generation, Today prompt disappears on next refresh because
  `house_norms` is no longer null.

4.2 No member negotiation channel
- Non-owner members must not get suggest-edit/comment/request-change actions
  from this prompt.

5. Non-Goals

- Prompting non-owners to author or negotiate norms.
- Tracking completion percentages for norms setup.
- Treating norms as rules or policy enforcement.

6. Invariant

The Today House Norms prompt is an owner-only invitation to define shared
defaults. It must never behave like a required setup step or compliance gate.
