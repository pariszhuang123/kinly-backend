SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(2);

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

-- Seed minimal data
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000999', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES (
  '00000000-0000-4000-8000-000000000501',
  '00000000-0000-0000-0000-000000000000',
  'paywall-member@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
),
(
  '00000000-0000-4000-8000-000000000502',
  '00000000-0000-0000-0000-000000000000',
  'paywall-nonmember@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
)
ON CONFLICT (id) DO NOTHING;

-- Home + membership for member user
INSERT INTO public.homes (id, owner_user_id)
VALUES ('00000000-0000-4000-8000-000000000601', '00000000-0000-4000-8000-000000000501')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.memberships (user_id, home_id, role, valid_from)
VALUES ('00000000-0000-4000-8000-000000000501', '00000000-0000-4000-8000-000000000601', 'owner', now())
ON CONFLICT DO NOTHING;

INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES ('00000000-0000-4000-8000-000000000601', 'free', NULL)
ON CONFLICT (home_id) DO NOTHING;

-- paywall_log_event works for member
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000501', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT lives_ok(
  $$ SELECT paywall_log_event('00000000-0000-4000-8000-000000000601', 'impression', 'test'); $$,
  'paywall_log_event succeeds for member'
);

SELECT is(
  (SELECT COUNT(*) FROM public.paywall_events WHERE home_id = '00000000-0000-4000-8000-000000000601'),
  1::bigint,
  'paywall_log_event inserted one row'
);

SELECT * FROM finish();
ROLLBACK;
