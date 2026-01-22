SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(11);

CREATE TEMP TABLE tmp_ids (
  label   text PRIMARY KEY,
  user_id uuid,
  home_id uuid
);

-- Starter avatar required by handle_new_user trigger
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000901', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- User without membership
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES (
  '00000000-0000-4000-8000-000000000701',
  '00000000-0000-0000-0000-000000000000',
  'onboarding-nomem@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
)
ON CONFLICT (id) DO NOTHING;

-- Owner user
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES (
  '00000000-0000-4000-8000-000000000702',
  '00000000-0000-0000-0000-000000000000',
  'onboarding-owner@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
)
ON CONFLICT (id) DO NOTHING;

-- Owner context to create a home
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000702', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_ids (label, user_id, home_id)
SELECT
  'owner',
  '00000000-0000-4000-8000-000000000702',
  (payload->'home'->>'id')::uuid
FROM res;

-- 1) No membership -> all prompts false
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000701', true);
SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptNotifications')::boolean,
  false,
  'No membership returns shouldPromptNotifications=false'
);

-- Switch to owner context for the rest
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000702', true);

-- 2) Zero user-authored chores -> no prompts
SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptNotifications')::boolean,
  false,
  'Zero user-authored chores does not prompt notifications'
);

-- 3) 1 user-authored chore, no prefs -> prompt notifications
SELECT public.chores_create(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_name := 'Chore 1',
  p_assignee_user_id := (SELECT user_id FROM tmp_ids WHERE label = 'owner'),
  p_start_date := current_date
);

-- Simulate runtime fetch creating an unknown/false prefs row (matching RPC defaults)
INSERT INTO public.notification_preferences (
  user_id,
  wants_daily,
  preferred_hour,
  preferred_minute,
  timezone,
  locale,
  os_permission
) VALUES (
  (SELECT user_id FROM tmp_ids WHERE label = 'owner'),
  FALSE,
  9,
  0,
  'UTC',
  'en',
  'unknown'
) ON CONFLICT (user_id) DO NOTHING;

SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptNotifications')::boolean,
  true,
  'User-authored chores >=1 without prefs prompts notifications'
);

-- 4) With prefs, notifications prompt suppressed
SELECT public.notifications_update_preferences(true, 9, 0);
UPDATE public.notification_preferences
SET os_permission = 'allowed'
WHERE user_id = (SELECT user_id FROM tmp_ids WHERE label = 'owner');
SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptNotifications')::boolean,
  false,
  'Existing prefs suppress notification prompt'
);

-- 4b) If prefs exist with os_permission blocked, prompt is suppressed
UPDATE public.notification_preferences
SET os_permission = 'blocked'
WHERE user_id = '00000000-0000-4000-8000-000000000702';
SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptNotifications')::boolean,
  false,
  'Blocked os_permission suppresses notification prompt'
);

-- 5) 2 user-authored chores -> flatmate invite prompt when not shared
SELECT public.chores_create(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_name := 'Chore 2',
  p_assignee_user_id := (SELECT user_id FROM tmp_ids WHERE label = 'owner'),
  p_start_date := current_date
);

SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptFlatmateInviteShare')::boolean,
  true,
  'User-authored chores >=2 with no share triggers flatmate invite prompt'
);

-- Log flatmate invite share
SELECT public.share_log_event(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_feature := 'invite_housemate',
  p_channel := 'copy_link'
);

-- 6) After flatmate share, next ladder prompt only when count high enough
SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptFlatmateInviteShare')::boolean,
  false,
  'Flatmate invite already shared disables that prompt'
);

-- 7) Increase to 5 user-authored chores -> generic invite prompt
SELECT public.chores_create(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_name := 'Chore 3',
  p_assignee_user_id := (SELECT user_id FROM tmp_ids WHERE label = 'owner'),
  p_start_date := current_date
);
SELECT public.chores_create(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_name := 'Chore 4',
  p_assignee_user_id := (SELECT user_id FROM tmp_ids WHERE label = 'owner'),
  p_start_date := current_date
);
SELECT public.chores_create(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_name := 'Chore 5',
  p_assignee_user_id := (SELECT user_id FROM tmp_ids WHERE label = 'owner'),
  p_start_date := current_date
);

SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptInviteShare')::boolean,
  true,
  'User-authored chores >=5 prompts generic invite when earlier steps satisfied'
);

-- Log generic invite share to suppress prompt
SELECT public.share_log_event(
  p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
  p_feature := 'invite_button',
  p_channel := 'system_share'
);

-- 8) Once shared, generic invite prompt clears
SELECT is(
  ((public.today_onboarding_hints())->>'shouldPromptInviteShare')::boolean,
  false,
  'Generic invite share suppresses future prompt'
);

-- 9) onboarding_dismiss share channel accepted
SELECT lives_ok(
  $$
    SELECT public.share_log_event(
      p_home_id := (SELECT home_id FROM tmp_ids WHERE label = 'owner'),
      p_feature := 'invite_button',
      p_channel := 'onboarding_dismiss'
    );
  $$,
  'share_log_event accepts onboarding_dismiss channel'
);

-- 10) Active chore count surface
SELECT is(
  ((public.today_onboarding_hints())->>'userAuthoredChoreCountLifetime')::int,
  5,
  'Lifetime authored chore count reflects user-authored chores'
);

SELECT finish();
ROLLBACK;
