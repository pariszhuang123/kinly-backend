SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(5);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE tmp_invites (
  label text PRIMARY KEY,
  code  text
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

-- Seed avatars with deterministic order (animals for free plan + one premium)
INSERT INTO public.avatars (id, storage_path, category, name, created_at)
VALUES
  ('00000000-0000-4000-9000-000000000901', 'avatars/a.png', 'animal', 'Avatar A', '2025-01-01'),
  ('00000000-0000-4000-9000-000000000902', 'avatars/b.png', 'animal', 'Avatar B', '2025-01-02'),
  ('00000000-0000-4000-9000-000000000903', 'avatars/c.png', 'plant',  'Avatar C', '2025-01-03')
ON CONFLICT (id) DO NOTHING;

-- Seed users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',    '00000000-0000-4000-9000-000000000801', 'owner-uniq@example.com'),
  ('joiner1',  '00000000-0000-4000-9000-000000000802', 'joiner1-uniq@example.com'),
  ('joiner2',  '00000000-0000-4000-9000-000000000803', 'joiner2-uniq@example.com');

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

-- Align all profiles to the same starting avatar (Avatar A)
UPDATE public.profiles
   SET avatar_id = '00000000-0000-4000-9000-000000000901'
 WHERE id IN (SELECT user_id FROM tmp_users)
   AND deactivated_at IS NULL;

-- Owner creates a home + invite
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

INSERT INTO tmp_invites (label, code)
SELECT 'primary', code::text
FROM public.invites i
WHERE i.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND i.revoked_at IS NULL
LIMIT 1;

SELECT ok(
  (SELECT home_id IS NOT NULL FROM tmp_homes WHERE label = 'primary'),
  'home created with invite'
);

-- First joiner: should be reassigned to the next available animal avatar
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'joiner1'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary'));

SELECT is(
  (SELECT avatar_id::text FROM public.profiles WHERE id = (SELECT user_id FROM tmp_users WHERE label = 'joiner1')),
  '00000000-0000-4000-9000-000000000902',
  'joiner1 is assigned the next available avatar'
);

SELECT is(
  (SELECT COUNT(*) FROM public.memberships
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'joiner1')
      AND is_current),
  1::bigint,
  'joiner1 has a current membership after join'
);

SELECT is(
  (SELECT avatar_id::text FROM public.profiles WHERE id = (SELECT user_id FROM tmp_users WHERE label = 'owner')),
  '00000000-0000-4000-9000-000000000901',
  'owner avatar remains unchanged'
);

-- Second joiner: no animal avatars left, should error with NO_AVAILABLE_AVATAR
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'joiner2'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary')); $$,
  'NO_AVAILABLE_AVATAR',
  'joining fails when no avatars are available for the plan'
);

SELECT * FROM finish();
ROLLBACK;
