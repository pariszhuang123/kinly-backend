---
Domain: MONETIZATION
Capability: Premium Paywall
Scope: shared
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

# Kinly Premium Paywall — Phase 1 Contract

Scope: Paywall UI/flows, RevenueCat integration, Supabase sync, and telemetry for the home-only MVP.

## Goals (v1)
- Upgrade flow that feels trustworthy, priced as “<0.5% of rent,” and matches Kinly primitives.
- Any member can fund the home; multiple subs per home are allowed; the home is premium if any attached sub is active/cancelled and unexpired (max expiry wins).
- No Settings entry; paywall appears only when a free-tier quota would be exceeded.
- Only standard monthly package; no trials/intro offers in v1.

## RevenueCat Mapping
- Offering: `main`
- Package: `monthly`
- Product IDs: `com.makinglifeeasie.kinly.premium.monthly` (iOS + Android)
- Entitlement: `kinly_premium`
- `app_user_id`: Supabase auth user id (stable across homes)
- Subscriber attributes (best-effort): `home_id`, `locale`, `email?`
- Price UI uses `package.storeProduct.priceString` (do not hard-code).

## Entry & Eligibility
- Show paywall when: (`home_entitlements.plan = 'free'` OR `expires_at <= now()`) AND the requested action would exceed `home_plan_limits` for that metric.
- Trigger sources: exceeding free limits on flows=chores, shares=expenses, flow photos=chore_photos. No explicit entry in Settings.
- Always scrollable, full screen; dismiss via “Continue with free home.”

## Messaging & UI Requirements
- Hero: “Bring more harmony to your home for less than 0.5% of your rent”
- Subtitle: “One simple monthly price per home. Everyone inside gets Premium.”
- Feature bullets:
  - Unlimited home members
  - Unlimited active flows (chores)
  - Unlimited flow photos (chore photos)
  - Unlimited active shares (expenses)
- CTAs: Primary “Upgrade to Kinly Premium”, Secondary “Continue with free home.”
- Use Kinly primitives (buttons, loader, snackbar), directionality-safe, i18n via `S.of(context)`, respects dark/light + text scaling. No raw Material buttons or `CircularProgressIndicator`.

## Funding & Entitlement Rules
- Any current member may purchase. Subscriptions attach to the purchaser’s current home (via `_home_attach_subscription_to_home` on join) and detach on leave. `user_subscriptions.home_id` stays nullable for “floating” subs.
- Home is premium if any attached subscription is `active` or `cancelled` and not expired (`expires_at` NULL or future). If the last funding member leaves, `home_entitlements` downgrades to free.
- Multiple subs per home allowed; `home_entitlements` uses the max `current_period_end_at` across attached subs.
- No manual Supabase “premium flag”; `home_entitlements` is derived from subscriptions.

## Data Model (existing + new)
- Reuse: `home_plan_limits` (free caps), `home_usage_counters` (cached active_chores/chore_photos/active_expenses/active_members), `home_entitlements`, `user_subscriptions` (keep `home_id` nullable).
- New table: `revenuecat_webhook_events`
  - Columns: id uuid PK default gen_random_uuid(), received_at timestamptz default now(), event_timestamp timestamptz, environment text, rc_event_id text, rc_app_user_id text, entitlement_id text, entitlement_ids text[] NULL, product_id text, store subscription_store, status subscription_status, current_period_end_at timestamptz, original_purchase_at timestamptz, last_purchase_at timestamptz, latest_transaction_id text, original_transaction_id text, home_id uuid NULL, raw jsonb, error text NULL, error_code text NULL.
  - Indexes: UNIQUE (environment, rc_event_id) where rc_event_id is not null; non-unique on latest_transaction_id and original_transaction_id where not null.
  - Access: service role only (REVOKE anon/authenticated).
- New table: `paywall_events`
  - Columns: id uuid PK default gen_random_uuid(), user_id uuid references profiles, home_id uuid references homes, event_type text check (event_type in ('impression','cta_click','dismiss','restore_attempt')), source text (e.g., 'chore_cap','expense_cap','photo_cap'), created_at timestamptz default now().
  - Access: service role only (REVOKE anon/authenticated). Insert path via backend when BLoC logs events.

## Backend Functions (Supabase)
- Reuse: `_home_attach_subscription_to_home`, `_home_detach_subscription_to_home`, `home_entitlements_refresh` (keeps plan/expires_at in sync, max expiry wins).
- New SEC-DEFINER `paywall_record_subscription(...)` (service role only):
  - Inputs: user_id, home_id NULLABLE, store, rc_app_user_id, entitlement_id, entitlement_ids[], product_id, status, current_period_end_at, original_purchase_at, last_purchase_at, latest_transaction_id, rc_event_id, original_transaction_id, event_timestamp, environment, raw, error, error_code.
  - Behavior: upsert `user_subscriptions` on (user_id, rc_entitlement_id); update status/expiry/product/transaction ids/app_user_id/home_id/last_synced_at/updated_at; call `home_entitlements_refresh(home_id)` when provided; insert audit row into `revenuecat_webhook_events` with idempotency on (environment, rc_event_id).
- New auth-required `paywall_get_status(home_id uuid)`:
  - Returns: `{ plan, expires_at, usage: {...from home_usage_counters...}, limits: array of {metric, max_value} for the current plan (free/premium) }`.
  - Consumers: Flutter repos to decide paywall vs proceed.

## Edge Function (Deno) `revenuecat_webhook`
- Auth: shared secret header (RC webhook secret). Reject if missing/invalid.
- Parse RC event payload (event-first). Subscriber attributes are read from `event.subscriber_attributes`. User resolution order: `event.subscriber_attributes.user_id.value` → `event.app_user_id` if UUID → first UUID in `event.aliases`. Home resolution: `event.subscriber_attributes.home_id.value` (nullable).
- Entitlement resolution: `event.entitlement_ids[0]` primary; fallbacks: payload.entitlement_ids[0], event.entitlement_id, payload.entitlement_id. Store full array in audit.
- Idempotency: insert audit first keyed on (environment, rc_event_id); if unique violation, return 200 `{ ok: true, deduped: true }` and skip RPC. `latest_transaction_id` kept for correlation only.
- Error handling: always log audit. If user/entitlement/product missing, return 200 `{ ok: true, ignored: true, error: <code> }`, no RPC. Missing home_id or latest_transaction_id are non-fatal warnings (still call RPC, log `error_code`).
- Call `paywall_record_subscription` with service key when actionable. RPC failures log audit with `error_code = rpc_failure` and return 200.

## Client Responsibilities (Flutter)
- Repository: `getPaywallStatus(homeId)` → `paywall_get_status`; `purchasePremium(homeId)` → RevenueCat flow; log paywall events (impression/CTA/dismiss/restore).
- BLoC/UI:
  - Show loader while fetching offerings; retry state on failure.
  - On upgrade: set RC subscriber attributes (user_id, locale, home_id), call `purchasePackage(monthly)`, refresh entitlements. Webhook updates Supabase; UI shows success snackbar and closes.
  - On failure/cancel: Kinly snackbar “Purchase not completed — you can try again anytime.”
  - Optional “Restore purchases” action to re-fetch entitlements.
  - Price string from RC, not hard-coded.

## Analytics & Ops
- Supabase audit: `revenuecat_webhook_events` for every webhook; `paywall_events` for funnel (impression, CTA click, dismiss, restore).
- Subscription snapshot: `user_subscriptions` remains the live cache; `home_entitlements` is the fast plan check.
- Downgrade/upgrade automation: handled via triggers (`home_entitlements_refresh`) when subs attach/detach or expire.

## Definition of Done (paywall slice)
- Migration adds tables + functions + RLS/permissions.
- Edge function deployed for RC webhook, validates secret, writes audit, calls RPC.
- Flutter paywall screen uses Kinly primitives, i18n, directionality-safe, shows RC price string, and handles success/failure/dismiss.
- Repositories/BLoC integrate `paywall_get_status` and RevenueCat purchase/restore.
- Tests: unit for RPC (pgtap/sql), paywall BLoC/repo, widget smoke for paywall. Strings via `S.of(context)`. Format/lint/tests green.
