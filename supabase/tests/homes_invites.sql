SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(25);

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

-- Basic sanity for invite code generator
SELECT is(
  char_length(public._gen_invite_code()::text),
  6,
  '_gen_invite_code returns 6 characters'
);

SELECT ok(
  public._gen_invite_code()::text ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$',
  '_gen_invite_code uses Crockford alphabet without confusing chars'
);

-- Starter avatar required by handle_new_user trigger
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000501', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- Additional avatars to allow unique assignment per home
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000502', 'avatars/alt-1.png', 'animal', 'Alt Avatar 1'),
  ('00000000-0000-4000-8000-000000000503', 'avatars/alt-2.png', 'animal', 'Alt Avatar 2')
ON CONFLICT (id) DO NOTHING;

-- Seed logical users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',        '00000000-0000-4000-8000-000000000111', 'owner-test@example.com'),
  ('member_one',   '00000000-0000-4000-8000-000000000112', 'member1-test@example.com'),
  ('member_two',   '00000000-0000-4000-8000-000000000113', 'member2-test@example.com'),
  ('deactivated',  '00000000-0000-4000-8000-000000000114', 'deactivated-test@example.com');

-- Seed auth users (profiles auto-created via trigger)
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

-- Owner creates a home with invite
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

SELECT ok(
  (SELECT COUNT(*) FROM tmp_homes WHERE label = 'primary' AND home_id IS NOT NULL) = 1,
  'homes_create_with_invite returns a home id'
);

SELECT is(
  (SELECT owner_user_id::text FROM public.homes WHERE id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  'home owner is recorded correctly'
);

-- New home starts with a free entitlement row
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.home_entitlements he
    WHERE he.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND he.plan = 'free'
      AND he.expires_at IS NULL
  ),
  'home_entitlements row created with free plan on home creation'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.memberships
     WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner')
       AND role = 'owner'
       AND is_current
  ),
  'owner membership stint is created as current'
);

-- Capture initial invite code
INSERT INTO invite_codes (label, code)
SELECT 'initial', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
LIMIT 1;

-- Owner rotates invite (allowed)
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.invites_rotate((SELECT home_id FROM tmp_homes WHERE label = 'primary'));

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.invites
     WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND code = (SELECT code FROM invite_codes WHERE label = 'initial')::citext
       AND revoked_at IS NOT NULL
  ),
  'rotated invite code is revoked'
);

INSERT INTO invite_codes (label, code)
SELECT 'active_after_rotate', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
ORDER BY created_at DESC
LIMIT 1;

SELECT isnt(
  (SELECT code FROM invite_codes WHERE label = 'active_after_rotate'),
  (SELECT code FROM invite_codes WHERE label = 'initial'),
  'invite rotation issues a new code'
);

-- Non-owner cannot rotate invites (expect FORBIDDEN)
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  $$ SELECT public.invites_rotate((SELECT home_id FROM tmp_homes WHERE label = 'primary')); $$,
  '%FORBIDDEN%',
  'non-owner cannot rotate invites'
);

-- Member joins via active invite
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_join(
  (SELECT code FROM invite_codes WHERE label = 'active_after_rotate')
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.memberships
     WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')
       AND role = 'member'
       AND is_current
  ),
  'member joins home via invite code'
);

-- NOW: owner should not be allowed to leave while another member is current
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  $$ SELECT public.homes_leave((SELECT home_id FROM tmp_homes WHERE label = 'primary')); $$,
  '%OWNER_MUST_TRANSFER_FIRST%',
  'owner must transfer ownership before leaving'
);

-- Back to member_one context
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (SELECT used_count FROM public.invites
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND revoked_at IS NULL
    ORDER BY created_at DESC
    LIMIT 1
  ),
  1,
  'joining increments invite used_count'
);

WITH payload AS (
  SELECT public.membership_me_current() AS body
)
SELECT is(
  (SELECT body->'current'->>'home_id' FROM payload),
  (SELECT home_id::text FROM tmp_homes WHERE label = 'primary'),
  'membership_me_current reports the joined home'
);

-- Transfer ownership from original owner to member_one
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_transfer_owner(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  (SELECT user_id FROM tmp_users WHERE label = 'member_one')
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.memberships
     WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')
       AND role = 'owner'
       AND is_current
  ),
  'transfer promotes member_one to owner'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.memberships
     WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner')
       AND role = 'member'
       AND is_current
  ),
  'transfer demotes original owner to member'
);

-- New owner revokes invites
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.invites_revoke(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary')
);

-- Second revoke returns no_active_invite info
WITH revoke_payload AS (
  SELECT public.invites_revoke((SELECT home_id FROM tmp_homes WHERE label = 'primary')) AS payload
)
SELECT is(
  (SELECT payload->>'code' FROM revoke_payload),
  'no_active_invite',
  'second invites_revoke returns no_active_invite when nothing to revoke'
);

SELECT is(
  (SELECT COUNT(*)::integer FROM public.invites
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND revoked_at IS NULL),
  0::integer,
  'invites_revoke clears active invites'
);

-- Rotate again for later tests (by new owner, allowed)
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.invites_rotate(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary')
);

INSERT INTO invite_codes (label, code)
SELECT 'post_transfer', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
ORDER BY created_at DESC
LIMIT 1;

SELECT ok(
  (SELECT code FROM invite_codes WHERE label = 'post_transfer') IS NOT NULL,
  'new invite code created after rotation by new owner'
);

-- Deactivated profile cannot create or join homes
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'deactivated'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

UPDATE public.profiles
SET deactivated_at = now()
WHERE id = (SELECT user_id FROM tmp_users WHERE label = 'deactivated');

SELECT throws_like(
  $$ SELECT public.homes_create_with_invite(); $$,
  '%PROFILE_DEACTIVATED%',
  'deactivated profile cannot create a home'
);

SELECT throws_like(
  $$ SELECT public.homes_join((SELECT code FROM invite_codes WHERE label = 'post_transfer')); $$,
  '%PROFILE_DEACTIVATED%',
  'deactivated profile cannot join a home'
);

-- Original owner (now member) can leave successfully
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_leave(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary')
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.memberships
     WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner')
       AND is_current
  ),
  'member leave clears current membership'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.membership_me_current() AS body
)
SELECT is(
  (SELECT jsonb_typeof(body->'current') FROM payload),
  'null',
  'membership_me_current is null after leaving the home'
);

-- New owner leaves last, deactivating the home
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_leave(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary')
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.homes
     WHERE id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
       AND is_active = FALSE
       AND deactivated_at IS NOT NULL
  ),
  'home is deactivated when the last member leaves'
);

-- Joining an inactive home fails even with a saved code
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_two'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  $$ SELECT public.homes_join((SELECT code FROM invite_codes WHERE label = 'post_transfer')); $$,
  '%INACTIVE_INVITE%',
  'inactive home blocks new joins'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.membership_me_current() AS body
)
SELECT is(
  (SELECT jsonb_typeof(body->'current') FROM payload),
  'null',
  'membership_me_current is null for former owner after leaving'
);

SELECT * FROM finish();
ROLLBACK;
