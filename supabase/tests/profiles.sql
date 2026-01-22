SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(7);

CREATE TEMP TABLE tmp_profile_ids (
  owner_id uuid,
  home_id  uuid
);

-- Seed two avatars (animal + premium category).
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-9000-000000000801', 'avatars/test-animal.png', 'animal', 'Test Animal Avatar'),
  ('00000000-0000-4000-9000-000000000802', 'avatars/test-plant.png',  'plant',  'Test Plant Avatar')
ON CONFLICT (id) DO NOTHING;

-- Create the owner auth user (trigger seeds profiles automatically).
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES (
  '00000000-0000-4000-9000-000000000501',
  '00000000-0000-0000-0000-000000000000',
  'profile-owner@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
)
ON CONFLICT (id) DO NOTHING;

-- Owner context
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-9000-000000000501', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Owner creates a home (defaults to plan=free)
WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_profile_ids (owner_id, home_id)
SELECT
  '00000000-0000-4000-9000-000000000501',
  (payload->'home'->>'id')::uuid
FROM res;

-- profile_me returns the caller's identity
WITH payload AS (
  SELECT * FROM public.profile_me()
)
SELECT is(
  (SELECT user_id::text FROM payload),
  '00000000-0000-4000-9000-000000000501',
  'profile_me returns current user id'
);

WITH payload AS (
  SELECT * FROM public.profile_me()
)
SELECT ok(
  (SELECT avatar_storage_path FROM payload) IS NOT NULL,
  'profile_me returns avatar storage path'
);

-- Free plan hides premium avatar categories
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.avatars_list_for_home(
      (SELECT home_id FROM tmp_profile_ids)
    )
    WHERE category <> 'animal'
  ),
  'free homes only see animal avatars'
);

-- Attempting to use a premium avatar on the free plan should error
SELECT throws_like(
  $$
  SELECT public.profile_identity_update(
    'owner_premium',
    '00000000-0000-4000-9000-000000000802'::uuid
  )
  $$,
  '%AVATAR_NOT_ALLOWED_FOR_PLAN%',
  'profile_identity_update blocks premium avatars on free homes'
);

-- Upgrade the home to premium to permit premium avatars
UPDATE public.home_entitlements
SET plan = 'premium', expires_at = now() + interval '30 days'
WHERE home_id = (SELECT home_id FROM tmp_profile_ids);

WITH payload AS (
  SELECT *
  FROM public.profile_identity_update(
    'owner_premium',
    '00000000-0000-4000-9000-000000000802'::uuid
  )
)
SELECT is(
  (SELECT avatar_id::text FROM payload),
  '00000000-0000-4000-9000-000000000802',
  'profile_identity_update succeeds once plan is premium'
);

WITH payload AS (
  SELECT * FROM public.profile_me()
)
SELECT is(
  (SELECT avatar_storage_path FROM payload),
  'avatars/test-plant.png',
  'profile_me reflects the updated avatar storage path'
);

-- Premium plans expose every avatar category (including the caller's current selection)
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.avatars_list_for_home(
      (SELECT home_id FROM tmp_profile_ids)
    )
    WHERE category = 'plant'
  ),
  'premium homes can browse premium avatar categories'
);

SELECT * FROM finish();
ROLLBACK;
