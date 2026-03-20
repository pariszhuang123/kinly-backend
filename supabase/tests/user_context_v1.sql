SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(16);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000801', 'avatars/default_ctx.png', 'animal', 'Ctx Avatar')
ON CONFLICT (id) DO NOTHING;

-- Seed auth users
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000000501', '00000000-0000-0000-0000-000000000000', 'ctx-owner@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000502', '00000000-0000-0000-0000-000000000000', 'ctx-other@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner', '00000000-0000-4000-8000-000000000501', 'ctx-owner@example.com'),
  ('other', '00000000-0000-4000-8000-000000000502', 'ctx-other@example.com');

INSERT INTO public.profiles (id, username, avatar_id, created_at, updated_at)
VALUES
  ('00000000-0000-4000-8000-000000000501', 'ctx_owner', '00000000-0000-4000-8000-000000000801', now(), now()),
  ('00000000-0000-4000-8000-000000000502', 'ctx_other', '00000000-0000-4000-8000-000000000801', now(), now())
ON CONFLICT (id) DO NOTHING;

-- 1) No artifacts -> no avatar and no personal-directory content
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_preference_report')::boolean, false, 'no preference report by default');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_personal_mentions')::boolean, false, 'no personal mentions by default');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_personal_directory_content')::boolean, false, 'personal directory flag is false by default');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT user_context_v1->>'avatar_storage_path' FROM ctx), NULL, 'avatar path is NULL when the caller has no personal artifacts');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT user_context_v1->>'display_name' FROM ctx), 'ctx_owner', 'display_name mirrors profiles.username');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT (user_context_v1->>'user_id')::uuid FROM ctx), (SELECT user_id FROM tmp_users WHERE label = 'owner'), 'user_id matches auth.uid()');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'show_avatar')::boolean, false, 'show_avatar is false when all artifact flags are false');

-- Seed a home for FK on personal mentions
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
CREATE TEMP TABLE tmp_homes AS
SELECT 'home'::text AS label, (public.homes_create_with_invite()->'home'->>'id')::uuid AS home_id;

-- 2) Preference report should count as artifact
INSERT INTO public.preference_reports (
  subject_user_id,
  template_key,
  locale,
  generated_content,
  published_content
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  'personal_preferences_v1',
  'en',
  '{}'::jsonb,
  '{"sections":[],"summary":{"title":"t","subtitle":"s"}}'::jsonb
) ON CONFLICT DO NOTHING;

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_preference_report')::boolean, true, 'preference report toggles artifact flag');

-- 3) Personal-directory bank account should set directory-content flag
INSERT INTO public.member_directory_bank_accounts (
  user_id,
  account_holder_name,
  account_number
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  'Ctx Owner',
  '12-3456-7890123-00'
)
ON CONFLICT (user_id) DO NOTHING;

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_personal_directory_content')::boolean, true, 'bank account toggles personal directory content flag');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT user_context_v1->>'avatar_storage_path' FROM ctx), 'avatars/default_ctx.png', 'avatar path is returned when personal directory content exists');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'show_avatar')::boolean, true, 'show_avatar is true when any artifact exists');

-- 4) Personal mention should set mention flag
-- Seed a mood entry to satisfy source_entry_id FK
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'other'), true);
INSERT INTO public.home_mood_entries (
  id,
  home_id,
  user_id,
  mood,
  created_at,
  iso_week_year,
  iso_week
) VALUES (
  '00000000-0000-4000-8000-000000000e01',
  (SELECT home_id FROM tmp_homes WHERE label = 'home'),
  (SELECT user_id FROM tmp_users WHERE label = 'other'),
  'sunny',
  now(),
  date_part('isoyear', now())::int,
  date_part('week', now())::int
)
ON CONFLICT (id) DO NOTHING;

-- Insert personal mention anchored to the entry
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
INSERT INTO public.gratitude_wall_personal_items (
  recipient_user_id,
  home_id,
  author_user_id,
  mood,
  message,
  source_kind,
  source_entry_id,
  created_at
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  (SELECT home_id FROM tmp_homes WHERE label = 'home'),
  (SELECT user_id FROM tmp_users WHERE label = 'other'),
  'sunny',
  'thank you',
  'mention_only',
  '00000000-0000-4000-8000-000000000e01',
  now()
);

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_personal_mentions')::boolean, true, 'personal mention toggles mention flag');

-- 5) Personal preference fetch should succeed without home id
SELECT is(
  (public.preference_reports_get_personal_v1('personal_preferences_v1', 'en')->>'found')::boolean,
  true,
  'preference_reports_get_personal_v1 finds published report for caller'
);

-- Sanity check: other user sees no artifacts
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'other'), true);
WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_preference_report')::boolean, false, 'other user has no preference report flagged');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(((SELECT user_context_v1 FROM ctx)->>'has_personal_directory_content')::boolean, false, 'other user has no personal directory content flagged');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT user_context_v1->>'avatar_storage_path' FROM ctx), NULL, 'other user has no avatar path when no artifacts exist');

SELECT * FROM finish();
ROLLBACK;
