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

-- Ensure avatars exist for profile creation hooks
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000701', 'avatars/default.png', 'animal', 'House Vibe Avatar 1'),
  ('00000000-0000-4000-8000-000000000702', 'avatars/default2.png', 'animal', 'House Vibe Avatar 2')
ON CONFLICT (id) DO NOTHING;

-- Ensure enough unique avatars exist for multi-member join scenarios.
INSERT INTO public.avatars (id, storage_path, category, name)
SELECT
  gen_random_uuid(),
  'avatars/house-vibe-compute-' || g::text || '.png',
  'animal',
  'House Vibe Compute Avatar ' || g::text
FROM generate_series(1, 20) AS g;

-- Seed auth users for large-home and small-home scenarios
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner_large', '00000000-0000-4000-8000-000000001001', 'owner-large-house-vibe@example.com'),
  ('l1',         '00000000-0000-4000-8000-000000001002', 'l1-house-vibe@example.com'),
  ('l2',         '00000000-0000-4000-8000-000000001003', 'l2-house-vibe@example.com'),
  ('l3',         '00000000-0000-4000-8000-000000001004', 'l3-house-vibe@example.com'),
  ('l4',         '00000000-0000-4000-8000-000000001005', 'l4-house-vibe@example.com'),
  ('l5',         '00000000-0000-4000-8000-000000001006', 'l5-house-vibe@example.com'),
  ('owner_small','00000000-0000-4000-8000-000000001007', 'owner-small-house-vibe@example.com'),
  ('s1',         '00000000-0000-4000-8000-000000001008', 's1-house-vibe@example.com'),
  ('s2',         '00000000-0000-4000-8000-000000001009', 's2-house-vibe@example.com');

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

-- Persist user IDs for service-role blocks (service role cannot read temp tables here).
SELECT set_config('test.owner_large_id', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_large'), true);
SELECT set_config('test.l1_id', (SELECT user_id::text FROM tmp_users WHERE label = 'l1'), true);
SELECT set_config('test.l2_id', (SELECT user_id::text FROM tmp_users WHERE label = 'l2'), true);
SELECT set_config('test.l3_id', (SELECT user_id::text FROM tmp_users WHERE label = 'l3'), true);
SELECT set_config('test.l4_id', (SELECT user_id::text FROM tmp_users WHERE label = 'l4'), true);
SELECT set_config('test.l5_id', (SELECT user_id::text FROM tmp_users WHERE label = 'l5'), true);
SELECT set_config('test.owner_small_id', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_small'), true);
SELECT set_config('test.s1_id', (SELECT user_id::text FROM tmp_users WHERE label = 's1'), true);
SELECT set_config('test.s2_id', (SELECT user_id::text FROM tmp_users WHERE label = 's2'), true);

-- Active mapping must be v2 after cutover migration.
SELECT is(
  (
    SELECT mapping_version
    FROM public.house_vibe_versions
    WHERE status = 'active'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'v2',
  'house_vibe active mapping version is v2'
);

-- ------------------------------
-- Large-home scenario (5 members: 3 high vs 2 low should NOT be mixed in v2)
-- ------------------------------
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_large'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'home_large', (payload->'home'->>'id')::uuid FROM res;

SELECT set_config('test.large_owner_id', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_large'), true);
SELECT set_config('test.large_home_id', (SELECT home_id::text FROM tmp_homes WHERE label = 'home_large'), true);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'l1'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.large_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'l2'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.large_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'l3'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.large_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'l4'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.large_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;

INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
WITH pref_choices(preference_id, high_opt, low_opt) AS (
  VALUES
    ('environment_noise_tolerance', 2::smallint, 0::smallint),
    ('environment_light_preference', 2::smallint, 0::smallint),
    ('environment_scent_sensitivity', 2::smallint, 0::smallint),
    ('schedule_quiet_hours_preference', 2::smallint, 0::smallint),
    ('schedule_sleep_timing', 2::smallint, 0::smallint),
    ('communication_channel', 2::smallint, 0::smallint),
    ('communication_directness', 2::smallint, 0::smallint),
    ('cleanliness_shared_space_tolerance', 2::smallint, 0::smallint),
    ('privacy_room_entry', 2::smallint, 0::smallint),
    ('privacy_notifications', 2::smallint, 0::smallint),
    ('social_hosting_frequency', 2::smallint, 0::smallint),
    ('social_togetherness', 2::smallint, 0::smallint),
    ('routine_planning_style', 2::smallint, 0::smallint),
    ('conflict_resolution_style', 2::smallint, 0::smallint)
)
SELECT u.user_id, p.preference_id, p.high_opt, now()
FROM (
  VALUES
    (current_setting('test.owner_large_id')::uuid),
    (current_setting('test.l1_id')::uuid),
    (current_setting('test.l2_id')::uuid)
) AS u(user_id)
JOIN pref_choices p ON true
UNION ALL
SELECT u.user_id, p.preference_id, p.low_opt, now()
FROM (
  VALUES
    (current_setting('test.l3_id')::uuid),
    (current_setting('test.l4_id')::uuid)
) AS u(user_id)
JOIN pref_choices p ON true
;

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', current_setting('test.large_owner_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

CREATE TEMP TABLE tmp_large_res_5 AS
SELECT public.house_vibe_compute(current_setting('test.large_home_id')::uuid, false, true) AS res;

SELECT ok(
  (SELECT res->>'label_id' FROM tmp_large_res_5) <> 'mixed_home',
  '5-member 3-vs-2 split does not resolve to mixed_home in v2'
);

SELECT is(
  (SELECT res->>'mapping_version' FROM tmp_large_res_5),
  'v2',
  'large-home compute resolves using v2 mapping'
);

-- Add 6th member to force 3-vs-3 split -> mixed_home
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'l5'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.large_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
WITH pref_choices(preference_id, low_opt) AS (
  VALUES
    ('environment_noise_tolerance', 0::smallint),
    ('environment_light_preference', 0::smallint),
    ('environment_scent_sensitivity', 0::smallint),
    ('schedule_quiet_hours_preference', 0::smallint),
    ('schedule_sleep_timing', 0::smallint),
    ('communication_channel', 0::smallint),
    ('communication_directness', 0::smallint),
    ('cleanliness_shared_space_tolerance', 0::smallint),
    ('privacy_room_entry', 0::smallint),
    ('privacy_notifications', 0::smallint),
    ('social_hosting_frequency', 0::smallint),
    ('social_togetherness', 0::smallint),
    ('routine_planning_style', 0::smallint),
    ('conflict_resolution_style', 0::smallint)
)
SELECT
  current_setting('test.l5_id')::uuid,
  p.preference_id,
  p.low_opt,
  now()
FROM pref_choices p;
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT set_config('request.jwt.claim.sub', current_setting('test.large_owner_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  public.house_vibe_compute(current_setting('test.large_home_id')::uuid, false, false)->>'label_id',
  'mixed_home',
  '6-member 3-vs-3 split resolves to mixed_home in v2'
);

-- ------------------------------
-- Small-home scenario (3 members stays sensitive)
-- ------------------------------
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_small'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'home_small', (payload->'home'->>'id')::uuid FROM res;

SELECT set_config('test.small_owner_id', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_small'), true);
SELECT set_config('test.small_home_id', (SELECT home_id::text FROM tmp_homes WHERE label = 'home_small'), true);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 's1'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.small_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 's2'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code::text FROM public.invites WHERE home_id = current_setting('test.small_home_id')::uuid AND revoked_at IS NULL LIMIT 1));

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;

INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
WITH pref_choices(preference_id, high_opt, low_opt) AS (
  VALUES
    ('environment_noise_tolerance', 2::smallint, 0::smallint),
    ('environment_light_preference', 2::smallint, 0::smallint),
    ('environment_scent_sensitivity', 2::smallint, 0::smallint),
    ('schedule_quiet_hours_preference', 2::smallint, 0::smallint),
    ('schedule_sleep_timing', 2::smallint, 0::smallint),
    ('communication_channel', 2::smallint, 0::smallint),
    ('communication_directness', 2::smallint, 0::smallint),
    ('cleanliness_shared_space_tolerance', 2::smallint, 0::smallint),
    ('privacy_room_entry', 2::smallint, 0::smallint),
    ('privacy_notifications', 2::smallint, 0::smallint),
    ('social_hosting_frequency', 2::smallint, 0::smallint),
    ('social_togetherness', 2::smallint, 0::smallint),
    ('routine_planning_style', 2::smallint, 0::smallint),
    ('conflict_resolution_style', 2::smallint, 0::smallint)
)
SELECT u.user_id, p.preference_id, p.high_opt, now()
FROM (
  VALUES
    (current_setting('test.owner_small_id')::uuid),
    (current_setting('test.s1_id')::uuid)
) AS u(user_id)
JOIN pref_choices p ON true
UNION ALL
SELECT u.user_id, p.preference_id, p.low_opt, now()
FROM (
  VALUES
    (current_setting('test.s2_id')::uuid)
) AS u(user_id)
JOIN pref_choices p ON true
;

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', current_setting('test.small_owner_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  public.house_vibe_compute(current_setting('test.small_home_id')::uuid, false, false)->>'label_id',
  'mixed_home',
  '3-member split remains mixed_home (small-home sensitivity unchanged)'
);

SELECT is(
  (
    SELECT min_side_count_small::text || '/' || min_side_count_large::text
    FROM public.house_vibe_versions
    WHERE mapping_version = 'v2'
  ),
  '1/3',
  'v2 thresholds are min_side_count_small=1 and min_side_count_large=3'
);

SELECT * FROM finish();

ROLLBACK;
