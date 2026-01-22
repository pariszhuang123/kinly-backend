# Member Cap Paywall (v1)

Scope: Member cap enforcement for free homes and the blocked-join handoff to owners.

## Goals
- Free homes honor the active member cap from `public.home_plan_limits` (`active_members` row per plan).
- Joiners never see pricing and are never asked to pay.
- Owners see the blocked join and can upgrade; after upgrade, eligible pending joins are resolved automatically.

## Data & Sources of Truth
- Plan: `public.home_entitlements.plan` (text; `free`/`premium*`), refreshed by `home_entitlements_refresh`.
- Cap: `public.home_plan_limits` (`plan`, `metric = 'active_members'`, `max_value`).
- Usage: `public.home_usage_counters.active_members` (kept via `_home_usage_apply_delta`).
- Existing RPC to reuse: `public.homes_join(code)`; paywall/status surface: `public.paywall_status_get(home_id)`; owner surfacing: `public.today_onboarding_hints()`; entitlement change hook: `public.home_entitlements_refresh`.

### New table (proposed)
`public.member_cap_join_requests`
- `id uuid PK default gen_random_uuid()`
- `home_id uuid references public.homes(id) on delete cascade`
- `joiner_user_id uuid references public.profiles(id) on delete cascade`
- `created_at timestamptz default now()`
- `resolved_at timestamptz null`
- `resolved_reason text null check (resolved_reason in ('joined','joiner_superseded','home_inactive','invite_missing','owner_dismissed'))`
- `resolved_payload jsonb null` (e.g., invite code used, message shown)
- Unique partial index on (`home_id`, `joiner_user_id`) where `resolved_at` is null (prevents spam/duplicates).
- RLS: table locked down (no anon/auth grants); all app access goes through sec-definer RPCs.

## Flow: Joiner (blocked)
1) `homes_join(code)` keeps current guards: auth + active profile, invite exists/not revoked, home active, unique avatar, single active membership.
2) Before `_home_assert_quota(active_members: 1)`, fetch current plan + active_members usage (lock `homes` + `home_usage_counters` to avoid race).
3) If plan is premium -> proceed as today (no cap).
4) If free and projected `active_members` would exceed `home_plan_limits.max_value`:
   - Insert/refresh `member_cap_join_requests` (idempotent on `home_id + joiner_user_id`).
   - Return structured result (no paywall copy): `{ status: 'blocked', code: 'member_cap', message: 'Home is not accepting new members right now. We notified the owner.', home_id, request_id }`.
   - Do not increment counters or memberships; do not show pricing.

## Flow: Owner surfacing
- On cap hit, surface once per pending request batch (per home) to owner.
- Recommended surface: extend `today_onboarding_hints()` to include `memberCapJoinRequests` when:
  - caller is the home owner,
  - home plan is free,
  - `member_cap_join_requests` has unresolved rows,
  - caller still holds that home (no current membership elsewhere).
- Hint payload: `{ homeId, pendingCount, joinerNames: [up to N oldest usernames], requestIds: [...] }` (names read live from `profiles.username`).
- Dismiss/ignore: mark `resolved_at` + `resolved_reason = 'owner_dismissed'` for all unresolved rows for that home, so the card disappears until the next blocked join.

## Flow: Resolution after upgrade
- Hook: when `home_entitlements_refresh` transitions plan from free -> premium (or expires_at extends), call a helper to process pending member-cap requests.
- Processing (oldest first):
  1) Fetch active invite for the home (create one if none exists).
  2) For each pending request:
     - Skip/mark `joiner_superseded` if the joiner already has a current membership (any home).
     - Skip/mark `home_inactive` if the home was deactivated.
     - Skip/mark `invite_missing` if no active invite exists/can be created.
     - Otherwise, perform the same safety checks as `homes_join`: `_assert_active_profile` for the joiner, `_ensure_unique_avatar_for_home`, membership uniqueness, increment `home_usage_counters.active_members` (premium bypasses cap but still tracks usage), increment invite `used_count`, attach subscription via `_home_attach_subscription_to_home`.
     - Insert membership (role `member`, valid_from now()).
     - Mark request `resolved_reason = 'joined'`, store `resolved_payload` with the invite code used.
- No pricing copy; no retries needed on the client. This keeps the queue consistent after upgrade and prevents orphaned requests.

## Suggested Guards (why)
- Home active (`homes.is_active = true`): matches join semantics; avoids reviving deactivated homes.
- Invite active (not revoked, home active): maintains a single source of truth for eligibility and ensures `used_count` stays accurate.
- Unique pending per (home, joiner): prevents spam and simplifies owner UI.
- Joiner must still be membership-free when resolving: respects “one active home” invariant.
- Cleanup: when a user joins/leaves manually, expire any pending requests for that user/home to avoid stale cards.

## Surfaces / RPCs to touch first
- `homes_join(code)`: add cap-aware pending request path + structured blocked response.
- `today_onboarding_hints()`: add owner card data for pending member-cap requests.
- `paywall_status_get(home_id)`: optionally include `active_members` usage + cap so the paywall UI can show “at cap” state without new endpoints.
- `home_entitlements_refresh`: add post-upgrade resolver for pending join requests.

## Non-goals / Notes
- No use of `paywall_events` for blocked joins (keep funnel telemetry separate).
- No push/email; in-app only.
- Joiner-facing copy stays neutral (no pricing, no upgrade ask).
