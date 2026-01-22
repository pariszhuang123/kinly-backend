SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(7);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE invite_codes (
  label text PRIMARY KEY,
  code  text
);

-- Ensure avatars exist for profile creation hooks
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000701', 'avatars/default.png', 'animal', 'House Vibe Avatar 1'),
  ('00000000-0000-4000-8000-000000000702', 'avatars/default2.png', 'animal', 'House Vibe Avatar 2')
ON CONFLICT (id) DO NOTHING;

-- Seed auth users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000811', 'owner-house-vibe@example.com'),
  ('member', '00000000-0000-4000-8000-000000000812', 'member-house-vibe@example.com');

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

-- Owner creates home
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'home', (payload->'home'->>'id')::uuid FROM res;

INSERT INTO invite_codes (label, code)
SELECT 'home', (SELECT code::text FROM public.invites WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'home') AND revoked_at IS NULL LIMIT 1);

-- Member joins home
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM invite_codes WHERE label = 'home'));

-- Persist identifiers for service_role block without temp table access
SELECT set_config('test.owner_id', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('test.home_id', (SELECT home_id::text FROM tmp_homes WHERE label = 'home'), true);

-- Switch to service_role for direct table checks (tables are service-role only)
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;

-- Seed checks
CREATE TEMP TABLE tmp_vibe_seed_counts AS
SELECT
  (SELECT count(*) FROM public.house_vibe_labels WHERE mapping_version = 'v1')::bigint AS labels_count,
  (SELECT count(*) FROM public.house_vibe_mapping_effects WHERE mapping_version = 'v1')::bigint AS mapping_effects_count;

-- share_events allows feature = house_vibe
INSERT INTO public.share_events (user_id, home_id, feature, channel)
VALUES (
  current_setting('test.owner_id')::uuid,
  current_setting('test.home_id')::uuid,
  'house_vibe',
  'system_share'
);

CREATE TEMP TABLE tmp_share_events_count AS
SELECT count(*)::int AS share_event_count
FROM public.share_events
WHERE home_id = current_setting('test.home_id')::uuid
  AND feature = 'house_vibe'
  AND channel = 'system_share';

-- Invalidation from memberships (owner created home, member joined)
CREATE TEMP TABLE tmp_vibe_membership_invalidation AS
SELECT
  EXISTS (
    SELECT 1
    FROM public.house_vibes
    WHERE home_id = current_setting('test.home_id')::uuid
      AND out_of_date = true
      AND invalidated_at IS NOT NULL
      AND coverage_total = 2
  ) AS has_membership_invalidation;

-- Capture invalidated_at after member join
UPDATE public.house_vibes
SET invalidated_at = now() - interval '1 second'
WHERE home_id = current_setting('test.home_id')::uuid;

CREATE TEMP TABLE hv_snapshot AS
SELECT invalidated_at AS prev_inv
FROM public.house_vibes
WHERE home_id = current_setting('test.home_id')::uuid;

-- Preference update triggers invalidation bump
INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
VALUES (
  current_setting('test.owner_id')::uuid,
  'environment_noise_tolerance',
  0,
  now()
);

CREATE TEMP TABLE tmp_vibe_invalidation_after AS
SELECT
  (SELECT invalidated_at FROM public.house_vibes WHERE home_id = current_setting('test.home_id')::uuid) AS curr_inv,
  (SELECT out_of_date FROM public.house_vibes WHERE home_id = current_setting('test.home_id')::uuid) AS out_of_date_after;

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT ok(
  (SELECT labels_count FROM tmp_vibe_seed_counts) >= 8,
  'house_vibe_labels v1 seeded'
);

SELECT is(
  (SELECT mapping_effects_count FROM tmp_vibe_seed_counts),
  39::bigint,
  'house_vibe_mapping_effects v1 seeded with 39 rows'
);

SELECT is(
  (SELECT share_event_count FROM tmp_share_events_count),
  1,
  'share_events accepts feature=house_vibe with system_share channel'
);

SELECT ok(
  (SELECT has_membership_invalidation FROM tmp_vibe_membership_invalidation),
  'house_vibes row exists with out_of_date=true, invalidated_at set, coverage_total=2 after memberships'
);

SELECT ok(
  (SELECT curr_inv FROM tmp_vibe_invalidation_after) > (SELECT prev_inv FROM hv_snapshot),
  'preference_responses change bumps invalidated_at on house_vibes'
);

SELECT ok(
  (SELECT curr_inv FROM tmp_vibe_invalidation_after) IS NOT NULL,
  'house_vibes invalidated_at remains set after preference change'
);

-- out_of_date stays true until compute clears it
SELECT ok(
  (SELECT out_of_date_after FROM tmp_vibe_invalidation_after),
  'house_vibes remains out_of_date after preference change'
);

SELECT * FROM finish();

ROLLBACK;
