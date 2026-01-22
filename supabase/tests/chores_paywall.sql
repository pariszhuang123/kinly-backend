SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(9);

CREATE TEMP TABLE tmp_ids (
  user_id uuid,
  home_id uuid,
  avatar_id uuid
);

INSERT INTO tmp_ids VALUES (
  '00000000-0000-4000-8000-000000000101'::uuid,
  '00000000-0000-4000-8000-000000000201'::uuid,
  '00000000-0000-4000-8000-000000000301'::uuid
);

CREATE TEMP TABLE chore_ids (
  label text PRIMARY KEY,
  chore_id uuid
);

-- Seed an avatar so handle_new_user trigger has a valid FK target
INSERT INTO public.avatars (id, storage_path, category, name)
SELECT avatar_id, 'avatars/default.png', 'animal', 'Test Avatar'
FROM tmp_ids
ON CONFLICT (id) DO NOTHING;

-- Create auth user + profile (trigger runs automatically)
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'chore-test@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
FROM tmp_ids;

-- Home + membership owned by the same user
INSERT INTO public.homes (id, owner_user_id)
SELECT home_id, user_id FROM tmp_ids;

INSERT INTO public.memberships (user_id, home_id, role)
SELECT user_id, home_id, 'owner' FROM tmp_ids;

-- Mark this home as a free plan so paywall applies
INSERT INTO public.home_entitlements (home_id, plan, expires_at)
SELECT home_id, 'free', NULL
FROM tmp_ids
ON CONFLICT (home_id) DO NOTHING;

-- Simulate authenticated context for RLS + auth.uid()
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_ids),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- 1️⃣ Initial counters
SELECT is(
  COALESCE((
    SELECT active_chores
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  0,
  'initial active chore counter starts at 0'
);

-- 2️⃣ Create first chore (no photo)
WITH res AS (
  SELECT public.chores_create(
    p_home_id                := (SELECT home_id FROM tmp_ids),
    p_name                   := 'First chore',
    p_assignee_user_id       := NULL,
    p_start_date             := current_date,
    p_recurrence             := 'none'::public.recurrence_interval,
    p_how_to_video_url       := NULL,
    p_notes                  := NULL,
    p_expectation_photo_path := NULL
  ) AS chore
)
INSERT INTO chore_ids (label, chore_id)
SELECT 'first', (chore).id
FROM res;

SELECT is(
  COALESCE((
    SELECT active_chores
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  1,
  'active counter increments after create'
);

-- 3️⃣ Add expectation photo to first chore (first photo → +1)
-- 3️⃣ Add expectation photo to first chore (first photo → +1)
SELECT public.chores_update(
  p_chore_id               := (SELECT chore_id FROM chore_ids WHERE label = 'first'),
  p_name                   := 'First chore',
  p_assignee_user_id       := (SELECT user_id FROM tmp_ids),
  p_start_date             := current_date,
  p_recurrence             := 'none',
  p_expectation_photo_path := 'flow/expectations/'
      || (SELECT home_id::text FROM tmp_ids)
      || '/chores/'
    || (SELECT chore_id::text FROM chore_ids WHERE label = 'first'),
  p_how_to_video_url       := NULL,
  p_notes                  := NULL
);

SELECT is(
  COALESCE((
    SELECT chore_photos
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  1,
  'photo counter increments after adding first expectation photo'
);

-- 4️⃣ Replace expectation photo (non-NULL → non-NULL, no counter change)
-- 4️⃣ Replace expectation photo (non-NULL → non-NULL, no counter change)
SELECT public.chores_update(
  p_chore_id               := (SELECT chore_id FROM chore_ids WHERE label = 'first'),
  p_name                   := 'First chore updated photo',
  p_assignee_user_id       := (SELECT user_id FROM tmp_ids),
  p_start_date             := current_date,
  p_recurrence             := 'none',
  p_expectation_photo_path := 'flow/expectations/'
      || (SELECT home_id::text FROM tmp_ids)
      || '/chores/'
    || (SELECT chore_id::text FROM chore_ids WHERE label = 'first')
    || '/replacement.jpg',
  p_how_to_video_url       := NULL,
  p_notes                  := NULL
);

SELECT is(
  COALESCE((
    SELECT chore_photos
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  1,
  'replacing an existing expectation photo does not change photo counter'
);

-- 6️⃣ Cancel first chore => remove from active count
SELECT public.chores_cancel(
  (SELECT chore_id FROM chore_ids WHERE label = 'first')
);

SELECT is(
  COALESCE((
    SELECT active_chores
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  0,
  'active counter decrements after cancel'
);

-- 7️⃣ Create second chore (no photo) and complete it (one-off)
WITH res AS (
  SELECT public.chores_create(
    p_home_id                := (SELECT home_id FROM tmp_ids),
    p_name                   := 'Second chore',
    p_assignee_user_id       := (SELECT user_id FROM tmp_ids),  -- 👈 assign to test user
    p_start_date             := current_date,
    p_recurrence             := 'none'::public.recurrence_interval,
    p_how_to_video_url       := NULL,
    p_notes                  := NULL,
    p_expectation_photo_path := NULL
  ) AS chore
)
INSERT INTO chore_ids (label, chore_id)
SELECT 'second', (chore).id
FROM res;

SELECT is(
  COALESCE((
    SELECT active_chores
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  1,
  'active counter increments for second chore'
);

-- 1) Ensure we are acting as the test user (the assignee)
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_ids),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- 2) Now complete the chore as the correct assignee
SELECT public.chore_complete(
  (SELECT chore_id FROM chore_ids WHERE label = 'second')
);

-- 3) Assert the counter
SELECT is(
  COALESCE((
    SELECT active_chores
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_ids)
  ), 0),
  0,
  'active counter decrements after one-off completion'
);

-- 8️⃣ Create third chore (used for paywall save test)
WITH res AS (
  SELECT public.chores_create(
    p_home_id                := (SELECT home_id FROM tmp_ids),
    p_name                   := 'Third chore',
    p_assignee_user_id       := NULL,
    p_start_date             := current_date,
    p_recurrence             := 'none'::public.recurrence_interval,
    p_how_to_video_url       := NULL,
    p_notes                  := NULL,
    p_expectation_photo_path := NULL
  ) AS chore
)
INSERT INTO chore_ids (label, chore_id)
SELECT 'third', (chore).id
FROM res;

-- 9️⃣ Simulate nearing the active chore limit (set to 20) and ensure create fails
SELECT public._home_usage_apply_delta(
  (SELECT home_id FROM tmp_ids),
  jsonb_build_object('active_chores', 19) -- current active=1 -> push to 20
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_ids),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  $$
    SELECT public.chores_create(
      p_home_id                := (SELECT home_id FROM tmp_ids),
      p_name                   := 'Overflow chore',
      p_assignee_user_id       := NULL,
      p_start_date             := current_date,
      p_recurrence             := 'none'::public.recurrence_interval,
      p_how_to_video_url       := NULL,
      p_notes                  := NULL,
      p_expectation_photo_path := NULL
    );
  $$,
  '%PAYWALL_LIMIT_ACTIVE_CHORES%',
  'paywall blocks creation when active counter exceeds 20'
);

-- 🔟 Reset active count back down
SELECT public._home_usage_apply_delta(
  (SELECT home_id FROM tmp_ids),
  jsonb_build_object('active_chores', -19)
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_ids),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- 1️⃣1 Simulate photo cap (set cached count to 15) and ensure save fails when adding new photo
SELECT public._home_usage_apply_delta(
  (SELECT home_id FROM tmp_ids),
  jsonb_build_object(
    'chore_photos',
    15 - COALESCE((
      SELECT chore_photos
      FROM public.home_usage_counters
      WHERE home_id = (SELECT home_id FROM tmp_ids)
    ), 0)
  )
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_ids),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  $$
    SELECT public.chores_update(
      p_chore_id               := (SELECT chore_id FROM chore_ids WHERE label = 'third'),
      p_name                   := 'Third chore',
      p_assignee_user_id       := (SELECT user_id FROM tmp_ids),
      p_start_date             := current_date,
      p_recurrence             := 'none',
      p_expectation_photo_path := 'flow/expectations/'
          || (SELECT home_id::text FROM tmp_ids)
          || '/chores/'
        || (SELECT chore_id::text FROM chore_ids WHERE label = 'third'),
      p_how_to_video_url       := NULL,
      p_notes                  := NULL
    );
  $$,
  '%PAYWALL_LIMIT_CHORE_PHOTOS%',
  'paywall blocks adding a 16th expectation photo'
);

SELECT * FROM finish();
ROLLBACK;
