---
Domain: Shared
Capability: House Norms Taxonomy
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly House Norms Taxonomy Contract v1

Status: Proposed (Create Home MVP)

Scope: Stable taxonomy for House Norms scenario IDs and option value keys.

Audience: Product, design, engineering, AI agents.

Depends on:
- Kinly product philosophy (care, not control)
- Kinly Project Brief

1. Purpose

Define stable IDs so House Norms can be captured consistently, interpreted
safely, and generated from templates without semantic drift.

Taxonomy applies only to House Norms. It does not apply to permissions,
enforcement, or feature gating.

2. Core Principles

- IDs are stable and never renamed.
- Wording can evolve without changing IDs.
- House Norms remain descriptive, not enforceable.
- No automatic compliance or monitoring is implied.

3. Domains (v1)

These domains are for organization only (UI grouping and template structure).
They do not imply priority.

- `rhythm`
- `spaces`
- `social`
- `effort`
- `repair`
- `identity`
- `context` (anchors)

4. Taxonomy Items (v1)

4.1 Context anchors

`norms_property_context`
- `domain`: `context`
- `value_keys`: [`owner_occupied`, `rental`, `room_rental_shared_home`]

`norms_relationship_model`
- `domain`: `context`
- `value_keys`: [`housemates`, `family`, `family_and_housemates`]

4.2 Directional norms

`norms_rhythm_quiet`
- `domain`: `rhythm`
- `value_keys`: [`wind_down`, `variable`, `flexible`]

`norms_shared_spaces`
- `domain`: `spaces`
- `value_keys`: [`clear_now`, `reset_later`, `relaxed`]

`norms_guests_social`
- `domain`: `social`
- `value_keys`: [`planned`, `heads_up`, `everyday`]

`norms_responsibility_flow`
- `domain`: `effort`
- `value_keys`: [`clear_agreements`, `notice_and_do`, `own_areas`]

`norms_repair_style`
- `domain`: `repair`
- `value_keys`: [`talk_soon`, `gentle_check_in`, `let_small_pass`]

`norms_home_identity`
- `domain`: `identity`
- `value_keys`: [`recharge`, `balanced`, `lively`]

5. Machine-readable Taxonomy (v1)

```contracts-json
{
  "domains": [
    "context",
    "rhythm",
    "spaces",
    "social",
    "effort",
    "repair",
    "identity"
  ],
  "items": [
    {
      "id": "norms_property_context",
      "domain": "context",
      "value_keys": ["owner_occupied", "rental", "room_rental_shared_home"]
    },
    {
      "id": "norms_relationship_model",
      "domain": "context",
      "value_keys": ["housemates", "family", "family_and_housemates"]
    },
    {
      "id": "norms_rhythm_quiet",
      "domain": "rhythm",
      "value_keys": ["wind_down", "variable", "flexible"]
    },
    {
      "id": "norms_shared_spaces",
      "domain": "spaces",
      "value_keys": ["clear_now", "reset_later", "relaxed"]
    },
    {
      "id": "norms_guests_social",
      "domain": "social",
      "value_keys": ["planned", "heads_up", "everyday"]
    },
    {
      "id": "norms_responsibility_flow",
      "domain": "effort",
      "value_keys": ["clear_agreements", "notice_and_do", "own_areas"]
    },
    {
      "id": "norms_repair_style",
      "domain": "repair",
      "value_keys": ["talk_soon", "gentle_check_in", "let_small_pass"]
    },
    {
      "id": "norms_home_identity",
      "domain": "identity",
      "value_keys": ["recharge", "balanced", "lively"]
    }
  ]
}
```

6. Governance and Versioning

Owners:
- Product: semantic meaning and scope.
- Design: phrasing and UX safety.
- Engineering: schema and enforcement.
- Docs: versioning and changelog.

Versioning rules:
- IDs are immutable.
- Scenario wording may change without version bump.
- New IDs require v2 and an ADR.
- Deprecations must be non-breaking and documented.

7. Non-Goals

- Enforcement or permissions derived from taxonomy.
- Automatic reminders.
- Best-practice scoring.
- Treating norms as house rules.

8. Invariant

House Norms are a calm, shared reference. They must never become a mechanism
for control or compliance.
