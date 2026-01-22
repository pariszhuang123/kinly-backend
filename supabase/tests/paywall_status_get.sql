SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(6);

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

-- Seed default avatar required by handle_new_user()
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000999', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- Seed users
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000000801', '00000000-0000-0000-0000-000000000000', 'paywall-status-member@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000802', '00000000-0000-0000-0000-000000000000', 'paywall-status-nonmember@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000803', '00000000-0000-0000-0000-000000000000', 'paywall-status-member-2@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

-- Home + membership
INSERT INTO public.homes (id, owner_user_id)
VALUES ('00000000-0000-4000-8000-000000000901', '00000000-0000-4000-8000-000000000801')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.memberships (user_id, home_id, role, valid_from)
VALUES ('00000000-0000-4000-8000-000000000801', '00000000-0000-4000-8000-000000000901', 'owner', now())
ON CONFLICT DO NOTHING;

-- Entitlements + usage for this home
INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES ('00000000-0000-4000-8000-000000000901', 'premium', now() + interval '30 days')
ON CONFLICT (home_id) DO UPDATE SET plan = EXCLUDED.plan, expires_at = EXCLUDED.expires_at;

INSERT INTO public.home_usage_counters (home_id, active_chores, chore_photos, active_members, active_expenses, updated_at)
VALUES ('00000000-0000-4000-8000-000000000901', 2, 3, 4, 1, now())
ON CONFLICT (home_id) DO UPDATE
SET active_chores = EXCLUDED.active_chores,
    chore_photos = EXCLUDED.chore_photos,
    active_members = EXCLUDED.active_members,
    active_expenses = EXCLUDED.active_expenses,
    updated_at = EXCLUDED.updated_at;

-- Member can fetch status
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000801', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT lives_ok(
  $$ SELECT public.paywall_status_get('00000000-0000-4000-8000-000000000901'); $$,
  'paywall_status_get succeeds for member'
);

SELECT is(
  (SELECT (public.paywall_status_get('00000000-0000-4000-8000-000000000901')->>'plan')),
  'premium',
  'paywall_status_get returns plan'
);

SELECT is(
  (SELECT (public.paywall_status_get('00000000-0000-4000-8000-000000000901')->>'is_premium')::boolean),
  true,
  'paywall_status_get flags premium'
);

SELECT is(
  (SELECT (public.paywall_status_get('00000000-0000-4000-8000-000000000901')->'usage'->>'active_chores')::int),
  2,
  'paywall_status_get returns usage'
);

-- Non-member blocked
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000802', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.paywall_status_get('00000000-0000-4000-8000-000000000901'); $$,
  'NOT_HOME_MEMBER',
  'non-members cannot fetch paywall status'
);

-- Missing counters returns defaults and free plan
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000803', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

INSERT INTO public.homes (id, owner_user_id)
VALUES ('00000000-0000-4000-8000-000000000902', '00000000-0000-4000-8000-000000000803')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.memberships (user_id, home_id, role, valid_from)
VALUES ('00000000-0000-4000-8000-000000000803', '00000000-0000-4000-8000-000000000902', 'owner', now())
ON CONFLICT DO NOTHING;

INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES ('00000000-0000-4000-8000-000000000902', 'free', NULL)
ON CONFLICT (home_id) DO UPDATE SET plan = EXCLUDED.plan, expires_at = EXCLUDED.expires_at;

SELECT is(
  (SELECT (public.paywall_status_get('00000000-0000-4000-8000-000000000902')->>'plan')),
  'free',
  'missing entitlement defaults to free'
);

SELECT * FROM finish();
ROLLBACK;
