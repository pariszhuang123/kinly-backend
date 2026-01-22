---
Domain: HOME
Capability: Home Preferences & Rules
Scope: shared
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

# Kinly Contract v1 - Home Preferences, Vibe, and Rules

Status: Canonical rationale (non-breaking)

Scope: Preference capture, vibe calculation, rule generation, sharing, enforcement.

Audience: Product, design, engineering, AI agents.

Purpose

This contract defines three distinct but related concepts in Kinly:
- Personal Preferences
- Home Vibe
- Home Rules

They must remain separate by design to preserve trust, psychological safety,
system stability, and correct enforcement semantics.

Core Principle

Preferences describe people.
Vibe describes the home.
Rules describe agreements.

Each serves a different role and obeys different rules of change, ownership,
and enforcement.

1) Personal Preferences

Definition
Personal preferences are individual, self-reported signals about a person's:
- needs
- sensitivities
- energy
- communication tendencies
- interests
- goals
- pet peeves

They answer: "What is true for me?"

Properties
- Owned by the individual.
- Descriptive, not prescriptive.
- Non-binding and subjective.
- May change frequently.
- Require interpretation to be useful.

Why preferences require a taxonomy
Preferences are signals, not decisions. Without a taxonomy:
- signals cannot be aggregated fairly
- meaning drifts over time
- outputs become inconsistent
- future features (matching, vibe, summaries) break

A preference taxonomy provides:
- semantic consistency
- bounded scope (prevents question creep)
- stable interpretation across wording changes
- safe aggregation into higher-level constructs

2) Home Vibe

Definition
Home vibe is an emergent, descriptive summary of what a home tends to feel like,
based on the aggregation of personal preferences of current members.

It answers: "Given who lives here, what does this home feel like right now?"

Properties
- Collective (derived from many people).
- Descriptive, not enforceable.
- Non-binding.
- Automatically recalculated.
- Changes when people join, leave, or update preferences.
- Requires no acceptance.

Home vibe is a reflection, not a rule.

Important constraints
- Vibe must never gate actions.
- Vibe must never require acceptance.
- Vibe must never auto-modify rules.

Home vibe is discovered, not decided.

3) Home Rules

Definition
Home rules are explicit, intentional agreements that define how shared
interactions work.

They answer: "What have we agreed to do when coordination matters?"

Examples: quiet hours, guest norms, responsibility expectations, communication
norms, money handling.

Properties
- Declared by the home owner (with member acceptance).
- Explicit and discrete.
- Normative and enforceable.
- Versioned.
- Change only via intentional edits.

Home rules are decisions, not signals.

Why rules do NOT require a taxonomy
Rules already have:
- explicit meaning
- clear scope
- direct enforcement semantics

They do not need interpretation or aggregation. A rule is its own semantic unit.

Adding a taxonomy to rules would:
- blur accountability
- make enforcement ambiguous
- imply negotiability where none exists

4) Relationship Between the Three

The system flows downward, never upward:

Personal Preferences (rich, fuzzy, individual)
        ->
Home Vibe (emergent, descriptive, collective)
        ->
Home Rules (explicit, minimal, enforceable)

Key invariants
- Preferences influence vibe.
- Vibe may inspire rule changes.
- Rules never auto-derive from vibe.
- Preferences never become rules by default.

5) Hard Guardrails (Prohibited)

The following are explicitly disallowed:
- Treating preferences as implicit rules.
- Auto-generating or auto-updating rules from vibe.
- Requiring acceptance of vibe.
- Enforcing preferences.
- Using vibe to block user actions.
- Collapsing hobbies, pet peeves, or identity traits into rules.

Violating these breaks trust and safety.

6) Rationale

Without this separation:
- users feel policed by averages
- personal expression becomes risky
- homes feel unstable or manipulative
- rules feel passive-aggressive
- system behavior becomes unpredictable

With this separation:
- people can express themselves safely
- homes can evolve without conflict
- rules remain minimal and intentional
- vibe remains honest and human

Summary (Canonical)

Personal preferences require taxonomy because they are signals that must be
interpreted.
Home vibe is an emergent description derived from preferences.
Home rules do not require taxonomy because they are explicit agreements.
Each layer has different ownership, change semantics, and enforcement rules.
Mixing these layers is a design error.

Preferences are language. Vibe is meaning. Rules are law.

```contracts-json
{
  "domain": "home_dynamics",
  "version": "v1",
  "entities": {},
  "functions": {},
  "rls": []
}
```
