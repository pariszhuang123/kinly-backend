# Contracts Changelog

Tracks versioned contract changes and related ADRs.

## v1.0.0 - App Store Reviewer Access
- Date: 2026-01-23
- Scope: `docs/contracts/app_store_reviewer_access_v2.md`
- Changes:
  - Adds deterministic reviewer login contract (email/password, confirmed Supabase user, standard profile link).
  - Requires reviewer home to use normal plan/entitlement (premium) rather than reviewer-only flags.
  - Documents lifecycle/runbook for credential storage, optional rotation, and manual plan setting; no backend seeding shipped.

## v1 - Gratitude Wall (Shared + Personal)
- Date: 2026-01-17
- Scope: `docs/contracts/gratitude_wall_v1.md`
- Changes:
  - Document ambient, identity-suppressed gratitude wall guardrails for shared and personal surfaces.
  - Add safety constraints on layout, metrics, sarcasm handling, and weekly ephemerality to avoid weaponisation.
  - Note interop with mentions pipelines to strip identity and counts on shared surfaces.

## v2 - Chores Recurrence Every/Unit
- Date: 2026-01-04
- Scope: `docs/contracts/chores_v2.md`
- Changes:
  - Replace `RecurrenceInterval` enum usage at the API boundary with `recurrenceEvery` + `recurrenceUnit`.
  - Add v2 RPCs for create/update (`public.chores_create_v2`, `public.chores_update_v2`).
  - Update chores read payloads to return `recurrenceEvery/recurrenceUnit`.

## v1 - Home Preferences, Vibe, and Rules
- Date: 2026-01-05
- Scope: `docs/contracts/home_dynamics_v1.md`
- Changes:
  - Define the separation between personal preferences, home vibe, and home rules.
  - Add hard guardrails to prevent auto-derivation or enforcement from vibe or preferences.

## v1 - Hub Personal Preferences Visibility
- Date: 2026-01-06
- Scope: `docs/contracts/hub_personal_preferences_visibility_v1.md`
- Changes:
  - Define Hub visibility rules for personal preference reports.
  - Enforce published-only visibility and subject-only edits.
  - Disallow progress indicators, placeholders, or enforcement cues.

## v1 - Preference Taxonomy
- Date: 2026-01-05
- Scope: `docs/contracts/preference_taxonomy_v1.md`
- Changes:
  - Define preference taxonomy v1 domains, IDs, aggregation rules, and governance.

## v1 - Preference Scenarios
- Date: 2026-01-05
- Scope: `docs/contracts/preference_scenarios_v1.md`
- Changes:
  - Define scenario-based preference capture and interpretation rules.

## v1 - Preference Reports
- Date: 2026-01-05
- Scope: `docs/contracts/preference_reports_v1.md`
- Changes:
  - Define generation, subject edits, and revision tracking for preference reports.
  - Align contract with preference taxonomy tables, template schema, and RPCs.
  - Sync template schema to value_key/title/text and section title/text structure.

## v1 - Avatar Identity
- Date: 2026-01-06
- Scope: `docs/contracts/kinly_avatar_identity_v1.md`
- Changes:
  - Define progressive identity disclosure for avatar selection and commitment.
  - Require visible display names on selection/focus and persisted on commit.
  - Codify accessibility semantics for avatar identity cues.

## v2 - Expenses Recurrence Every/Unit
- Date: 2026-01-15
- Scope: `docs/contracts/expenses_v2.md`
- Changes:
  - Replace `recurrenceInterval` enum with `recurrenceEvery` + `recurrenceUnit` (day|week|month|year).
  - Add v2 RPCs for create/edit (`public.expenses_create_v2`, `public.expenses_edit_v2`).
  - Update expense read payloads to return recurrenceEvery/Unit.

## v1 - Design System Umbrella
- Date: 2026-01-05
- Scope: `docs/contracts/kinly_design_system_v1.md`, `docs/contracts/kinly_composable_system_v1.md`, `docs/contracts/architecture_guardrails_amendment_foundation_surfaces_v1.md`
- Changes:
  - Add umbrella Design System contract referencing token/color contracts.
  - Add renderer boundary + enforcement references to the Composable System contract.
  - Add renderer boundary to the Architecture Guardrails amendment.
  - Extend design system lint to detect `material.dart` imports outside `lib/renderer/**`.
  - Add baseline snapshot support and flip CI to fail on new violations only.

## v1 - Foundation Composable System
- Date: 2026-01-02
- Scope: `docs/contracts/kinly_composable_system_v1.md`
- Changes:
  - Define composable units, surfaces, slots, and registry-based feature composition.
  - Add CI lint in warning mode (`tool/check_composable_system.dart`) with a migration plan to strict enforcement.
  - Add initial audit checklist in `docs/engineering/composable_system_audit_v1.md`.

## CODEX-L10N-001 -- Codex i18n Hygiene
- Date: 2025-12-24
- Scope: `docs/contracts/codex_i18n_hygiene.md`
- Changes:
  - Define canonical EN source (`lib/l10n/intl_en.arb`) and enforce no unused keys or invalid references.
  - Add `tool/l10n_integrity_check.dart` with optional non-EN drift enforcement.
  - Wire the new check into CI and AGENTS merge checklist.

## v1 — Expenses MVP
- Date: 2025-11-20
- Scope: `docs/contracts/expenses_v1.md`
- Changes:
  - Define `Expense`, `ExpenseSplit`, and `ExpenseSummaryDto` entities plus enums.
  - Document lifecycle (draft → active → cancelled), debtor-only payments, derived summary fields, and access patterns.
  - 2025-11-21: Capture Supabase requirements: tables, grants, and RPCs (`expenses.create`, `expenses.edit`, `expenses.markSharePaid`, `expenses.cancel`, `expenses.getCurrentOwed`, `expenses.getCreatedByMe`). Tables remain RPC-only with RLS disabled + GRANT revokes per ADR-0003 (`docs/adr/ADR-0003-expenses-rpc-only-access.md`).
  - 2025-11-22: Allow creators to participate in equal/custom splits (creator rows persisted but auto-marked `paid`; at least one non-creator debtor required; each active expense involves two unique members).
  - 2025-12-22: Add “Who paid me” recipient view state (`expense_splits.recipient_viewed_at`) and RPCs for Today + drilldown (`expenses.getCurrentPaidToMeDebtors`, `expenses.getCurrentPaidToMeByDebtorDetails`, `expenses.markPaidReceivedViewedForDebtor`). Existing paid splits remain unseen (no backfill) to surface badges during testing; creator auto-paid splits are excluded from paid-to-me responses.
  - 2025-12-23: Paid-to-me RPCs return debtor avatar + owner flag (`homes.owner_user_id` match) in both list and drilldown payloads.
  - 2025-12-27: Fold recurring activation into `expenses.create`/`expenses.edit`, add `expense_plans` + `expense_plan_debtors`, introduce `expense_status=converted` and `expense_plan_status`, add `expenses.payMyDue` bulk payment, make active expenses immutable, store `fully_paid_at` for idempotent quota decrements, and update `docs/contracts/share_recurring_v1.md`.
- Notes: Home members can author expenses; drafts stay private; Today/Explore surfaces consume the summary RPCs.

## v2 – Homes Memberships/Invites Alignment
- Date: 2025-11-11
- Scope: `docs/contracts/homes_v2.md`
- Changes:
  - Replace `Member` with append-only `Membership` stints (validFrom/validTo/isCurrent).
  - Enforce: one current membership per user across homes; one current owner per home; no overlap per (user, home).
  - Invites: `code` is `CITEXT` with Crockford Base32 (6 chars) and added `usedCount`; removed `updatedAt`.
  - RLS: enabled on `homes`, `memberships`, and `invites`; anon/auth revoked on tables.
  - Deprecate `members.listByHome` in favor of `members.listActiveByHome` (only active members are used by clients).
- Notes: Contracts reflect migration `20251111225015_home_membership_invites_table.sql`. Repositories should pin to v2.

## v1 — Home MVP
- Date: 2025-11-03
- Scope: `docs/contracts/homes_v1.md`
- Highlights: Permanent invite codes (revokable; invalid on home deactivation).
- ADR: `docs/adr/ADR-0002-invites-permanent-codes.md`
- Notes: Repositories/BLoC pin to v1. Breaking changes must create `homes_v2.md` and a new ADR.

## v1 — Users/Avatars Alignment
- Date: 2025-11-10
- Scope: `docs/contracts/users_v1.md`
- Changes:
  - Align registry and users_v1 contracts with migrations:
    - Add `Avatar` entity (id, storagePath, category, name, createdAt).
    - Update `UserProfile` (id, email, fullName, avatarId, createdAt, deactivated_at).
  - RLS documented:
    - `public.profiles`: self-select only; client writes revoked.
    - `public.avatars`: SELECT for authenticated users.
  - `users.selfDelete` effects text updated to remove future-state fields.
- Notes: Extractor and registry in sync; validator passing.
