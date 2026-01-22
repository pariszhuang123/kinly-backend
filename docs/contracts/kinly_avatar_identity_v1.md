# Kinly Avatar Identity Contract v1

Status: Proposed
Owners: Design System (policy), Product (UX intent), Release (CI + accessibility enforcement)
Scope: Flutter app (lib/**), avatar components, member selection UI, accessibility semantics
Non-breaking: Yes (additive, refactor-friendly)

This contract defines how avatars, names, and identity cues are presented in Kinly
to balance warmth, clarity, and low cognitive load.

## 1) Goals
- Make human identity unambiguous at decision points.
- Preserve Kinly calm, friendly, low-noise UI.
- Avoid relying on memory for relational actions.
- Ensure accessibility and inclusivity.
- Support homes from couples to extended households.

## 2) Non-Goals
- Define avatar art style (Design System owns visuals).
- Enforce profile completeness (Product/onboarding owns).
- Introduce usernames/handles (Kinly uses display names).
- Encode hierarchy, authority, or role via avatars.

## 3) Definitions
- Avatar: Visual identity marker representing a member (illustration, icon, image).
- Display Name: Human-readable name for a member (e.g., "Alex", "Mum").
- Identity Moment: UI moment where the user must recognize/select/assign someone.

## 4) Core Principles (Normative)
P1 - Never rely on memory alone
- Kinly must not assume users remember who an avatar represents.
- Avatars are emotional cues, not identity guarantees.

P2 - Identity must be revealed before impact
- If an action affects another person, their display name must be revealed before
  the action is committed.

P3 - Visual calm is preserved
- Names are secondary to avatars.
- Names are light in hierarchy and weight.
- Names are revealed progressively where appropriate.

P4 - Accessibility is mandatory
- All avatars must expose the display name to assistive technologies at all times,
  regardless of visual state.

## 5) Presentation Rules
### 5.1 Unselected State (Allowed)
- Avatars may be shown without visible names.
- Intended for: create/edit flows, dense layouts, scanning and quick selection.
- Accessibility semantics must still include the display name.
- This state is permitted only before intent is expressed.

### 5.2 Selected or Focused State (Mandatory)
- When an avatar is selected, focused, or highlighted:
  - The display name must be revealed visually.
  - The name must be readable without additional gestures.
  - The reveal must occur before any action can be committed.
- This is the canonical identity confirmation moment.

### 5.3 Committed or Summary State (Mandatory)
- After selection is confirmed, the display name must remain visible in:
  - Confirmation UI
  - Review states
  - Activity summaries
- Identity must remain unambiguous post-action.

## 6) Progressive Disclosure Pattern (Recommended)
- Avatar-only -> Name on selection -> Name persists on commit
- Default recommendation for:
  - Bill create/edit
  - Flow create/edit
  - Chore assignment
  - Responsibility rotation
  - Member selection screens

## 7) Restricted and Prohibited Patterns
Restricted
- An action affecting another person must not be committed unless:
  - The avatar is selected/focused
  - The display name is visible
  - Accessibility semantics expose the display name

Prohibited
- Committing an action without revealing the name.
- Expecting users to remember avatar identities.
- Hiding names behind non-obvious gestures.
- Encoding identity via color/shape/art alone.
- Sacrificing identity clarity for visual minimalism.

## 8) Accessibility Contract
Every avatar component must:
- Provide Semantics(label: displayName).
- Support screen reader focus and navigation.
- Maintain a minimum 48dp tap target.
- Not rely on imagery alone to convey identity.

CI or lint tooling may flag:
- Avatar widgets without semantics.
- Identity moments without visible name reveal.

## 9) Scaling Rules
- Name reveal on selection is mandatory for all home sizes.
- For larger homes, names should remain visible while focused.
- Persistence after commit is required.

## 10) Design System Integration
This contract depends on:
- Kinly Design System contract
- Kinly Accessibility contract
- Kinly Foundation Composable System contract

## 11) Rationale
Kinly is a relational system, not a task list. Mistaken identity creates friction,
emotional discomfort, and loss of trust. Progressive disclosure enables calm
scanning, clear intent, and safe commitment. Clarity is care.

## 12) Future Extensions (Non-binding)
- Role or context badges (non-hierarchical).
- Relationship labels (e.g., "Parent", "Flatmate").
- Pronoun support.
- Time-based name fading after commitment (never before).
