SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(8);

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

-- Seed auth users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000901', 'owner-house-vibe-compute@example.com'),
  ('member', '00000000-0000-4000-8000-000000000902', 'member-house-vibe-compute@example.com');

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

-- Service role to seed preference responses (contributors need complete set)
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;

CREATE TEMP TABLE tmp_pref_choices (
  preference_id text,
  owner_opt smallint,
  member_opt smallint,
  member_opt_mixed smallint
);

INSERT INTO tmp_pref_choices VALUES
  ('environment_noise_tolerance',     2, 2, 0),
  ('environment_light_preference',    2, 2, 0),
  ('environment_scent_sensitivity',   2, 2, 0),
  ('schedule_quiet_hours_preference', 2, 2, 0),
  ('schedule_sleep_timing',           2, 2, 0),
  ('communication_channel',           2, 2, 0),
  ('communication_directness',        2, 2, 0),
  ('cleanliness_shared_space_tolerance', 2, 2, 0),
  ('privacy_room_entry',              2, 2, 0),
  ('privacy_notifications',           2, 2, 0),
  ('social_hosting_frequency',        2, 2, 0),
  ('social_togetherness',             2, 2, 0),
  ('routine_planning_style',          2, 2, 0),
  ('conflict_resolution_style',       2, 2, 0);

INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
SELECT current_setting('test.owner_id')::uuid, preference_id, owner_opt, now() FROM tmp_pref_choices
UNION ALL
SELECT current_setting('test.member_id')::uuid, preference_id, member_opt, now() FROM tmp_pref_choices;

-- Switch back to owner for RPC calls
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', current_setting('test.owner_id'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- First compute: contributors=2, label should resolve to social_home (energy/social high), source computed
CREATE TEMP TABLE tmp_vibe_res AS
SELECT public.house_vibe_compute(current_setting('test.home_id')::uuid, false, false) AS res;

SELECT is(
  (SELECT res->>'label_id' FROM tmp_vibe_res),
  'social_home',
  'first compute resolves to social_home'
);

SELECT is(
  (SELECT (res->'coverage'->>'answered')::int FROM tmp_vibe_res),
  2,
  'coverage_answered = contributors (2)'
);

SELECT is(
  (SELECT res->>'source' FROM tmp_vibe_res),
  'computed',
  'first call marks source=computed'
);

-- Second compute without changes should hit cache
SELECT is(
  public.house_vibe_compute(current_setting('test.home_id')::uuid, false, false)->>'source',
  'cache',
  'subsequent call uses cache when not out_of_date'
);

-- Make member opposite to force mixed axis (energy/social)
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
UPDATE public.preference_responses pr
SET option_index = c.member_opt_mixed
FROM tmp_pref_choices c
WHERE pr.user_id = current_setting('test.member_id')::uuid
  AND pr.preference_id = c.preference_id;
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  public.house_vibe_compute(current_setting('test.home_id')::uuid, false, false)->>'label_id',
  'mixed_home',
  'mixed votes resolve to mixed_home'
);

-- Remove one preference for member to drop contributor count below 2 -> insufficient_data
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
DELETE FROM public.preference_responses
WHERE user_id = current_setting('test.member_id')::uuid
  AND preference_id = 'environment_noise_tolerance';
RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  public.house_vibe_compute(current_setting('test.home_id')::uuid, false, false)->>'label_id',
  'insufficient_data',
  'incomplete contributor set falls back to insufficient_data'
);

-- Cozy social: energy high, noise low, social high -> cozy_social_home
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
DELETE FROM public.preference_responses
WHERE user_id IN (current_setting('test.owner_id')::uuid, current_setting('test.member_id')::uuid);

WITH data(preference_id, owner_opt, member_opt) AS (
  VALUES
    ('environment_noise_tolerance', 0, 0),
    ('environment_light_preference', 2, 2),
    ('schedule_quiet_hours_preference', 0, 0),
    ('schedule_sleep_timing', 2, 2),
    ('environment_scent_sensitivity', 2, 2),
    ('communication_channel', 2, 2),
    ('communication_directness', 2, 2),
    ('cleanliness_shared_space_tolerance', 2, 2),
    ('privacy_room_entry', 2, 2),
    ('privacy_notifications', 2, 2),
    ('social_hosting_frequency', 2, 2),
    ('social_togetherness', 2, 2),
    ('routine_planning_style', 2, 2),
    ('conflict_resolution_style', 2, 2)
)
INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
SELECT current_setting('test.owner_id')::uuid, preference_id, owner_opt, now() FROM data
UNION ALL
SELECT current_setting('test.member_id')::uuid, preference_id, member_opt, now() FROM data;

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  public.house_vibe_compute(current_setting('test.home_id')::uuid, false, false)->>'label_id',
  'cozy_social_home',
  'noise low + social high resolves to cozy_social_home'
);

-- Warm social: energy balanced, noise balanced, social high -> warm_social_home
SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;
DELETE FROM public.preference_responses
WHERE user_id IN (current_setting('test.owner_id')::uuid, current_setting('test.member_id')::uuid);

WITH data(preference_id, owner_opt, member_opt) AS (
  VALUES
    ('environment_noise_tolerance', 1, 1),
    ('environment_light_preference', 1, 1),
    ('schedule_quiet_hours_preference', 2, 2),
    ('schedule_sleep_timing', 1, 1),
    ('environment_scent_sensitivity', 2, 2),
    ('communication_channel', 2, 2),
    ('communication_directness', 2, 2),
    ('cleanliness_shared_space_tolerance', 2, 2),
    ('privacy_room_entry', 2, 2),
    ('privacy_notifications', 2, 2),
    ('social_hosting_frequency', 1, 1),
    ('social_togetherness', 2, 2),
    ('routine_planning_style', 2, 2),
    ('conflict_resolution_style', 2, 2)
)
INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
SELECT current_setting('test.owner_id')::uuid, preference_id, owner_opt, now() FROM data
UNION ALL
SELECT current_setting('test.member_id')::uuid, preference_id, member_opt, now() FROM data;

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  public.house_vibe_compute(current_setting('test.home_id')::uuid, false, false)->>'label_id',
  'warm_social_home',
  'social high with neutral energy resolves to warm_social_home'
);

SELECT * FROM finish();

ROLLBACK;
