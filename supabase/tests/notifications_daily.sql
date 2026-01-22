SET search_path = pgtap, public, auth, extensions;

-- pgTAP tests for notifications daily migration
BEGIN;
SELECT plan(31);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_tokens (
  label     text PRIMARY KEY,
  token_id  uuid,
  user_id   uuid
);

-- Stub today_has_content so we can deterministically include/exclude users
CREATE OR REPLACE FUNCTION public.today_has_content(
  p_user_id    uuid,
  p_timezone   text,
  p_local_date date
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_user_id <> '20000000-0000-4000-9000-000000000002'::uuid;
$$;

-- Seed a default avatar so handle_new_user can create profiles
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('20000000-0000-4000-9000-000000000900', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- Seed auth users (profiles auto-created via trigger)
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('eligible',        '20000000-0000-4000-9000-000000000001', 'eligible-notify@example.com'),
  ('no_content',      '20000000-0000-4000-9000-000000000002', 'no-content-notify@example.com'),
  ('expired_token',   '20000000-0000-4000-9000-000000000003', 'expired-notify@example.com'),
  ('reserve_target',  '20000000-0000-4000-9000-000000000004', 'reserve-notify@example.com'),
  ('success_target',  '20000000-0000-4000-9000-000000000005', 'success-notify@example.com'),
  ('failure_target',  '20000000-0000-4000-9000-000000000006', 'failure-notify@example.com'),
  ('minute_mismatch', '20000000-0000-4000-9000-000000000007', 'minute-mismatch@example.com');

INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  email,
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
FROM tmp_users
ON CONFLICT (id) DO NOTHING;

-- 1) Tables exist
SELECT has_table(
  'public',
  'notification_preferences',
  'notification_preferences table exists'
);

SELECT has_table(
  'public',
  'device_tokens',
  'device_tokens table exists'
);

SELECT has_table(
  'public',
  'notification_sends',
  'notification_sends table exists'
);

-- 2) Columns sanity
SELECT has_column(
  'public',
  'notification_preferences',
  'preferred_hour',
  'preferred_hour column exists on notification_preferences'
);

SELECT has_column(
  'public',
  'notification_preferences',
  'preferred_minute',
  'preferred_minute column exists on notification_preferences'
);

SELECT has_column(
  'public',
  'device_tokens',
  'token',
  'token column exists on device_tokens'
);

SELECT has_column(
  'public',
  'device_tokens',
  'status',
  'status column exists on device_tokens'
);

SELECT has_column(
  'public',
  'notification_sends',
  'local_date',
  'local_date column exists on notification_sends'
);

SELECT has_column(
  'public',
  'notification_sends',
  'status',
  'status column exists on notification_sends'
);

SELECT has_column(
  'public',
  'notification_sends',
  'token_id',
  'token_id column exists on notification_sends'
);

-- 3) Unique per token per local_date when sent
SELECT ok(
  (
    SELECT COUNT(*)
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_notification_sends_token_date'
  ) = 1,
  'unique index for token per day exists'
);

-- 4) RLS enabled on prefs/tokens
SELECT ok(
  (
    SELECT relrowsecurity
    FROM pg_class
    WHERE relname = 'notification_preferences'
  ) = true,
  'RLS enabled on notification_preferences'
);

SELECT ok(
  (
    SELECT relrowsecurity
    FROM pg_class
    WHERE relname = 'device_tokens'
  ) = true,
  'RLS enabled on device_tokens'
);

-- 5) Helper functions exist
SELECT has_function(
  'public',
  'today_has_content',
  ARRAY['uuid','text','date']
);

SELECT has_function(
  'public',
  'notifications_daily_candidates',
  ARRAY['integer','integer']
);

-- Seed preferences + tokens for candidate selection (current hour)
WITH now_parts AS (
  SELECT
    date_part('hour', timezone('UTC', now()))::int   AS current_hour,
    date_part('minute', timezone('UTC', now()))::int AS current_minute,
    timezone('UTC', now())::date                     AS current_date
)
INSERT INTO public.notification_preferences (
  user_id,
  wants_daily,
  preferred_hour,
  preferred_minute,
  timezone,
  locale,
  os_permission,
  last_os_sync_at,
  last_sent_local_date,
  created_at,
  updated_at
)
SELECT
  u.user_id,
  TRUE,
  np.current_hour,
  np.current_minute,
  'UTC',
  'en',
  'allowed',
  now(),
  np.current_date - INTERVAL '1 day',
  now(),
  now()
FROM tmp_users u
CROSS JOIN now_parts np
WHERE u.label IN ('eligible', 'no_content', 'expired_token', 'success_target', 'failure_target');

-- Seed a user whose minute is offset so they should not be in candidates
WITH now_parts AS (
  SELECT
    date_part('hour', timezone('UTC', now()))::int   AS current_hour,
    date_part('minute', timezone('UTC', now()))::int AS current_minute
)
INSERT INTO public.notification_preferences (
  user_id,
  wants_daily,
  preferred_hour,
  preferred_minute,
  timezone,
  locale,
  os_permission,
  last_os_sync_at,
  last_sent_local_date,
  created_at,
  updated_at
)
SELECT
  u.user_id,
  TRUE,
  np.current_hour,
  (np.current_minute + 1) % 60,
  'UTC',
  'en',
  'allowed',
  now(),
  NULL,
  now(),
  now()
FROM tmp_users u
CROSS JOIN now_parts np
WHERE u.label = 'minute_mismatch';

-- Keep success/failure users out of candidate list while still allowing status updates
UPDATE public.notification_preferences
SET wants_daily = FALSE, os_permission = 'blocked'
WHERE user_id IN (
  '20000000-0000-4000-9000-000000000005',
  '20000000-0000-4000-9000-000000000006'
);

INSERT INTO public.device_tokens (id, user_id, token, provider, platform, status, last_seen_at, created_at, updated_at)
VALUES
  ('30000000-0000-4000-9000-000000000001', '20000000-0000-4000-9000-000000000001', 'eligible-token', 'fcm', 'ios', 'active', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000002', '20000000-0000-4000-9000-000000000002', 'no-content-token', 'fcm', 'ios', 'active', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000003', '20000000-0000-4000-9000-000000000003', 'expired-token', 'fcm', 'ios', 'expired', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000004', '20000000-0000-4000-9000-000000000006', 'failure-token', 'fcm', 'android', 'active', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000005', '20000000-0000-4000-9000-000000000005', 'success-token', 'fcm', 'android', 'active', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000006', '20000000-0000-4000-9000-000000000007', 'minute-mismatch-token', 'fcm', 'ios', 'active', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000007', '20000000-0000-4000-9000-000000000004', 'reserve-token-1', 'fcm', 'android', 'active', now(), now(), now()),
  ('30000000-0000-4000-9000-000000000008', '20000000-0000-4000-9000-000000000004', 'reserve-token-2', 'fcm', 'android', 'active', now(), now(), now());

INSERT INTO tmp_tokens (label, token_id, user_id) VALUES
  ('eligible', '30000000-0000-4000-9000-000000000001', '20000000-0000-4000-9000-000000000001'),
  ('no_content', '30000000-0000-4000-9000-000000000002', '20000000-0000-4000-9000-000000000002'),
  ('expired', '30000000-0000-4000-9000-000000000003', '20000000-0000-4000-9000-000000000003'),
  ('failure', '30000000-0000-4000-9000-000000000004', '20000000-0000-4000-9000-000000000006'),
  ('success', '30000000-0000-4000-9000-000000000005', '20000000-0000-4000-9000-000000000005'),
  ('minute_mismatch', '30000000-0000-4000-9000-000000000006', '20000000-0000-4000-9000-000000000007'),
  ('reserve_one', '30000000-0000-4000-9000-000000000007', '20000000-0000-4000-9000-000000000004'),
  ('reserve_two', '30000000-0000-4000-9000-000000000008', '20000000-0000-4000-9000-000000000004');

-- Candidate selection filters for wants_daily + allowed + current hour + content present + active token
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
CREATE TEMP TABLE tmp_candidates AS
SELECT * FROM public.notifications_daily_candidates(10, 0);
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  (SELECT COUNT(*)::int FROM tmp_candidates),
  1,
  'Only eligible users with active tokens are returned'
);

SELECT is(
  (SELECT user_id::text FROM tmp_candidates LIMIT 1),
  '20000000-0000-4000-9000-000000000001',
  'Eligible user returned'
);

SELECT is(
  (SELECT token_id::text FROM tmp_candidates LIMIT 1),
  '30000000-0000-4000-9000-000000000001',
  'Returns active token id'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM tmp_candidates WHERE user_id = '20000000-0000-4000-9000-000000000007'
  ),
  'Candidate list excludes users whose preferred_minute does not match current minute'
);

SELECT is(
  (SELECT local_date::text FROM tmp_candidates LIMIT 1),
  (timezone('UTC', now())::date)::text,
  'local_date matches timezone(current_date)'
);

DROP TABLE IF EXISTS tmp_candidates;

-- Reserve send is idempotent per token+date and stores job_run_id
SELECT set_config(
  'app.test.reserve_token_one',
  (SELECT token_id::text FROM tmp_tokens WHERE label = 'reserve_one'),
  true
);
SELECT set_config(
  'app.test.reserve_token_two',
  (SELECT token_id::text FROM tmp_tokens WHERE label = 'reserve_two'),
  true
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
CREATE TEMP TABLE tmp_reserved AS
SELECT public.notifications_reserve_send(
  '20000000-0000-4000-9000-000000000004',
  current_setting('app.test.reserve_token_one', false)::uuid,
  timezone('UTC', now())::date,
  'job-run-1'
) AS send_id;
CREATE TEMP TABLE tmp_second_attempt AS
SELECT public.notifications_reserve_send(
  '20000000-0000-4000-9000-000000000004',
  current_setting('app.test.reserve_token_one', false)::uuid,
  timezone('UTC', now())::date,
  'job-run-1'
) AS send_id;
CREATE TEMP TABLE tmp_other_token AS
SELECT public.notifications_reserve_send(
  '20000000-0000-4000-9000-000000000004',
  current_setting('app.test.reserve_token_two', false)::uuid,
  timezone('UTC', now())::date,
  'job-run-1'
) AS send_id;
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT ok(
  (SELECT send_id IS NOT NULL FROM tmp_reserved),
  'First reservation returns a send id'
);

SELECT is(
  (SELECT send_id FROM tmp_second_attempt),
  NULL,
  'Second reservation for same token/date returns null'
);

SELECT is(
  (
    SELECT COUNT(*)::int
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000004'
      AND local_date = timezone('UTC', now())::date
  ),
  2,
  'Two send rows persisted for distinct tokens on same day'
);

SELECT is(
  (
    SELECT job_run_id
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000004'
      AND token_id = (SELECT token_id FROM tmp_tokens WHERE label = 'reserve_one')
      AND local_date = timezone('UTC', now())::date
  ),
  'job-run-1',
  'job_run_id stored on reservation'
);

DROP TABLE IF EXISTS tmp_reserved;
DROP TABLE IF EXISTS tmp_second_attempt;
DROP TABLE IF EXISTS tmp_other_token;

-- Mark send success updates status + prefs.last_sent_local_date
SELECT set_config(
  'app.test.success_token_id',
  (SELECT token_id::text FROM tmp_tokens WHERE label = 'success'),
  true
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
CREATE TEMP TABLE tmp_success AS
SELECT public.notifications_reserve_send(
  '20000000-0000-4000-9000-000000000005',
  current_setting('app.test.success_token_id', false)::uuid,
  timezone('UTC', now())::date,
  'job-success'
) AS send_id;
SELECT public.notifications_mark_send_success(
  (SELECT send_id FROM tmp_success),
  '20000000-0000-4000-9000-000000000005',
  timezone('UTC', now())::date
);
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  (
    SELECT status
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000005'
  ),
  'sent',
  'mark_send_success sets status=sent'
);

SELECT ok(
  (
    SELECT sent_at IS NOT NULL
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000005'
  ),
  'mark_send_success stamps sent_at'
);

SELECT is(
  (
    SELECT last_sent_local_date
    FROM public.notification_preferences
    WHERE user_id = '20000000-0000-4000-9000-000000000005'
  ),
  timezone('UTC', now())::date,
  'Preferences last_sent_local_date updated on success'
);

DROP TABLE IF EXISTS tmp_success;

-- Failed send captures error + failed_at; token status can be updated to expired
SELECT set_config(
  'app.test.failure_token_id',
  (SELECT token_id::text FROM tmp_tokens WHERE label = 'failure'),
  true
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
CREATE TEMP TABLE tmp_failed AS
SELECT public.notifications_reserve_send(
  '20000000-0000-4000-9000-000000000006',
  current_setting('app.test.failure_token_id', false)::uuid,
  timezone('UTC', now())::date,
  'job-fail'
) AS send_id;
SELECT public.notifications_update_send_status(
  (SELECT send_id FROM tmp_failed),
  'failed',
  'token_expired'
);
SELECT public.notifications_mark_token_status(
  current_setting('app.test.failure_token_id', false)::uuid,
  'expired'
);
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  (
    SELECT status
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000006'
  ),
  'failed',
  'Failed send stores status'
);

SELECT is(
  (
    SELECT error
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000006'
  ),
  'token_expired',
  'Failed send stores error text'
);

SELECT ok(
  (
    SELECT failed_at IS NOT NULL
    FROM public.notification_sends
    WHERE user_id = '20000000-0000-4000-9000-000000000006'
  ),
  'Failed send stamps failed_at'
);

SELECT is(
  (
    SELECT status
    FROM public.device_tokens
    WHERE id = (SELECT token_id FROM tmp_tokens WHERE label = 'failure')
  ),
  'expired',
  'mark_token_status updates token status'
);

DROP TABLE IF EXISTS tmp_failed;

RESET ROLE;


SELECT finish();
ROLLBACK;
