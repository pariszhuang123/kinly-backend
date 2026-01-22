SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(8);

-- ---------------------------------------------------------------------------
-- Seed auth users + home
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

-- Starter avatars required by handle_new_user trigger (unique per home)
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000501', 'avatars/default.png', 'animal', 'Test Avatar'),
  ('00000000-0000-4000-8000-000000000502', 'avatars/pulse-alt-1.png', 'animal', 'Pulse Alt 1'),
  ('00000000-0000-4000-8000-000000000503', 'avatars/pulse-alt-2.png', 'animal', 'Pulse Alt 2')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000a01', 'owner-house-pulse@example.com'),
  ('member', '00000000-0000-4000-8000-000000000a02', 'member-house-pulse@example.com');

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

-- Owner creates home + invite
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'home', (payload->'home'->>'id')::uuid FROM res;

-- Member joins
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join(
  (SELECT code::text FROM public.invites WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'home') AND revoked_at IS NULL LIMIT 1)
);

-- Persist IDs for reuse
SELECT set_config('test.owner_id', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('test.member_id', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('test.home_id', (SELECT home_id::text FROM tmp_homes WHERE label = 'home'), true);

-- ISO week/year anchor (UTC)
DO $$
BEGIN
  PERFORM set_config(
    'test.iso_week',
    to_char((now() AT TIME ZONE 'UTC')::date, 'IW')::int::text,
    true
  );
  PERFORM set_config(
    'test.iso_year',
    to_char((now() AT TIME ZONE 'UTC')::date, 'IYYY')::int::text,
    true
  );
END;
$$;

-- Helper insert performed as service_role (bypass RLS)
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;

-- Reset to owner for RPC calls
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', current_setting('test.owner_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- ---------------------------------------------------------------------------
-- Test 1: Forming gate when only one reflection (P=2, R=1, participation <0.30)
-- ---------------------------------------------------------------------------
INSERT INTO public.home_mood_entries (home_id, user_id, mood, comment, iso_week_year, iso_week)
VALUES (
  current_setting('test.home_id')::uuid,
  current_setting('test.owner_id')::uuid,
  'partially_sunny',
  NULL,
  current_setting('test.iso_year')::int,
  current_setting('test.iso_week')::int
)
ON CONFLICT (user_id, iso_week_year, iso_week) DO UPDATE
  SET mood = EXCLUDED.mood, comment = EXCLUDED.comment;

SELECT public.house_pulse_compute_week(
  current_setting('test.home_id')::uuid,
  current_setting('test.iso_year')::int,
  current_setting('test.iso_week')::int
);

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT is(res.payload->'pulse'->>'pulse_state', 'forming', 'forms when only one reflection and participation too low') FROM res;

-- ---------------------------------------------------------------------------
-- Test 2: Sunny calm when both members submit light moods and no friction
-- ---------------------------------------------------------------------------
INSERT INTO public.home_mood_entries (home_id, user_id, mood, comment, iso_week_year, iso_week)
VALUES (
  current_setting('test.home_id')::uuid,
  current_setting('test.member_id')::uuid,
  'sunny',
  NULL,
  current_setting('test.iso_year')::int,
  current_setting('test.iso_week')::int
)
ON CONFLICT (user_id, iso_week_year, iso_week) DO UPDATE
  SET mood = EXCLUDED.mood, comment = EXCLUDED.comment;

SELECT public.house_pulse_compute_week(
  current_setting('test.home_id')::uuid,
  current_setting('test.iso_year')::int,
  current_setting('test.iso_week')::int
);

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT is(res.payload->'pulse'->>'pulse_state', 'sunny_calm', 'sunny_calm when light_ratio high, care_present, no friction') FROM res;

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT is(res.payload->'pulse'->>'weather_display', 'sunny', 'weather_display maps sunny_calm to sunny') FROM res;

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT ok((res.payload->'pulse'->>'care_present')::boolean, 'care_present true when light_ratio >= 0.25 and two participants') FROM res;

-- ---------------------------------------------------------------------------
-- Test 3: Thunderstorm override when any thunderstorm mood present
-- ---------------------------------------------------------------------------
INSERT INTO public.home_mood_entries (home_id, user_id, mood, comment, iso_week_year, iso_week)
VALUES (
  current_setting('test.home_id')::uuid,
  current_setting('test.owner_id')::uuid,
  'thunderstorm',
  'heavy week',
  current_setting('test.iso_year')::int,
  current_setting('test.iso_week')::int
)
ON CONFLICT (user_id, iso_week_year, iso_week) DO UPDATE
  SET mood = EXCLUDED.mood, comment = EXCLUDED.comment;

SELECT public.house_pulse_compute_week(
  current_setting('test.home_id')::uuid,
  current_setting('test.iso_year')::int,
  current_setting('test.iso_week')::int
);

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT is(res.payload->'pulse'->>'pulse_state', 'thunderstorm', 'thunderstorm overrides other states') FROM res;

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT ok((res.payload->'pulse'->>'friction_present')::boolean, 'friction_present true when thunderstorm present') FROM res;

-- ---------------------------------------------------------------------------
-- Test 4: mark_seen records pulse_state/computed_at for caller
-- ---------------------------------------------------------------------------
WITH seen AS (
  SELECT public.house_pulse_mark_seen(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS row
)
SELECT is((seen.row).last_seen_pulse_state::text, 'thunderstorm', 'mark_seen stores last_seen_pulse_state') FROM seen;

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
SELECT set_config(
  'test.pulse_read_exists',
  (
    SELECT EXISTS (
      SELECT 1
      FROM public.house_pulse_reads
      WHERE user_id = current_setting('test.owner_id')::uuid
      LIMIT 1
    )::text
  ),
  true
);
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT ok(
  current_setting('test.pulse_read_exists')::boolean,
  'house_pulse_reads row written'::text
);

-- ---------------------------------------------------------------------------
-- Done
-- ---------------------------------------------------------------------------
SELECT finish();

ROLLBACK;
