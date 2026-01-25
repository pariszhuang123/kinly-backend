SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(3);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000521', 'avatars/default.png', 'animal', 'Pulse Refresh 1'),
  ('00000000-0000-4000-8000-000000000522', 'avatars/pulse-alt-1.png', 'animal', 'Pulse Refresh 2'),
  ('00000000-0000-4000-8000-000000000523', 'avatars/pulse-alt-2.png', 'animal', 'Pulse Refresh 3')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000b01', 'owner-house-pulse-refresh@example.com'),
  ('member', '00000000-0000-4000-8000-000000000b02', 'member-house-pulse-refresh@example.com');

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

-- Canonical ISO week/year (UTC)
DO $$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM public._iso_week_utc();
  PERFORM set_config('test.iso_week', r.iso_week::text, true);
  PERFORM set_config('test.iso_year', r.iso_week_year::text, true);
END;
$$;

-- Owner submits first reflection (no publish) -> forming snapshot stored
SELECT set_config('request.jwt.claim.sub', current_setting('test.owner_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.mood_submit_v2(
    current_setting('test.home_id')::uuid,
    'partially_sunny',
    'solo reflection',
    false,
    NULL
  ) AS payload
)
SELECT is(
  res.payload->'pulse'->>'pulse_state',
  'forming',
  'First reflection computes forming snapshot via mood_submit_v2'
) FROM res;

-- Weekly get returns the forming snapshot
WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT is(
  res.payload->'pulse'->>'pulse_state',
  'forming',
  'Initial weekly_get returns forming snapshot'
) FROM res;

-- Member submits second reflection -> weekly_get should recompute to sunny_calm
SELECT set_config('request.jwt.claim.sub', current_setting('test.member_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.mood_submit_v2(
  current_setting('test.home_id')::uuid,
  'sunny',
  'second reflection',
  false,
  NULL
);

WITH res AS (
  SELECT public.house_pulse_weekly_get(
    current_setting('test.home_id')::uuid,
    current_setting('test.iso_year')::int,
    current_setting('test.iso_week')::int
  ) AS payload
)
SELECT is(
  res.payload->'pulse'->>'pulse_state',
  'sunny_calm',
  'weekly_get recomputes snapshot after new reflection'
) FROM res;

SELECT * FROM finish();

ROLLBACK;
