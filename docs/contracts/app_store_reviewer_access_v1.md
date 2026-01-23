---
Domain: app_store_review
Capability: deterministic_reviewer_access
Scope: kinly (iOS + Android)
Artifact-Type: contract
Status: draft
Stability: beta
Version: v1.0.0
Owner: paris
Last-Updated: 2026-01-23
---

# Contract: Deterministic Reviewer Access (Email/Password, Normal Auth)

## 1) Problem Statement
App store reviewers must log in without Google/Apple prompts, MFA, or location checks. They need a deterministic email/password that produces a normal Supabase session so RLS and existing app flows work. No reviewer-only roles/flags are introduced.

## 2) Goals
- Deterministic login via Supabase Auth email/password (no OAuth prompts).
- Reviewer session is a normal authenticated user; `auth.uid()` works everywhere.
- Hidden/low-prominence entry point remains a client concern (out of this repo).
- No new reviewer-specific DB state (roles, flags, bypass policies).

## 3) Non-Goals
- Replacing Google/Apple sign-in for real users.
- Adding reviewer-only columns, roles, or RLS exceptions.
- Shipping demo-only data or fixtures from the backend (seeding handled manually in-app if desired).

## 4) Backend Requirements
R1 — Reviewer Auth user exists and is confirmed  
- Create the reviewer in Supabase Auth (email/password).  
- Ensure `email_confirmed_at`/`confirmed_at` is set so no email confirmation flow blocks sign-in.

R2 — Profiles linkage remains standard  
- `public.profiles.id = auth.users.id`; `public.profiles.email = reviewer email`.  
- Reuse the existing `handle_new_user` trigger path; if absent, insert once manually.

R3 — Session + RLS unchanged  
- Reviewer signs in through `supabase.auth.signInWithPassword(email, password)`.  
- No RLS bypasses; all policies rely on `auth.uid()` as for any user.

R4 — Paywall/entitlement guard  
- Reviewer’s active home must be placed on a plan that unblocks Flows/Bills (manual “premium” set via Supabase is acceptable).  
- No reviewer-only overrides; use the normal plan/entitlement mechanism.

## 5) Lifecycle / Operations
- Provisioning: create the Auth user (email/password), mark confirmed, verify `profiles` row.  
- Credential storage: store email/password in app-store submission notes and the team secret manager.  
- Rotation: none planned; if ever rotated, update store notes and rerun provisioning checks.  
- Reset: admin updates password via Supabase Auth admin/API; re-verify confirmation + profile linkage after reset.  
- Plan setting: manually set reviewer home to premium (or equivalent) before sharing credentials.  
- Data seeding: optional; reviewer may self-create data in-app. Backend does not ship seed fixtures.

## 6) Acceptance Criteria
- Reviewer logs in via email/password without third-party prompts or confirmation blocks.  
- Standard session established (`auth.uid()` present; RLS behaves normally).  
- Profile row exists and matches the Auth user.  
- Reviewer home is on a plan that exposes Flows/Bills; no reviewer-only flags exist.  
- Hidden entry instructions are present in store notes (client-owned), not enforced by backend.

## 7) Operations Runbook (Reviewer Account)
1) Provisioning: create the reviewer Auth user (email/password) and mark confirmed; verify `public.profiles` row exists (`profiles.id = auth.users.id` and `profiles.email` matches).  
2) Plan: ensure the reviewer’s current home has `home_entitlements.plan = 'premium'` (or equivalent) so Flows/Bills are reachable.  
3) Credentials: store email/password in App Store Connect / Play Console review notes and the team secret manager.  
4) Hidden entry note: include “Tap Kinly logo 7 times on login to open Reviewer Login, then use the provided email/password.” in store notes.  
5) Reset (if ever needed): update password via Supabase Auth admin/API, keep the account confirmed, and re-verify profile linkage + premium plan afterward.
