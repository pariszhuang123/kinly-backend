---
Domain: Mobile
Capability: Welcome Avatar Personal Profile
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Welcome Avatar & Personal Profile Access v1 (Adjusted)

Status: Proposed  
Scope: Start surface (no-home), personal artifacts access  
Owner: Kinly Core

Primary goal: allow users without an active home to access and share their personal artifacts (preferences, personal mentions) with a meaningful identity affordance.

## 1) Definitions
- Personal artifact: user-owned data existing outside a specific home. In v1:
  - Personal Preference Report (published)
  - Personal Mention (received)
  - Personal Directory content (bank account or active note)

## 2) Avatar Visibility Rule (Start Surface)
- Avatar appears only if the user has **at least one** personal artifact:
  - `has_preference_report == true`
  - `has_personal_mentions == true`
  - `has_personal_directory_content == true`
- No placeholder/disabled avatar; no empty sheet.

## 3) Avatar Interaction (Start Surface)
- Placement: top-right of Start screen.
- Tap: opens Personal Profile sheet with:
  - Personal Preferences
  - Personal Mentions
- Entry source passed as `"start"` for navigation/back behaviors.

## 4) Routing Independence
- Personal Preferences and Personal Mentions must be reachable without an active home. Home membership only affects Hub access, not these routes.

## 5) RPC Contract: `user_context_v1`
Purpose: single decision point for avatar visibility, routing, and artifact
existence outside a home, including whether the owner has any Personal
Directory content.

Return shape: `jsonb`

Canonical response shape:

```json
{
  "ok": true,
  "user_id": "uuid",
  "has_preference_report": true,
  "has_personal_mentions": false,
  "has_personal_directory_content": true,
  "show_avatar": true,
  "avatar_storage_path": "text|null",
  "display_name": "text|null"
}
```

Invariants:
- Succeeds when user has no home.
- Returns no home identifiers or home-scoped state.
- Only returns data for `auth.uid`.
- Does not leak artifact content; only existence flags and avatar path.
- `has_personal_directory_content` MUST be `true` when either of the
  following is true for `auth.uid()`:
  - a row exists in `member_directory_bank_accounts`
  - an active row exists in `member_directory_notes` where
    `archived_at is null`
- `has_personal_directory_content` MUST be `false` only when the caller has
  neither a bank account nor any active personal-directory notes.
- `show_avatar` MUST equal logical OR of:
  - `has_preference_report`
  - `has_personal_mentions`
  - `has_personal_directory_content`
- `avatar_storage_path` MUST be non-null when any of
  `has_preference_report`, `has_personal_mentions`, or
  `has_personal_directory_content` is true.
- `avatar_storage_path` MUST be null when all three artifact flags are false.

Avatar sourcing:
- Use `avatar_storage_path` when present; fall back to initial-only avatar otherwise.

Sheet visibility:
- The Start-surface personal-profile sheet is reachable only when `avatar_storage_path`
  is non-null.
- Personal Directory UI inside that sheet MUST be hidden when
  `has_personal_directory_content` is false.

## 6) Explicit Scenarios
- First-time user (no artifacts): no avatar; only create/join.
- Preference only: avatar shown; preferences sheet opens to onboarding/view as applicable.
- Mention only: avatar shown; mentions screen accessible.
- Personal Directory only: avatar shown; personal-profile entry remains available even with no active home.
- Left all homes: avatar still shown if artifacts exist.
- Deleted all artifacts: avatar removed.

## 7) Non-Goals (v1)
- Public sharing links, anonymous viewing, cross-user browsing, or showing avatar solely because user is authenticated.
