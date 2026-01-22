SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(11);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE tmp_entries (
  label     text PRIMARY KEY,
  entry_id  uuid
);

CREATE OR REPLACE FUNCTION pg_temp.expect_api_error(
  p_sql         text,
  p_error_code  text,
  p_description text
)
RETURNS text
LANGUAGE sql
AS $$
  SELECT throws_like(
    p_sql,
    '%' || p_error_code || '%',
    p_description
  );
$$;

-- Starter avatar required for profile creation
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000777', 'avatars/default.png', 'animal', 'Mood Avatar')
ON CONFLICT (id) DO NOTHING;

-- Seed logical users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator', '30000000-0000-4000-8000-000000000010', 'creator-nps@example.com'),
  ('outsider', '30000000-0000-4000-8000-000000000011', 'outsider-nps@example.com');

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

-- Clean up any prior data for these test users to avoid cross-run collisions
DELETE FROM public.gratitude_wall_reads
WHERE user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.home_mood_feedback_counters
WHERE user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.home_nps
WHERE user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.gratitude_wall_posts
WHERE author_user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.home_mood_entries
WHERE user_id IN (SELECT user_id FROM tmp_users);

-- Creator creates home + invite
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

-- Baseline: no counters row yet → nps status false
WITH payload AS (
  SELECT public.home_nps_get_status((SELECT home_id FROM tmp_homes WHERE label = 'primary')) AS required
)
SELECT is(
  (SELECT required FROM payload),
  false,
  'NPS status defaults to false when no counters row exists'
);

-- First feedback creates counters with feedback_count=1, nps_required=false
WITH payload AS (
  SELECT * FROM public.mood_submit(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'sunny',
    'Initial mood',
    false
  )
)
INSERT INTO tmp_entries (label, entry_id)
SELECT 'first', entry_id FROM payload;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.home_mood_feedback_counters c
    WHERE c.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND c.user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')
      AND c.feedback_count = 1
      AND c.nps_required = false
  ),
  'First mood submission creates counters row with feedback_count=1 and nps_required=false'
);

-- Move first entry to a past ISO week to free the current slot
UPDATE public.home_mood_entries
SET iso_week = 1, iso_week_year = 2001
WHERE id = (SELECT entry_id FROM tmp_entries WHERE label = 'first');

-- Add 12 more moods to reach milestone 13 (same user/home)
DO $$
DECLARE
  i int;
  v_entry_id uuid;
BEGIN
  FOR i IN 2..13 LOOP
    WITH payload AS (
      SELECT * FROM public.mood_submit(
        (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
        'sunny',
        format('NPS run %s', i),
        false
      )
    )
    SELECT entry_id INTO v_entry_id FROM payload;

    -- Shift ISO week so the unique constraint does not block the next insert
    UPDATE public.home_mood_entries
    SET iso_week = i, iso_week_year = 2000 + i
    WHERE id = v_entry_id;
  END LOOP;
END;
$$;

SELECT is(
  (SELECT feedback_count FROM public.home_mood_feedback_counters
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
     AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')),
  13,
  'Feedback counter reaches 13 after 13 submissions'
);

SELECT is(
  (SELECT nps_required FROM public.home_mood_feedback_counters
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
     AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')),
  true,
  'NPS requirement flips to true at milestone 13'
);

WITH payload AS (
  SELECT public.home_nps_get_status((SELECT home_id FROM tmp_homes WHERE label = 'primary')) AS required
)
SELECT is(
  (SELECT required FROM payload),
  true,
  'home_nps_get_status returns true when nps_required is set'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT * FROM public.home_nps_submit(
      '%s',
      5
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'NOT_HOME_MEMBER',
  'Non-member cannot submit NPS'
);

-- Creator: invalid score rejected
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT * FROM public.home_nps_submit(
      '%s',
      11
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'INVALID_NPS_SCORE',
  'Score above 10 is rejected'
);

-- Creator submits valid NPS; clears requirement and records milestone
WITH submitted AS (
  SELECT * FROM public.home_nps_submit(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    8
  )
)
SELECT is(
  (SELECT COUNT(*)::int FROM submitted),
  1,
  'home_nps_submit returns inserted row'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.home_mood_feedback_counters c
    WHERE c.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND c.user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')
      AND c.last_nps_score = 8
      AND c.last_nps_feedback_count = 13
      AND c.nps_required = false
  ),
  'Counters updated with last_nps_score=8, last_nps_feedback_count=13, nps_required cleared'
);

-- One more mood after NPS does not immediately re-trigger requirement
WITH extra AS (
  SELECT * FROM public.mood_submit(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'sunny',
    'Post-NPS entry',
    false
  )
)
UPDATE public.home_mood_entries
SET iso_week = 14, iso_week_year = 2014
WHERE id = (SELECT entry_id FROM extra);

SELECT is(
  (SELECT feedback_count FROM public.home_mood_feedback_counters
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
     AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')),
  14,
  'Feedback counter increments to 14 after additional submission'
);

SELECT is(
  (SELECT public.home_nps_get_status((SELECT home_id FROM tmp_homes WHERE label = 'primary'))),
  false,
  'NPS status returns false after requirement cleared and one more submission'
);

SELECT * FROM finish();

ROLLBACK;
