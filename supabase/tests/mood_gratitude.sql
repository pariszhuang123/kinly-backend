SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(13);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);


-- =====================================================================
--  Test helper: expect_api_error
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.expect_api_error(
  p_sql         text,
  p_error_code  text,
  p_description text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_state text;
  v_msg   text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RETURN ok(false, format('Expected %s but query succeeded', p_error_code));
  EXCEPTION
    WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;

      IF position(p_error_code IN coalesce(v_msg, '')) > 0 OR v_state = p_error_code THEN
        RETURN ok(true, p_description);
      END IF;

      RETURN ok(false, format('%s (got %s / %s)', p_description, v_state, v_msg));
  END;
END;
$$;

-- =====================================================================
--  Seed avatars & users
-- =====================================================================

-- Starter avatars for profile creation (enough unique options for the home join path)
INSERT INTO public.avatars (id, storage_path, category, name) VALUES
  ('00000000-0000-4000-8000-000000000777', 'avatars/default.png',  'animal', 'Mood Avatar 1'),
  ('00000000-0000-4000-8000-000000000778', 'avatars/default2.png', 'animal', 'Mood Avatar 2'),
  ('00000000-0000-4000-8000-000000000779', 'avatars/default3.png', 'animal', 'Mood Avatar 3'),
  ('00000000-0000-4000-8000-000000000780', 'avatars/default4.png', 'animal', 'Mood Avatar 4'),
  ('00000000-0000-4000-8000-000000000781', 'avatars/default5.png', 'animal', 'Mood Avatar 5')
ON CONFLICT (id) DO NOTHING;

-- Seed logical users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator',    '30000000-0000-4000-8000-000000000001', 'creator-mood@example.com'),
  ('member_one', '30000000-0000-4000-8000-000000000002', 'member1-mood@example.com'),
  ('member_two', '30000000-0000-4000-8000-000000000003', 'member2-mood@example.com'),
  ('outsider',   '30000000-0000-4000-8000-000000000004', 'outsider-mood@example.com');

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

-- =====================================================================
--  Create home and join members
-- =====================================================================

-- Creator context
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

-- Grab invite code
WITH code AS (
  SELECT code::text
  FROM public.invites
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    AND revoked_at IS NULL
  LIMIT 1
)
SELECT set_config('app.test.invite_code', (SELECT code FROM code), true);

-- member_one joins
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join(current_setting('app.test.invite_code', false)::text);

-- member_two joins
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_two'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join(current_setting('app.test.invite_code', false)::text);

-- =====================================================================
--  Tests
-- =====================================================================

-- Context: creator
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- 1–2. Creator submits sunny mood with wall post
WITH payload AS (
  SELECT * FROM public.mood_submit(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'sunny',
    'Great vibe!',
    true
  )
)
SELECT ok(
  COALESCE(
    (SELECT gratitude_post_id IS NOT NULL
       FROM public.home_mood_entries
      WHERE id = (SELECT entry_id FROM payload)),
    FALSE
  ),
  'Sunny mood submission links a gratitude wall post'
);

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.gratitude_wall_posts
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  1,
  'Exactly one gratitude post created from first submission'
);

-- 3. Duplicate week is rejected for same user
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT * FROM public.mood_submit(
      '%s',
      'sunny',
      'Duplicate attempt',
      true
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'MOOD_ALREADY_SUBMITTED',
  'Reject duplicate mood for same ISO week'
);

-- 4–5. member_one submits negative mood (no wall post) + weekly check
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT * FROM public.mood_submit(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'rainy',
    'Tough week',
    true -- ignored for negative mood
  )
)
SELECT ok(
  COALESCE(
    (SELECT gratitude_post_id IS NULL
       FROM public.home_mood_entries
      WHERE id = (SELECT entry_id FROM payload)),
    FALSE
  ),
  'Negative mood does not create a gratitude wall post even if add_to_wall is requested'
);

WITH payload AS (
  SELECT public.mood_get_current_weekly(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS submitted
)
SELECT is(
  (SELECT submitted FROM payload),
  true,
  'mood_get_current_weekly returns true when a mood exists for this ISO week'
);

-- 6. Outsider blocked from submitting
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT * FROM public.mood_submit(
      '%s',
      'cloudy',
      NULL,
      false
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'NOT_HOME_MEMBER',
  'Non-members cannot submit moods'
);

-- 7–9. member_two posts another positive entry to drive pagination
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_two'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Ensure created_at ordering is deterministic for pagination checks
SELECT pg_sleep(0.02);

WITH payload AS (
  SELECT * FROM public.mood_submit(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'partially_sunny',
    'Second post for ordering',
    true
  )
)
SELECT ok(
  COALESCE(
    (SELECT gratitude_post_id IS NOT NULL
       FROM public.home_mood_entries
      WHERE id = (SELECT entry_id FROM payload)),
    FALSE
  ),
  'Positive mood creates gratitude wall post'
);

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.gratitude_wall_posts
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  2,
  'Two gratitude wall posts exist after two positive moods'
);

-- Pagination: newest first
WITH page1 AS (
  SELECT * FROM public.gratitude_wall_list(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    1
  )
)
SELECT is(
  (SELECT COUNT(*)::int FROM page1),
  1,
  'First page returns one row respecting limit'
);

WITH page1 AS (
  SELECT * FROM public.gratitude_wall_list(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    1
  )
)
SELECT is(
  (SELECT author_user_id FROM page1),
  (SELECT user_id FROM tmp_users WHERE label = 'member_two'),
  'First page returns newest post (member_two)'
);

WITH page1 AS (
  SELECT * FROM public.gratitude_wall_list(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    1
  )
),
page2 AS (
  SELECT * FROM public.gratitude_wall_list(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    10,
    (SELECT created_at FROM page1),
    (SELECT post_id FROM page1)
  )
)
SELECT is(
  (SELECT author_user_id FROM page2 LIMIT 1),
  (SELECT user_id FROM tmp_users WHERE label = 'creator'),
  'Second page returns older creator post'
);

-- 10–13. Read tracking upsert + timestamp bump
SELECT public.gratitude_wall_mark_read(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary')
);

SELECT ok(
  (SELECT COUNT(*)::int
     FROM public.gratitude_wall_reads
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_two')) = 1,
  'mark_read upserts read row for caller'
);

SELECT pg_sleep(0.05);

WITH before AS (
  SELECT last_read_at
  FROM public.gratitude_wall_reads
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_two')
),
call AS (
  SELECT public.gratitude_wall_mark_read(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS noop
),
after_ts AS (
  SELECT last_read_at
  FROM public.gratitude_wall_reads
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_two')
)
SELECT ok(
  (SELECT (after_ts.last_read_at > before.last_read_at) FROM before, after_ts),
  'mark_read updates last_read_at on subsequent call'
);

SELECT * FROM finish();

ROLLBACK;
