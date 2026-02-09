SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label text PRIMARY KEY,
  user_id uuid,
  email text
);

CREATE TEMP TABLE tmp_home (
  home_id uuid PRIMARY KEY
);

CREATE TEMP TABLE tmp_claim_1 (
  entry_id uuid,
  home_id uuid,
  author_user_id uuid,
  recipient_user_id uuid,
  request_id uuid
);

CREATE TEMP TABLE tmp_claim_2 (
  entry_id uuid,
  home_id uuid,
  author_user_id uuid,
  recipient_user_id uuid,
  request_id uuid
);

CREATE TEMP TABLE tmp_metric (
  baseline integer NOT NULL
);

-- Required by auth.users -> public.handle_new_user trigger
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES (
  '00000000-0000-4000-8000-000000009901'::uuid,
  'avatars/test-default.png',
  'animal',
  'Test Default Avatar'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000009902'::uuid, 'avatars/test-alt-1.png', 'animal', 'Test Alt Avatar 1'),
  ('00000000-0000-4000-8000-000000009903'::uuid, 'avatars/test-alt-2.png', 'animal', 'Test Alt Avatar 2')
ON CONFLICT (id) DO NOTHING;

-- -------------------------------------------------------------------
-- 1) Scheduler refactor checks (migration 20260322090010)
-- -------------------------------------------------------------------
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'complaint_trigger_runner_every_5m'
  ),
  'runner DB->HTTP cron job is unscheduled'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'complaint_rewrite_batch_submitter_15m'
  ),
  'batch submitter DB->HTTP cron job is unscheduled'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'complaint_rewrite_batch_collector_30m'
  ),
  'batch collector DB->HTTP cron job is unscheduled'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'complaint_trigger_watchdog_every_10m'
  ),
  'watchdog DB-only cron job remains scheduled'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'complaint_trigger_fail_exhausted_every_25m'
  ),
  'fail-exhausted DB-only cron job remains scheduled'
);

SELECT ok(
  to_regprocedure('public._cron_call_complaint_trigger_runner()') IS NULL,
  '_cron_call_complaint_trigger_runner() is dropped'
);

-- -------------------------------------------------------------------
-- 2) Build minimal home context for trigger + shopping tests
-- -------------------------------------------------------------------
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '10000000-0000-4000-9000-000000009901', 'owner-cron-test@example.com'),
  ('member', '10000000-0000-4000-9000-000000009902', 'member-cron-test@example.com');

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

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH created AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_home (home_id)
SELECT (payload->'home'->>'id')::uuid
FROM created;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_join(
  (
    SELECT code
    FROM public.invites
    WHERE home_id = (SELECT home_id FROM tmp_home)
      AND revoked_at IS NULL
    ORDER BY created_at DESC
    LIMIT 1
  )
);

-- -------------------------------------------------------------------
-- 3) Trigger queue state-machine checks (migration 20260322090007)
-- -------------------------------------------------------------------
INSERT INTO public.home_mood_entries (
  id,
  home_id,
  user_id,
  mood,
  comment,
  created_at,
  iso_week_year,
  iso_week
)
VALUES (
  '70000000-0000-4000-9000-000000009901'::uuid,
  (SELECT home_id FROM tmp_home),
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  'cloudy',
  'queue pipeline test',
  now(),
  extract(isoyear from now() at time zone 'UTC')::int,
  extract(week from now() at time zone 'UTC')::int
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.complaint_rewrite_triggers (
  entry_id, home_id, author_user_id, recipient_user_id, status
)
VALUES (
  '70000000-0000-4000-9000-000000009901'::uuid,
  (SELECT home_id FROM tmp_home),
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  (SELECT user_id FROM tmp_users WHERE label = 'member'),
  'queued'
)
ON CONFLICT (entry_id) DO UPDATE
SET status = 'queued',
    request_id = NULL,
    retry_after = NULL,
    processing_started_at = NULL,
    processed_at = NULL,
    error = NULL,
    note = NULL;

INSERT INTO tmp_claim_1
SELECT *
FROM public.complaint_trigger_pop_pending(1, 10)
WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid;

SELECT is((SELECT count(*) FROM tmp_claim_1), 1::bigint, 'pop_pending claims queued row');

SELECT is(
  (SELECT status FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'processing'::text,
  'claimed row moved to processing'
);

SELECT is(
  (SELECT attempts FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  1,
  'attempts incremented on first claim'
);

SELECT ok(
  (SELECT request_id IS NOT NULL FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'request_id set while processing'
);

SELECT lives_ok(
  $$
  SELECT public.complaint_trigger_mark_retry(
    (SELECT entry_id FROM tmp_claim_1 LIMIT 1),
    (SELECT request_id FROM tmp_claim_1 LIMIT 1),
    'forced retry test',
    '10 seconds'::interval,
    'test_retry'
  );
  $$,
  'mark_retry succeeds for claimed row'
);

SELECT is(
  (SELECT status FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'queued'::text,
  'mark_retry requeues row'
);

SELECT ok(
  (SELECT request_id IS NULL FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'request_id cleared after retry'
);

SELECT ok(
  (SELECT retry_after > now() FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'retry_after set in the future'
);

UPDATE public.complaint_rewrite_triggers
SET retry_after = now() - interval '1 second'
WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid;

INSERT INTO tmp_claim_2
SELECT *
FROM public.complaint_trigger_pop_pending(1, 10)
WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid;

SELECT is((SELECT count(*) FROM tmp_claim_2), 1::bigint, 'row is claimable again after retry_after elapses');

SELECT is(
  (SELECT attempts FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  2,
  'attempts incremented on second claim'
);

SELECT lives_ok(
  $$
  SELECT public.complaint_trigger_mark_completed(
    (SELECT entry_id FROM tmp_claim_2 LIMIT 1),
    (SELECT request_id FROM tmp_claim_2 LIMIT 1),
    now(),
    'test_completed'
  );
  $$,
  'mark_completed succeeds for current claim owner'
);

SELECT is(
  (SELECT status FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'completed'::text,
  'row reaches completed'
);

SELECT ok(
  (SELECT processed_at IS NOT NULL FROM public.complaint_rewrite_triggers WHERE entry_id = '70000000-0000-4000-9000-000000009901'::uuid),
  'processed_at set on completion'
);

SELECT throws_like(
  $$
  SELECT public.complaint_trigger_mark_completed(
    '70000000-0000-4000-9000-000000009901'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
    now(),
    'should fail'
  );
  $$,
  '%mark_completed_noop%',
  'marker RPC rejects stale/wrong request ownership'
);

-- -------------------------------------------------------------------
-- 4) Shopping photo quota checks (migration 20260322090009)
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

INSERT INTO tmp_metric (baseline)
SELECT COALESCE(
  (
    SELECT shopping_item_photos
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_home)
  ),
  0
);

UPDATE public.home_plan_limits
SET max_value = (SELECT baseline + 1 FROM tmp_metric)
WHERE plan = 'free'
  AND metric = 'shopping_item_photos';

SELECT lives_ok(
  $$
  SELECT public.shopping_list_add_item(
    (SELECT home_id FROM tmp_home),
    'Photo item 1',
    '1',
    'first photo item',
    'households/test/photo-item-1.jpg'
  );
  $$,
  'first photo item within temporary free cap succeeds'
);

SELECT is(
  (
    SELECT shopping_item_photos
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_home)
  ),
  (SELECT baseline + 1 FROM tmp_metric),
  'shopping_item_photos usage increments after first photo item'
);

SELECT throws_like(
  $$
  SELECT public.shopping_list_add_item(
    (SELECT home_id FROM tmp_home),
    'Photo item 2',
    '1',
    'second photo item should exceed cap',
    'households/test/photo-item-2.jpg'
  );
  $$,
  '%PAYWALL_LIMIT_SHOPPING_ITEM_PHOTOS%',
  'second photo item exceeds cap and returns paywall error'
);

SELECT * FROM finish();
ROLLBACK;
