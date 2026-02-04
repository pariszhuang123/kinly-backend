# Daily Notifications — Phase 1 (Kinly)

Goal: send at most one gentle daily nudge per user per local day (per active device token) when Today has meaningful content, respecting opt-in, OS permission, timezone, and device token availability. Default reminder time is 9:00am local. Implemented via migrations `20251203103000_notifications_daily.sql`, `20251227090000_notifications_preferred_minute.sql`, `20260323090000_notifications_daily_window.sql`, and Edge Function `notifications_daily`.

## 1) Entry point and opt-in
- Trigger: after the first chore (Flow) creation, app asks “daily reminder when your day is ready?” (yes/no).
- Data captured on answer: `wants_daily`, `preferred_hour = 9`, `preferred_minute = 0`, `timezone` (IANA), `locale`, `os_permission` (allowed/blocked/unknown), current device `token`.
- If “no”: store tz/locale but `wants_daily = false`.

## 2) Data model (Supabase)
- `notification_preferences`
  - `user_id (pk)`, `wants_daily bool`, `preferred_hour int` (default 9), `preferred_minute int` (default 0), `timezone text`, `locale text`, `os_permission text`, `last_os_sync_at timestamptz`, `last_sent_local_date date`, `created_at`, `updated_at`.
- `device_tokens`
  - `id uuid`, `user_id`, `token text`, `provider text` (fcm), `platform text`, `status text` (active/revoked/expired), `last_seen_at timestamptz`, `created_at`, `updated_at`.
  - Multiple active tokens allowed. Mark prior token revoked on logout/uninstall/rotation; mark expired on server if FCM reports unregistered/invalid. Unique token constraint enforced.
- Helpers
  - `today_has_content(user_id, tz, local_date)` SECURITY DEFINER; impersonates the user (via `request.jwt.claim.sub`) and reuses the existing RPCs to avoid duplicated logic. Uses the caller’s current home membership (enforced by membership uniqueness).
  - `notifications_daily_candidates(limit, offset)` SECURITY DEFINER; paged eligible rows for the scheduler (service role) using server-side tz + preferred time window + content check.
- `notification_sends`
  - `id uuid`, `user_id`, `token_id`, `local_date date`, `job_run_id text`, `status text` (reserved/sent/failed), `error text`, `created_at`.
  - Unique index on (`token_id`, `local_date`) to prevent duplicate sends per device per local day.

## 3) Client responsibilities
- Opt-in flow: upsert `notification_preferences` + add/activate device token with captured tz/locale/os_permission (direct table writes under RLS; not via RPC).
- Startup/login: re-check OS permission, refresh token, upsert preferences + device token, set `last_os_sync_at`.
- Logout/uninstall/token change: mark previous token `revoked`; app supplies new token on next launch.
- Token expiration: if FCM rotates/invalidates a token, the next send attempt will fail; backend marks `status = expired/revoked` and the client must provide a fresh token before pushes resume.
- Token optionality: client may sync prefs without a token (permission denied/unavailable); eligibility requires an active token, so backend skips until a token is stored.

## 4) Scheduled sender (Edge Function)
- Runs every 15 minutes with service role credentials (bypasses RLS).
- Steps:
  1) Select eligible users via `notifications_daily_candidates`.
  2) For each, record idempotent send row (reserve) before sending.
  3) Send via FCM HTTP v1 (service account from secrets) with Today deep-link payload.
  4) On `unregistered`/`invalid` errors, mark token `expired` and continue; on transient errors, keep token active and mark send `failed`.
  5) Structured logs for observability (eligible count, sent count, failed count, token_expired count, latency).
- Implementation notes: `notifications_daily` uses OAuth JWT with `FCM_SERVICE_ACCOUNT` JSON and optional `FCM_PROJECT_ID`; paged querying and send reservation are built in.

## 5) Eligibility rules (Phase 1)
- `wants_daily = true`.
- `os_permission = allowed`.
- Has ≥1 active device token.
- `local_time(user.timezone)` is within `[preferred_time, preferred_time + 15 minutes]` at job run (15-minute cadence provides the delivery window).
- `last_sent_local_date < today(user.timezone)` (or null) to avoid multiple sends per local day.
- `today_has_content(user_id, timezone, local_date)` returns true (see Section 6).

## 6) “Today has content” (server-side signal)
- Use existing RPCs as source of truth:
  - `public.today_flow_list(user_id, local_date, tz)`.
  - `public.expenses_get_current_owed(user_id, local_date, tz)`.
  - `public.expenses_get_created_by_me(user_id, local_date, tz)`.
  - `public.gratitude_wall_status(user_id, local_date, tz)`.
- Implement helper `public.today_has_content(user_id uuid, tz text, local_date date)` that returns boolean:
  - True if any of the four RPCs return at least one meaningful row (respect existing draft/active filters from each RPC).
  - Implement as a SQL helper (view or SQL function) that internally calls the RPCs or their underlying queries to avoid duplicated logic.
  - Add supporting indexes on source tables that back the RPCs (e.g., `(user_id, due_on, status)`, `(user_id, is_unread)` as applicable) so the 15-minute scan stays within p95 budget.
  - If RPCs already denormalize into materialized views, reuse those; do not add separate per-user joins in the Edge Function.

## 7) Message construction
- Template map inside the Edge Function keyed by locale with fallback to `en`.
- Short, kind copy only; Phase 1 avoids personalization. Example: “Your day is ready ✨ Tap to see what’s waiting.”
- Payload includes deep-link to Today screen.

## 8) Idempotency and timing
- Ledgered via `notification_sends`; retries are safe because eligibility checks `last_sent_local_date < today` and reservations are unique per `token_id + local_date`.
- `local_date` and `local_time` computed server-side using stored `timezone`; timezone changes take effect on next client sync.
- If a run fails at the preferred time, later runs within the 15-minute window can still deliver; after first successful send, later runs skip.
- Verify uniqueness: unique index on (`token_id`, `local_date`) to prevent duplicate sends per device per local day.

## 9) RLS and security
- App RLS: a user can only upsert/read their own `notification_preferences` and `device_tokens`.
- Edge Function uses service role to read eligibility and write `notification_sends`.
- Secrets: FCM service account stored in Supabase secrets; no client access.

## 10) Non-goals (Phase 1)
- No manual timezone override.
- No campaigns/streaks/weekly digests.
- No per-item personalization in notification text.

## Verification (pre-merge / CI checklist)
- Schema: apply constraints/indexes for `notification_sends` uniqueness and token status; ensure RLS policies for prefs/tokens exist.
- Linters/checks: `dart format`, `dart analyze`, `dart run tool/check_i18n.dart`, `dart run tool/check_directionality.dart`, `dart run tool/check_enums.dart`.
- Backend: manual or automated test for eligibility query and `today_has_content` helper; ensure scheduler job succeeds in dry-run with sample data.
- Notifications: simulate `unregistered` token response to confirm backend marks token expired and does not retry it until client refreshes token.
