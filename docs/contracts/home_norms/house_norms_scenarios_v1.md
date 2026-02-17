---
Domain: Shared
Capability: House Norms Scenarios
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly House Norms Scenarios Contract v1

Status: Proposed (Create Home MVP)

Scope: Scenario-based capture model for House Norms during Create Home.

Audience: Product, design, engineering, AI agents.

Depends on:
- House Norms Taxonomy v1
- Kinly product philosophy (recognition over configuration)
- Kinly Project Brief

1. Purpose

Define canonical scenario prompts and three-option choices used to capture a
home's shared defaults in Kinly style.

Scenarios:
- Are relatable moments.
- Have exactly three options.
- Avoid judgment.
- Avoid enforcement language.

2. Scenario Model

Each scenario item includes:
- `id` (stable and taxonomy-backed)
- `scenario` (prompt)
- `options` (exactly 3 strings)
- `option_order` meaning (`0..2`) documented

2.1 Constraints

No scenario may:
- Include "must/always/never".
- Reference consequences ("or else").
- Refer to specific people's behavior.
- Ask for deal-breakers.
- Ask users to rank importance.
- Use "rules" terminology.
- Capture hard policy constraints that belong to House Rules.

3. Required Context Anchors (owner completes)

3.1 Property context
- Prompt: "Are you renting or owning this house"
- Options (exactly 3):
  - `0`: "We own this home"
  - `1`: "We rent this whole home"
  - `2`: "We rent rooms in a shared home"

3.2 Relationship model
- Prompt: "Who's sharing this home together?"
- Options (exactly 3):
  - `0`: "Housemates"
  - `1`: "Family"
  - `2`: "Family and housemates"

4. Canonical Directional Scenarios (v1)

4.1 `norms_rhythm_quiet`
- Scenario:
  - "It's late, and someone is still active at home. What usually feels okay?"
- Options:
  - `0`: "Things wind down so the home can rest"
  - `1`: "It depends - some nights are quieter than others"
  - `2`: "Everyone keeps doing their thing"

4.2 `norms_shared_spaces`
- Scenario:
  - "You walk into the kitchen at the end of the day. What feels most comfortable?"
- Options:
  - `0`: "Mostly clear and ready to use"
  - `1`: "Lived-in, but reset later"
  - `2`: "A bit messy is fine - it's a shared home"

4.3 `norms_guests_social`
- Scenario:
  - "A friend or partner wants to come over. What usually feels right?"
- Options:
  - `0`: "It's planned and talked about first"
  - `1`: "A heads-up is enough"
  - `2`: "That's part of daily life here"

4.4 `norms_responsibility_flow`
- Scenario:
  - "Something small needs doing around the house. What tends to happen?"
- Options:
  - `0`: "We usually have clear agreements"
  - `1`: "Someone takes care of it when they notice"
  - `2`: "Everyone mostly looks after their own things"

4.5 `norms_repair_style`
- Scenario:
  - "Something feels a bit off between people. What helps most?"
- Options:
  - `0`: "Talking it through sooner rather than later"
  - `1`: "Checking in gently when the moment feels right"
  - `2`: "Letting small things pass unless they build up"

4.6 `norms_home_identity`
- Scenario:
  - "On a good day, this home feels most like..."
- Options:
  - `0`: "A calm place to recharge"
  - `1`: "A balance of quiet time and togetherness"
  - `2`: "A lively place where people come and go"

5. Interpretation Rules (Product and AI)

- Do not interpret scenarios into enforcement.
- Use scenarios only to shape tone and defaults in the generated document.
- When selections are mixed (future v2 per-member), phrase as "varied".
- In v1, scenarios are owner-selected home defaults; no aggregation is needed.
- Hard constraints (for example smoking bans, pet permissions, severe allergen
  policy) are out-of-scope for House Norms scenarios and route to House Rules.

6. Versioning and Governance

- Scenario wording MAY change without changing IDs.
- IDs are immutable.
- New scenario IDs require v2 and an ADR.
- Deprecations must be non-breaking and documented.

7. Contract Schema (Reference)

```contracts-json
{
  "domain": "house_norms_scenarios",
  "version": "v1",
  "entities": {
    "HouseNormsScenario": {
      "id": "text",
      "scenario": "text",
      "options": "text[3]",
      "enforceable": false
    }
  },
  "functions": {}
}
```
