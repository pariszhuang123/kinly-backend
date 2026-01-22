SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(10);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
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

-- 1) No artifacts -> avatar hidden, no path
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT has_preference_report FROM ctx), false, 'no preference report by default');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT has_personal_mentions FROM ctx), false, 'no personal mentions by default');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT show_avatar FROM ctx), false, 'avatar hidden when no artifacts');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is(
  (SELECT avatar_storage_path FROM ctx),
  NULL,
  'avatar path is NULL when avatar hidden'
);

-- Seed a home for FK on personal mentions
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
INSERT INTO tmp_homes (label, home_id)
SELECT 'home', (public.homes_create_with_invite()->'home'->>'id')::uuid;

-- 2) Preference report without a home should count as artifact
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
SELECT is((SELECT has_preference_report FROM ctx), true, 'preference report toggles artifact flag');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT ok((SELECT show_avatar FROM ctx), 'avatar shown when preference report published');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT avatar_storage_path FROM ctx), 'avatars/default_ctx.png', 'avatar path returned when shown');

-- 3) Personal mention should set mention flag
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
SELECT is((SELECT has_personal_mentions FROM ctx), true, 'personal mention toggles mention flag');

-- 4) Personal preference fetch should succeed without home id
SELECT is(
  (public.preference_reports_get_personal_v1('personal_preferences_v1', 'en')->>'found')::boolean,
  true,
  'preference_reports_get_personal_v1 finds published report for caller'
);

-- Sanity check: other user sees no artifacts
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'other'), true);
WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT has_preference_report FROM ctx), false, 'other user has no preference report flagged');

SELECT * FROM finish();
ROLLBACK;
