SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(8);
-- Seed default avatar required by handle_new_user()
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000999', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- Seed users
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000000901', '00000000-0000-0000-0000-000000000000', 'plan-premium@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000902', '00000000-0000-0000-0000-000000000000', 'plan-free@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000903', '00000000-0000-0000-0000-000000000000', 'plan-expired@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000904', '00000000-0000-0000-0000-000000000000', 'plan-inactive@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000905', '00000000-0000-0000-0000-000000000000', 'plan-no-home@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

-- Homes
INSERT INTO public.homes (id, owner_user_id, is_active, deactivated_at)
VALUES
  ('00000000-0000-4000-8000-000000000a01', '00000000-0000-4000-8000-000000000901', TRUE,  NULL),
  ('00000000-0000-4000-8000-000000000a02', '00000000-0000-4000-8000-000000000902', TRUE,  NULL),
  ('00000000-0000-4000-8000-000000000a03', '00000000-0000-4000-8000-000000000903', TRUE,  NULL),
  ('00000000-0000-4000-8000-000000000a04', '00000000-0000-4000-8000-000000000904', FALSE, now())
ON CONFLICT (id) DO NOTHING;

-- Memberships (current)
INSERT INTO public.memberships (user_id, home_id, role, valid_from)
VALUES
  ('00000000-0000-4000-8000-000000000901', '00000000-0000-4000-8000-000000000a01', 'owner', now()),
  ('00000000-0000-4000-8000-000000000902', '00000000-0000-4000-8000-000000000a02', 'owner', now()),
  ('00000000-0000-4000-8000-000000000903', '00000000-0000-4000-8000-000000000a03', 'owner', now()),
  ('00000000-0000-4000-8000-000000000904', '00000000-0000-4000-8000-000000000a04', 'owner', now())
ON CONFLICT DO NOTHING;

-- Entitlements
INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES
  ('00000000-0000-4000-8000-000000000a01', 'premium', now() + interval '7 days'),
  ('00000000-0000-4000-8000-000000000a03', 'premium', now() - interval '1 day')
ON CONFLICT (home_id) DO UPDATE SET plan = EXCLUDED.plan, expires_at = EXCLUDED.expires_at;

-- Premium plan returned
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000901', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT lives_ok(
  $$ SELECT public.get_plan_status(); $$,
  'get_plan_status succeeds for current member'
);

SELECT is(
  (SELECT public.get_plan_status()->>'plan'),
  'premium',
  'premium home returns premium'
);

SELECT is(
  (SELECT public.get_plan_status()->>'home_id'),
  '00000000-0000-4000-8000-000000000a01',
  'premium response includes home_id'
);

-- Free plan when no entitlement row exists
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000902', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (SELECT public.get_plan_status()->>'plan'),
  'free',
  'missing entitlement defaults to free'
);

-- Expired entitlement falls back to free
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000903', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (SELECT public.get_plan_status()->>'plan'),
  'free',
  'expired entitlement is treated as free'
);

-- Inactive home blocked
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000904', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_ok(
  $$ SELECT public.get_plan_status(); $$,
  'P0004',
  'inactive home is blocked'
);

-- No current home -> error
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000905', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_ok(
  $$ SELECT public.get_plan_status(); $$,
  '42501',
  'users without a current home are blocked'
);

SELECT * FROM finish();
ROLLBACK;
