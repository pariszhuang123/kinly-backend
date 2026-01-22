# Context-Aware Paywall v1 (Personalized Primary Benefit)

Owner: Kinly  
Scope: Paywall UI + paywall gate payload + deterministic benefit ordering.  
Non-goals: Pricing experiments, multiple paywall screens, backend-driven benefit ordering.

## Goal
When the paywall opens, the first benefit the user sees should match the cap/intent that triggered the paywall. Remaining benefits stay stable and deduped.

Examples
- Triggered by **members cap** → first benefit highlights **Unlimited members**.
- Triggered by **flow cap** → first benefit highlights **Unlimited active flows** (and **flow photos** if the blocked action was photo-related).

## Definitions

### Shared enum: PaywallTrigger
Shared by feature BLoCs and paywall UI (Dart location: `lib/core/paywall/enums/paywall_trigger.dart`).
- `flowActiveCap`
- `flowPhotosCap`
- `expenseActiveCap`
- `membersCap`

### Benefit groups (canonical order)
1. `flow`
2. `flow_photos`
3. `expenses`
4. `members`

Benefit-to-group mapping (UI strings already exist):
- `paywallBulletFlows` → `flow`
- `paywallBulletPhotos` → `flow_photos`
- `paywallBulletShares` → `expenses`
- `paywallBulletMembers` → `members`

### Trigger → primary group mapping
- `flowActiveCap` → [`flow`] (add `flow_photos` too when the blocked action included photo upload/preview).
- `flowPhotosCap` → [`flow_photos`].
- `expenseActiveCap` → [`expenses`].
- `membersCap` → [`members`].

### Stacking rules
If multiple caps are hit before the paywall is dismissed, stack all triggers for the session.
1. Collect all triggers into `context.triggers` (set semantics).
2. Map each trigger to its primary groups (see mapping above).
3. Union and dedupe the resulting groups.
4. Sort primary groups by canonical order (flow → flow_photos → expenses → members).
5. Render benefits in two phases:
   - Primary benefits: benefits whose group is in the primary set, ordered by canonical group order.
   - Secondary benefits: remaining benefits, ordered by canonical group order.
6. Never duplicate a benefit.

Pseudo:
```
primaryGroups = sortByPriority(unique(flatMap(triggers => PRIMARY_GROUPS_BY_TRIGGER[trigger])))
primaryBenefits = benefits.filter(b => primaryGroups.contains(b.group)).sortByGroupPriority()
secondaryBenefits = benefits.filter(b => !primaryGroups.contains(b.group)).sortByGroupPriority()
orderedBenefits = primaryBenefits + secondaryBenefits
```

## Client contract
- Feature BLoCs MUST surface the triggering `Set<PaywallTrigger>` alongside existing paywall gate request data. If a flow action involved photos, include `flowPhotosCap` in addition to `flowActiveCap`.
- Paywall UI MUST apply the ordering rules above before rendering the benefit checklist. When no triggers are provided, fall back to canonical order.
- Paywall event logging SHOULD include `triggers`, `primary_groups`, and `ordered_benefit_groups` in the event metadata (sent via `source`/payload) to keep analytics aligned with UI behavior.

## Backend suggestion (minimum to support this)
- Ensure paywall-blocking RPCs return a machine-readable `error_code` that maps 1:1 to `PaywallTrigger` values (`flow_active_cap`, `flow_photos_cap`, `expense_active_cap`, `members_cap`) so feature BLoCs can populate `context.triggers` deterministically.
- No new tables are required. Optionally extend `paywall_log_event` payload to accept `triggers`/`primary_groups` metadata for funnel analysis; otherwise encode the trigger in the existing `source` field (e.g., `flow_active_cap`).
- Keep canonical benefit definitions and ordering client-side (per non-goal: no backend-driven ordering).
