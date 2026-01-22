SET search_path = pgtap, public, auth, extensions;

BEGIN;

-- We now have 19 assertions (see bottom)
SELECT plan(19);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000311', 'owner-chores@example.com'),
  ('helper', '00000000-0000-4000-8000-000000000312', 'helper-chores@example.com');

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE tmp_chores (
  label    text PRIMARY KEY,
  chore_id uuid
);

CREATE TEMP TABLE invite_codes (
  label text PRIMARY KEY,
  code  text
);

-- Minimal avatar so profiles can reference one
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000701', 'avatars/default.png', 'animal', 'Chores Avatar')
ON CONFLICT (id) DO NOTHING;

-- Additional avatar to keep joins unique per home
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000702', 'avatars/chores-alt.png', 'animal', 'Chores Avatar Alt')
ON CONFLICT (id) DO NOTHING;

-- Seed auth.users for owner + helper
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

-- Owner creates a home via homes_create_with_invite
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

INSERT INTO invite_codes (label, code)
SELECT 'primary', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
LIMIT 1;

-- Helper joins home via homes_join
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'helper'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_join(
  (SELECT code FROM invite_codes WHERE label = 'primary')
);

-- -------------------------------------------------------------------
-- Create initial one-off chore (no assignee yet ⇒ state = draft)
-- chores_create(
--   p_home_id,
--   p_name,
--   p_assignee_user_id DEFAULT NULL,
--   p_start_date DEFAULT current_date,
--   p_recurrence DEFAULT 'none',
--   p_how_to_video_url DEFAULT NULL,
--   p_notes DEFAULT NULL,
--   p_expectation_photo_path DEFAULT NULL
-- )
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.chores_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Laundry day',
    NULL,              -- no assignee yet ⇒ draft
    current_date,
    'none',
    NULL,              -- how_to_video_url
    'Do the laundry',  -- notes
    NULL               -- expectation_photo_path
  ) AS payload
)
INSERT INTO tmp_chores (label, chore_id)
SELECT 'one_off', (payload).id FROM res;

SELECT throws_like(
  $$
    SELECT public.chores_create(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Bad link chore',
      NULL,
      current_date,
      'none',
      'ftp://invalid-link',
      NULL,
      NULL
    )
  $$,
  '%chores_how_to_video_url_scheme%',
  'rejects non-http(s) how_to_video_url on create'
);

-- After creation, active_chores should be 1 (draft counts as a slot)
SELECT is(
  (SELECT active_chores
     FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  1,
  'creating a chore increments active count'
);

-- -------------------------------------------------------------------
-- Assign chore to helper via chores_update
-- chores_update(
--   p_chore_id,
--   p_name,
--   p_assignee_user_id,
--   p_start_date,
--   p_recurrence DEFAULT NULL,
--   p_expectation_photo_path DEFAULT NULL,
--   p_how_to_video_url DEFAULT NULL,
--   p_notes DEFAULT NULL
-- )
-- This will:
--   * enforce name + assignee
--   * set state = active
--   * NOT change usage counters
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  $$
    SELECT public.chores_update(
      (SELECT chore_id FROM tmp_chores WHERE label = 'one_off'),
      'Laundry day',
      (SELECT user_id FROM tmp_users WHERE label = 'helper'),
      current_date,
      NULL,
      NULL,
      'ftp://invalid-link',
      NULL
    )
  $$,
  '%chores_how_to_video_url_scheme%',
  'rejects non-http(s) how_to_video_url on update'
);

SELECT public.chores_update(
  (SELECT chore_id FROM tmp_chores WHERE label = 'one_off'),
  'Laundry day',                                             -- keep name
  (SELECT user_id FROM tmp_users WHERE label = 'helper'),    -- new assignee
  current_date,                                              -- keep date
  NULL,                                                      -- keep recurrence as-is
  NULL,                                                      -- leave photo as-is (NULL)
  NULL,                                                      -- leave how_to_video_url
  'Do the laundry'                                           -- keep notes
);

-- Assignee should now be helper
SELECT is(
  (SELECT assignee_user_id::text
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'one_off')),
  (SELECT user_id::text FROM tmp_users WHERE label = 'helper'),
  'chores_update sets assignee'
);

-- State should now be 'active' (not 'assigned')
SELECT is(
  (SELECT state::text
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'one_off')),
  'active',
  'chores_update moves chore to active state'
);

-- We should have an "activate" event for this first assignment
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.chore_events
    WHERE chore_id = (SELECT chore_id FROM tmp_chores WHERE label = 'one_off')
      AND event_type = 'activate'
  ),
  'activate event recorded on first assignment'
);

-- -------------------------------------------------------------------
-- Helper completes the one-off chore via chore_complete
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'helper'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.chore_complete(
  (SELECT chore_id FROM tmp_chores WHERE label = 'one_off')
);

SELECT is(
  (SELECT state::text
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'one_off')),
  'completed',
  'chore_complete finalizes one-off chores'
);

SELECT is(
  (SELECT active_chores
   FROM public.home_usage_counters
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  0,
  'completing a one-off chore decrements active count'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.chore_events
    WHERE chore_id = (SELECT chore_id FROM tmp_chores WHERE label = 'one_off')
      AND event_type = 'complete'
  ),
  'complete event recorded'
);

-- -------------------------------------------------------------------
-- Create recurring chore with expectation photo
-- This should increment both active_chores (by 1) and chore_photos (by 1).
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.chores_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Fridge clean',
    NULL,  -- no assignee yet ⇒ draft
    current_date,
    'weekly',
    NULL,  -- how_to_video_url
    NULL,  -- notes
    'flow/expectations/'
      || (SELECT home_id::text FROM tmp_homes WHERE label = 'primary')
      || '/chores/fridge'
  ) AS payload
)
INSERT INTO tmp_chores (label, chore_id)
SELECT 'photo_chore', (payload).id FROM res;

SELECT is(
  (SELECT chore_photos
   FROM public.home_usage_counters
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  1,
  'adding expectation photo increments photo counter'
);

-- v1 create should backfill recurrence_every/unit for weekly cadence.
SELECT is(
  (SELECT recurrence_every
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'photo_chore')),
  1,
  'v1 create backfills recurrence_every for weekly cadence'
);

SELECT is(
  (SELECT recurrence_unit
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'photo_chore')),
  'week',
  'v1 create backfills recurrence_unit for weekly cadence'
);

SELECT throws_like(
  $$
    SELECT public.chores_create_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Bad recurrence unit',
      NULL,
      current_date,
      1,
      'fortnight',
      NULL,
      NULL,
      NULL
    )
  $$,
  '%recurrenceUnit must be one of day|week|month|year%',
  'chores_create_v2 rejects invalid recurrenceUnit'
);

WITH res AS (
  SELECT public.chores_create_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Trash day',
    NULL,
    current_date,
    2,
    'week',
    NULL,
    NULL,
    NULL
  ) AS payload
)
INSERT INTO tmp_chores (label, chore_id)
SELECT 'v2_recurring', (payload).id FROM res;

SELECT is(
  (SELECT recurrence_every
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'v2_recurring')),
  2,
  'chores_create_v2 stores recurrence_every'
);

SELECT is(
  (SELECT recurrence_unit
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'v2_recurring')),
  'week',
  'chores_create_v2 stores recurrence_unit'
);

SELECT throws_like(
  $$
    SELECT public.chores_update_v2(
      (SELECT chore_id FROM tmp_chores WHERE label = 'v2_recurring'),
      'Trash day',
      NULL,
      current_date,
      2,
      'week',
      NULL,
      NULL,
      NULL
    )
  $$,
  '%Assignee is required%',
  'chores_update_v2 requires an assignee'
);

SELECT public.chores_cancel(
  (SELECT chore_id FROM tmp_chores WHERE label = 'v2_recurring')
);

-- NOTE:
-- We are NOT currently testing "removal of expectation photo decrements photo
-- counter" because chores_update does not yet implement an empty-string/NULL
-- removal semantics. When you add that behavior, you can add a pgTAP
-- block here to exercise it.

-- -------------------------------------------------------------------
-- Cancel recurring chore
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.chores_cancel(
  (SELECT chore_id FROM tmp_chores WHERE label = 'photo_chore')
);

SELECT is(
  (SELECT state::text
   FROM public.chores
   WHERE id = (SELECT chore_id FROM tmp_chores WHERE label = 'photo_chore')),
  'cancelled',
  'chores_cancel marks chore as cancelled'
);

-- After:
--   - one-off completed (−1 active)
--   - recurring created (+1 active)
--   - recurring cancelled (−1 active)
-- ⇒ active count should be 0
SELECT is(
  (SELECT active_chores
   FROM public.home_usage_counters
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  0,
  'cancelling chore leaves active count at zero'
);

-- chores_list_for_home now returns only draft/active; completed and cancelled
-- chores should be excluded.
SELECT is(
  (
    SELECT count(*)::integer
    FROM public.chores_list_for_home(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  0,
  'chores_list_for_home omits completed one-offs and cancelled chores'
);

SELECT * FROM finish();
ROLLBACK;
