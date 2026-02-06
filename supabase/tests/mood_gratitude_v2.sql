SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(17);

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
) RETURNS text
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
INSERT INTO public.avatars (id, storage_path, category, name) VALUES
  ('00000000-0000-4000-8000-000000000777', 'avatars/default.png',  'animal', 'Mood Avatar 1'),
  ('00000000-0000-4000-8000-000000000778', 'avatars/default2.png', 'animal', 'Mood Avatar 2'),
  ('00000000-0000-4000-8000-000000000779', 'avatars/default3.png', 'animal', 'Mood Avatar 3'),
  ('00000000-0000-4000-8000-000000000780', 'avatars/default4.png', 'animal', 'Mood Avatar 4'),
  ('00000000-0000-4000-8000-000000000781', 'avatars/default5.png', 'animal', 'Mood Avatar 5')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator',    '30000000-0000-4000-8000-000000000101', 'creator-moodv2@example.com'),
  ('member_one', '30000000-0000-4000-8000-000000000102', 'member1-moodv2@example.com'),
  ('member_two', '30000000-0000-4000-8000-000000000103', 'member2-moodv2@example.com'),
  ('member_three','30000000-0000-4000-8000-000000000105','member3-moodv2@example.com'),
  ('outsider',   '30000000-0000-4000-8000-000000000104', 'outsider-moodv2@example.com');

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

INSERT INTO public.profiles (id, username, avatar_id)
SELECT
  user_id,
  concat('user_', replace(label, ' ', '_')),
  '00000000-0000-4000-8000-000000000777'
FROM tmp_users
ON CONFLICT (id) DO UPDATE
  SET avatar_id = EXCLUDED.avatar_id,
      username  = EXCLUDED.username;

-- Clean prior data for these users
DELETE FROM public.gratitude_wall_personal_reads
WHERE user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.gratitude_wall_personal_items
WHERE recipient_user_id IN (SELECT user_id FROM tmp_users)
   OR author_user_id IN (SELECT user_id FROM tmp_users);

DO $$
BEGIN
  -- Ensure complaint_rewrite_triggers exists for negative mention path
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'complaint_rewrite_triggers'
  ) THEN
    CREATE TABLE public.complaint_rewrite_triggers (
      entry_id uuid PRIMARY KEY,
      home_id uuid NOT NULL,
      author_user_id uuid NOT NULL,
      recipient_user_id uuid NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    );
  END IF;

  DELETE FROM public.complaint_rewrite_triggers
  WHERE author_user_id IN (SELECT user_id FROM tmp_users)
     OR recipient_user_id IN (SELECT user_id FROM tmp_users);
END $$;

DELETE FROM public.gratitude_wall_mentions
WHERE mentioned_user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.gratitude_wall_posts
WHERE author_user_id IN (SELECT user_id FROM tmp_users);

DELETE FROM public.home_mood_entries
WHERE user_id IN (SELECT user_id FROM tmp_users);

-- =====================================================================
--  Create home and join members
-- =====================================================================
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

WITH code AS (
  SELECT code::text
  FROM public.invites
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    AND revoked_at IS NULL
  LIMIT 1
)
SELECT set_config('app.test.invite_code_v2', (SELECT code FROM code), true);

-- member_one joins
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join(current_setting('app.test.invite_code_v2', false)::text);

-- member_two joins
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_two'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join(current_setting('app.test.invite_code_v2', false)::text);

-- member_three joins (used for negative mention path)
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_three'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join(current_setting('app.test.invite_code_v2', false)::text);

-- =====================================================================
--  Tests
-- =====================================================================

-- Switch to member_one (entry only, no publish)
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.mood_submit_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'sunny',
    'Sunny but private',
    false,
    NULL
  ) AS payload
)
SELECT ok(
  (payload->>'entry_id') IS NOT NULL
  AND (payload->>'public_post_id') IS NULL
  AND (payload->>'mention_count')::int = 0,
  'Entry-only path returns entry_id and no publish artifacts'
)
FROM res;

SELECT is(
  (SELECT COUNT(*)::int FROM public.gratitude_wall_posts WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
     AND author_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')),
  0,
  'No wall post created when publish not requested'
);

-- member_two: non-positive publish attempt with mentions -> NOT_POSITIVE_MOOD
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_two'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.mood_submit_v2(
      '%s', 'rainy', 'Cannot publish', false, ARRAY['%s']::uuid[]
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_one')
  ),
  'NOT_POSITIVE_MOOD',
  'Reject publishing when mood is not positive'
);

-- member_two: positive publish with wall + mentions (dedup + delivery)
WITH res AS (
  SELECT public.mood_submit_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'sunny',
    'Thanks team!',
    true,
    ARRAY[(SELECT user_id FROM tmp_users WHERE label = 'member_one')]::uuid[]
  ) AS payload
)
SELECT ok(
  (payload->>'public_post_id') IS NOT NULL
  AND (payload->>'mention_count')::int = 1,
  'Positive publish creates wall post and counts deduped mentions'
)
FROM res;

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.gratitude_wall_mentions gm
    WHERE gm.post_id IN (
      SELECT id FROM public.gratitude_wall_posts WHERE source_entry_id IS NOT NULL
    )),
  1,
  'Exactly one wall mention edge created'
);

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.gratitude_wall_personal_items pi
    WHERE pi.recipient_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')),
  1,
  'Personal inbox receives one item per mentioned recipient'
);

-- member_two: duplicate weekly submission -> MOOD_ALREADY_SUBMITTED
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.mood_submit_v2(
      '%s', 'sunny', 'Duplicate week', true, NULL::uuid[]
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'MOOD_ALREADY_SUBMITTED',
  'Reject second weekly submission for same user'
);

-- creator: self-mention blocked
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.mood_submit_v2(
      '%s', 'sunny', 'Duplicate mentions', false, ARRAY['%s','%s']::uuid[]
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_one')
  ),
  'DUPLICATE_MENTIONS_NOT_ALLOWED',
  'Duplicate mentions are rejected'
);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.mood_submit_v2(
      '%s', 'sunny', 'Self shoutout', false, ARRAY['%s']::uuid[]
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ),
  'SELF_MENTION_NOT_ALLOWED',
  'Self mentions are rejected'
);

-- outsider blocked from submitting
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.mood_submit_v2(
      '%s', 'sunny', 'No access', false, NULL
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'NOT_HOME_MEMBER',
  'Non-members cannot submit moods'
);

-- Personal inbox status/list/read for member_one (recipient)
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH status AS (
  SELECT * FROM public.personal_gratitude_wall_status_v1()
)
SELECT ok(
  (SELECT has_unread FROM status) IS TRUE,
  'Recipient sees unread personal gratitude'
);

WITH list AS (
  SELECT * FROM public.personal_gratitude_inbox_list_v1(10)
)
SELECT is(
  (SELECT COUNT(*)::int FROM list),
  1,
  'Inbox list returns one item for the mention'
);

SELECT public.personal_gratitude_wall_mark_read_v1();

WITH status AS (
  SELECT * FROM public.personal_gratitude_wall_status_v1()
)
SELECT ok(
  (SELECT has_unread FROM status) IS FALSE,
  'Mark read clears unread flag'
);

-- Showcase stats exclude self by default
WITH stats AS (
  SELECT public.personal_gratitude_showcase_stats_v1() AS payload
)
SELECT ok(
  (payload->>'total_received')::int = 1
  AND (payload->>'unique_individuals')::int = 1
  AND (payload->>'unique_homes')::int = 1,
  'Showcase stats report counts for received mentions (exclude self)'
)
FROM stats;

-- member_three: negative mood with one mention creates personal item and rewrite trigger
INSERT INTO public.preference_taxonomy (preference_id, is_active)
VALUES ('test_pref', TRUE)
ON CONFLICT (preference_id) DO NOTHING;

INSERT INTO public.preference_responses (user_id, preference_id, option_index)
VALUES ((SELECT user_id FROM tmp_users WHERE label = 'member_one'), 'test_pref', 0)
ON CONFLICT (user_id, preference_id) DO NOTHING;

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member_three'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

CREATE TEMP TABLE tmp_member_three_negative_submit AS
SELECT public.mood_submit_v2(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'thunderstorm',
  'Really stuck because the dishes piled up. Please help next time.',
  false,
  ARRAY[(SELECT user_id FROM tmp_users WHERE label = 'member_one')]::uuid[]
) AS payload;

WITH res AS (
  SELECT payload
  FROM tmp_member_three_negative_submit
)
SELECT ok(
  (payload->>'mention_count')::int = 1
  AND (payload->>'public_post_id') IS NULL
  AND (payload->>'rewrite_recipient_id')::uuid = (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
  'Negative mood with one mention returns mention_count=1 and rewrite recipient'
)
FROM res;

WITH res AS (
  SELECT payload
  FROM tmp_member_three_negative_submit
)
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.gratitude_wall_personal_items pi
    WHERE pi.recipient_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')
      AND pi.source_entry_id = (
        SELECT (payload->>'entry_id')::uuid FROM res
      )
  ),
  'Negative mention creates personal inbox item'
)
FROM res;

WITH res AS (
  SELECT payload
  FROM tmp_member_three_negative_submit
)
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.complaint_rewrite_triggers t
    WHERE t.entry_id = (
      SELECT (payload->>'entry_id')::uuid FROM res
    )
      AND t.recipient_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')
  ),
  'Negative mention with prefs enqueues complaint rewrite trigger'
)
FROM res;

SELECT * FROM finish();

ROLLBACK;
