SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(13);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',     '00000000-0000-4000-8000-000000000211', 'owner-membership@example.com'),
  ('member',    '00000000-0000-4000-8000-000000000212', 'member-membership@example.com'),
  ('outsider',  '00000000-0000-4000-8000-000000000213', 'outsider-membership@example.com');

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE invite_codes (
  label text PRIMARY KEY,
  code  text
);

-- Ensure at least one avatar exists (some views/functions may join on avatars)
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000601', 'avatars/default.png', 'animal', 'Membership Avatar')
ON CONFLICT (id) DO NOTHING;

-- Additional avatars so joins can assign unique per-home avatars
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000602', 'avatars/membership-alt1.png', 'animal', 'Membership Alt 1'),
  ('00000000-0000-4000-8000-000000000603', 'avatars/membership-alt2.png', 'animal', 'Membership Alt 2')
ON CONFLICT (id) DO NOTHING;

-- Seed auth users
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

-- -------------------------------------------------------------------
-- Owner creates the primary home (UPDATED: pass p_name text)
-- -------------------------------------------------------------------
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
SELECT
  'primary',
  (payload->'home'->>'id')::uuid
FROM res;

-- -------------------------------------------------------------------
-- EXTRA TESTS: new home → home_entitlements starts as free
-- -------------------------------------------------------------------
WITH ent AS (
  SELECT plan, expires_at
  FROM public.home_entitlements
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
)
SELECT is(
  (SELECT plan FROM ent),
  'free',
  'newly created home starts with free plan'
);

WITH ent AS (
  SELECT plan, expires_at
  FROM public.home_entitlements
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
)
SELECT ok(
  (SELECT expires_at IS NULL FROM ent),
  'newly created home has NULL expires_at'
);

-- Capture invite code for later join
INSERT INTO invite_codes (label, code)
SELECT 'primary', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
LIMIT 1;

-- -------------------------------------------------------------------
-- Member joins via invite
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- homes.join(code) now returns jsonb, but we only need side-effects
SELECT public.homes_join(
  (SELECT code FROM invite_codes WHERE label = 'primary')
);

-- Reduce the free-plan active_members limit for the next checks (owner + 1 member).
UPDATE public.home_plan_limits
   SET max_value = 2
 WHERE plan = 'free'
   AND metric = 'active_members';

-- -------------------------------------------------------------------
-- membership_me_current returns NULL for outsider
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.membership_me_current() AS body
)
SELECT is(
  (SELECT jsonb_typeof(body->'current') FROM payload),
  'null',
  'membership_me_current returns null for non-members'
);

-- -------------------------------------------------------------------
-- membership_me_current returns joined home for member
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.membership_me_current() AS body
)
SELECT is(
  (SELECT body->'current'->>'home_id' FROM payload),
  (SELECT home_id::text FROM tmp_homes WHERE label = 'primary'),
  'membership_me_current returns active home for member'
);

-- With limit tightened, inviting another member should be blocked by the paywall.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.homes_join(
    (SELECT code FROM invite_codes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT body->>'code' FROM payload),
  'member_cap',
  'free homes cannot exceed the active member cap (blocked, no exception)'
);

-- Restore default limit for other tests.
UPDATE public.home_plan_limits
   SET max_value = 4
 WHERE plan = 'free'
   AND metric = 'active_members';

-- -------------------------------------------------------------------
-- members_list_active_by_home excludes caller by default
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH rows AS (
  SELECT *
  FROM public.members_list_active_by_home(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  )
)
SELECT is(
  (SELECT count(*)::integer FROM rows),
  1::integer,
  'members_list_active_by_home excludes caller when p_exclude_self=TRUE'
);

-- -------------------------------------------------------------------
-- members_list_active_by_home includes caller and exposes transfer flags
-- -------------------------------------------------------------------
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH rows AS (
  SELECT *
  FROM public.members_list_active_by_home(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    false
  )
)
SELECT is(
  (SELECT count(*)::integer FROM rows),
  2::integer,
  'members_list_active_by_home includes caller when p_exclude_self=false'
);

-- non-owner can be transfer target
WITH rows AS (
  SELECT *
  FROM public.members_list_active_by_home(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    false
  )
)
SELECT ok(
  EXISTS (
    SELECT 1 FROM rows
    WHERE user_id = (SELECT user_id FROM tmp_users WHERE label = 'member')
      AND can_transfer_to = TRUE
  ),
  'non-owner members are valid transfer targets'
);

-- owner cannot be transfer target
WITH rows AS (
  SELECT *
  FROM public.members_list_active_by_home(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    false
  )
)
SELECT ok(
  EXISTS (
    SELECT 1 FROM rows
    WHERE user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner')
      AND can_transfer_to = FALSE
  ),
  'owner is not a transfer target'
);

-- -------------------------------------------------------------------
-- Constraint: user may not hold two current memberships simultaneously
-- -------------------------------------------------------------------
SELECT throws_like(
  $$
    INSERT INTO public.memberships (user_id, home_id, role)
    VALUES (
      (SELECT user_id FROM tmp_users WHERE label = 'owner'),
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'member'
    );
  $$,
  '%uq_memberships_user_one_current%',
  'unique current membership constraint enforced'
);

-- -------------------------------------------------------------------
-- Constraint: only one current owner per home
-- -------------------------------------------------------------------
SELECT throws_like(
  $$
    INSERT INTO public.memberships (user_id, home_id, role)
    VALUES (
      (SELECT user_id FROM tmp_users WHERE label = 'outsider'),
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'owner'
    );
  $$,
  '%uq_memberships_home_one_current_owner%',
  'unique current owner constraint enforced'
);

-- -------------------------------------------------------------------
-- Historical stint insert succeeds when non-overlapping
-- -------------------------------------------------------------------
SELECT lives_ok(
  $$
    INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
    VALUES (
      (SELECT user_id FROM tmp_users WHERE label = 'outsider'),
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'member',
      now() - interval '30 days',
      now() - interval '20 days'
    );
  $$,
  'non-overlapping historical stint is allowed'
);

-- -------------------------------------------------------------------
-- Overlapping historical stint is rejected
-- -------------------------------------------------------------------
SELECT throws_like(
  $$
    INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
    VALUES (
      (SELECT user_id FROM tmp_users WHERE label = 'outsider'),
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'member',
      now() - interval '25 days',
      now() - interval '15 days'
    );
  $$,
  '%no_overlap_per_user_home%',
  'overlapping stints on same home are prevented'
);

SELECT * FROM finish();
ROLLBACK;
