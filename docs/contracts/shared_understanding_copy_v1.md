# Kinly Shared Understanding Copy Contract v1.0

Status: Draft for MVP (home-only)

Scope: All user-facing copy (UI text, buttons, empty states, notifications, onboarding, paywall, errors).

Owners:
- Owner: Product
- Steward: Docs
- Enforcer: Engineering via lint + CI
- Human sign-off: Needed for new surfaces or sensitive home dynamics

Purpose: Set framing rules so Kinly sounds like shared understanding, not compliance. This contract pairs with `copy_taste_v1_1.md`: taste keeps the voice calm and warm; shared understanding keeps the intent cooperative.

## Core Principle (non-negotiable)
Kinly copy helps people understand each other. It never tries to control them.

## Mental Model
- We assume people want to contribute.
- Friction usually comes from unclear expectations, not bad intent.
- Homes feel better when context is visible.
- Avoid policing, score-keeping, or pressure language.

## Framing Rules
- Prefer collective framing: we, everyone, the home.
- Make things feel optional and invitational.
- Describe states and context before asking for action.
- Swap command-first strings with alignment-first strings.
- Rewrite rule: if a string answers “What should I do?”, rewrite it to answer “What should we understand?” unless it is an error/legal/system constraint.

## Preferred Vocabulary
- agree, alignment, context, understand, share, open, optional, together, everyone, coming up, settled.

## Discouraged Vocabulary (non-error/legal/system)
- assign, task, chore, due/overdue, require/required, must, log, record (verb), submit, failed, incomplete.
- Exceptions: errors, dialog bodies, and legal/system constraints where precision beats tone.

## Surface Guidance
- Titles: frame meaning, not commands. Example: “Create a Flow”, not “Add task”.
- Subtitles/Bodies: add why this matters; keep short, calm context.
- Buttons: close the loop (“Create flow”, “All set”); avoid enforcement verbs (“Submit”, “Assign”).
- Empty states: reassure and normalize pause; no blame.
- Errors: clear and factual; no blame. System/legal text may be direct.
- Paywalls/limits: frame as space/boundaries, not punishment.
- Notifications: one purpose, optional-feeling; never urgent.

## Human Review Checklist
- Does it sound like alignment, not instruction?
- Would this feel okay to say aloud to someone you live with?
- Does it assume goodwill and reduce pressure?
- Does it show context before action?
If fewer than three answers are “yes”, revise.

## Automation & CI (objective, blocking)
- Lint English ARB for discouraged vocabulary outside allowed surfaces (error, dialog_title/body, notification_*).
- Allow explicit overrides via `@key.shared_understanding_override: true` for legal/system constraints.
- Command: `dart run tool/check_shared_understanding_copy.dart` (added to CI).

## Governance
- Anyone can propose copy; product owns decisions; engineering enforces guardrails.
- If a string passes lint but violates this contract, the contract wins; update lint afterwards to cover the gap.
