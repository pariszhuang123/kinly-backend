SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(13);

-- Seed avatars for unique avatar enforcement on join
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-00000000aaaa', 'avatars/default.png', 'animal', 'Default')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-00000000aaab', 'avatars/alt1.png', 'animal', 'Alt1')
ON CONFLICT (id) DO NOTHING;

-- Users
CREATE TEMP TABLE tmp_users (
  label    text PRIMARY KEY,
  user_id  uuid,
  email    text,
  username text
);

INSERT INTO tmp_users (label, user_id, email, username) VALUES
  ('owner',   '00000000-0000-4000-8000-000000000301', 'owner-cap@example.com',  'owner_cap'),
  ('joiner1', '00000000-0000-4000-8000-000000000302', 'joiner1-cap@example.com','joiner_one'),
  ('joiner2', '00000000-0000-4000-8000-000000000303', 'joiner2-cap@example.com','joiner_two');

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

INSERT INTO public.profiles (id, email, full_name, avatar_id, username)
SELECT
  user_id,
  email,
  NULL,
  '00000000-0000-4000-8000-00000000aaaa'::uuid,
  username
FROM tmp_users
ON CONFLICT (id) DO UPDATE
SET username = EXCLUDED.username,
    avatar_id = EXCLUDED.avatar_id,
    email = EXCLUDED.email;

-- Owner creates a home
SELECT set_config('request.jwt.claim.sub',  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

CREATE TEMP TABLE tmp_home_payload AS
SELECT public.homes_create_with_invite() AS payload;

SELECT ok(
  EXISTS (SELECT 1 FROM tmp_home_payload),
  'homes_create_with_invite succeeded'
);

-- Capture home + invite
CREATE TEMP TABLE tmp_home AS
SELECT
  (payload->'home'->>'id')::uuid AS home_id,
  (payload->'invite'->>'code')::text AS invite_code
FROM tmp_home_payload;

-- Set active_members cap to 1 (owner already counts)
UPDATE public.home_plan_limits
   SET max_value = 1
 WHERE plan = 'free'
   AND metric = 'active_members';

-- joiner1 attempts to join -> blocked + enqueued
SELECT set_config('request.jwt.claim.sub',  (SELECT user_id::text FROM tmp_users WHERE label = 'joiner1'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.homes_join((SELECT invite_code FROM tmp_home)) AS body
)
SELECT is(
  (SELECT body->>'code' FROM payload),
  'member_cap',
  'homes_join returns member_cap code when cap exceeded'
);

SELECT is(
  (SELECT COUNT(*)::int FROM public.member_cap_join_requests WHERE home_id = (SELECT home_id FROM tmp_home) AND resolved_at IS NULL),
  1::int,
  'pending request created for joiner1'
);

-- owner sees onboarding payload with live username
SELECT set_config('request.jwt.claim.sub',  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.today_onboarding_hints() AS body
)
SELECT is(
  (SELECT (body->'memberCapJoinRequests'->>'pendingCount')::int FROM payload),
  1::int,
  'owner sees one pending request'
);

WITH payload AS (
  SELECT public.today_onboarding_hints() AS body
)
SELECT ok(
  EXISTS (
    SELECT 1
    FROM payload p
    CROSS JOIN LATERAL jsonb_array_elements_text((p.body->'memberCapJoinRequests'->'joinerNames')::jsonb) AS j(name)
    WHERE j.name = 'joiner_one'
  ),
  'owner sees joiner username in onboarding payload'
);

-- owner dismisses
SELECT public.member_cap_owner_dismiss((SELECT home_id FROM tmp_home));

SELECT is(
  (SELECT COUNT(*)::int FROM public.member_cap_join_requests WHERE home_id = (SELECT home_id FROM tmp_home) AND resolved_at IS NULL),
  0::int,
  'dismiss clears pending requests'
);

-- joiner2 blocked again to set up upgrade flow
SELECT set_config('request.jwt.claim.sub',  (SELECT user_id::text FROM tmp_users WHERE label = 'joiner2'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.homes_join((SELECT invite_code FROM tmp_home)) AS body
)
SELECT is(
  (SELECT body->>'code' FROM payload),
  'member_cap',
  'homes_join returns member_cap for joiner2'
);

-- Upgrade home: attach a subscription and refresh entitlements (postgres role)
INSERT INTO public.user_subscriptions (
  user_id,
  home_id,
  store,
  rc_app_user_id,
  rc_entitlement_id,
  product_id,
  status,
  current_period_end_at
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  (SELECT home_id FROM tmp_home),
  'app_store',
  'rc_user_owner_cap',
  'kinly_premium',
  'com.makinglifeeasie.kinly.premium.monthly',
  'active',
  now() + interval '30 days'
) ON CONFLICT DO NOTHING;

SELECT public.home_entitlements_refresh((SELECT home_id FROM tmp_home));

-- joiner2 should be auto-joined and request resolved
SELECT is(
  (SELECT COUNT(*)::int FROM public.memberships WHERE user_id = (SELECT user_id FROM tmp_users WHERE label = 'joiner2') AND is_current = TRUE),
  1::int,
  'joiner2 membership created after upgrade'
);

SELECT is(
  (SELECT resolved_reason FROM public.member_cap_join_requests WHERE joiner_user_id = (SELECT user_id FROM tmp_users WHERE label = 'joiner2') LIMIT 1),
  'joined',
  'joiner2 pending request resolved as joined'
);

-- owner sees resolution once
SELECT set_config('request.jwt.claim.sub',  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.today_onboarding_hints() AS body
)
SELECT is(
  (SELECT body->'memberCapJoinResolution'->>'resolvedReason' FROM payload),
  'joined',
  'owner sees joiner2 resolution after upgrade'
);

SELECT ok(
  EXISTS (
    SELECT 1
      FROM public.member_cap_join_requests
     WHERE joiner_user_id = (SELECT user_id FROM tmp_users WHERE label = 'joiner2')
       AND resolution_notified_at IS NOT NULL
  ),
  'resolution marked as notified'
);

WITH payload AS (
  SELECT public.today_onboarding_hints() AS body
)
SELECT is(
  (SELECT (body->'memberCapJoinResolution')::text FROM payload),
  'null',
  'resolution only shown once'
);

SELECT is(
  (SELECT resolution_notified_at IS NULL
     FROM public.member_cap_join_requests
    WHERE joiner_user_id = (SELECT user_id FROM tmp_users WHERE label = 'joiner1')
    LIMIT 1),
  true,
  'non-eligible resolution not marked notified'
);

-- Restore cap to default (10) to avoid side-effects on other tests
UPDATE public.home_plan_limits
   SET max_value = 10
 WHERE plan = 'free'
   AND metric = 'active_members';

SELECT * FROM finish();

ROLLBACK;
