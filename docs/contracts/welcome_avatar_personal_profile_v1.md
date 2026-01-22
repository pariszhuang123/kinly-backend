# Welcome Avatar & Personal Profile Access v1 (Adjusted)

Status: Proposed  
Scope: Start surface (no-home), personal artifacts access  
Owner: Kinly Core

Primary goal: allow users without an active home to access and share their personal artifacts (preferences, personal mentions) with a meaningful identity affordance.

## 1) Definitions
- Personal artifact: user-owned data existing outside a specific home. In v1:
  - Personal Preference Report (published)
  - Personal Mention (received)

## 2) Avatar Visibility Rule (Start Surface)
- Avatar appears only if the user has **at least one** personal artifact:
  - `has_preference_report == true` OR `has_personal_mentions == true`
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
Purpose: single decision point for avatar visibility, routing, and artifact existence outside a home.

Fields returned:
- `user_id uuid`
- `has_home boolean`
- `active_home_id uuid`
- `has_preference_report boolean`
- `has_personal_mentions boolean`
- `avatar_storage_path text` (nullable; preferred avatar for identity affordance)

Invariants:
- Succeeds when user has no home.
- Only returns data for `auth.uid`.
- Does not leak artifact content; only existence flags and avatar path.

Avatar sourcing:
- Use `avatar_storage_path` when present; fall back to initial-only avatar otherwise.

## 6) Explicit Scenarios
- First-time user (no artifacts): no avatar; only create/join.
- Preference only: avatar shown; preferences sheet opens to onboarding/view as applicable.
- Mention only: avatar shown; mentions screen accessible.
- Left all homes: avatar still shown if artifacts exist.
- Deleted all artifacts: avatar removed.

## 7) Non-Goals (v1)
- Public sharing links, anonymous viewing, cross-user browsing, or showing avatar solely because user is authenticated.
