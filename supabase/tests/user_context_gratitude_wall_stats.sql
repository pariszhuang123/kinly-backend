SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(9);

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
  ('00000000-0000-4000-8000-000000000901', 'avatars/ctx_default.png', 'animal', 'Ctx Avatar'),
  ('00000000-0000-4000-8000-000000000902', 'avatars/ctx_alt.png', 'animal', 'Ctx Avatar Alt')
ON CONFLICT (id) DO NOTHING;

-- Seed auth users
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000000511', '00000000-0000-0000-0000-000000000000', 'ctx-owner@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000512', '00000000-0000-0000-0000-000000000000', 'ctx-member@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000511', 'ctx-owner@example.com'),
  ('member', '00000000-0000-4000-8000-000000000512', 'ctx-member@example.com');

-- Profiles
INSERT INTO public.profiles (id, username, avatar_id, created_at, updated_at)
VALUES
  ('00000000-0000-4000-8000-000000000511', 'ctx_owner', '00000000-0000-4000-8000-000000000901', now(), now()),
  ('00000000-0000-4000-8000-000000000512', 'ctx_member', '00000000-0000-4000-8000-000000000902', now(), now())
ON CONFLICT (id) DO NOTHING;

-- Seed a home + invite upfront for mentions/stats
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
WITH new_home AS (
  SELECT (public.homes_create_with_invite()->'home'->>'id')::uuid AS home_id
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'home', home_id FROM new_home;

-- 1) No artifacts -> no avatar
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT show_avatar FROM ctx), false, 'show_avatar is false with no artifacts');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT avatar_storage_path FROM ctx), NULL, 'avatar path is NULL when avatar not shown');

-- 2) Preference report published -> avatar visible, path present
INSERT INTO public.preference_reports (
  subject_user_id,
  template_key,
  locale,
  generated_content,
  published_content,
  status,
  published_at
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  'personal_preferences_v1',
  'en',
  '{}'::jsonb,
  '{"summary":{"title":"t","subtitle":"s"},"sections":[]}'::jsonb,
  'published',
  now()
) ON CONFLICT DO NOTHING;

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT has_preference_report FROM ctx), true, 'has_preference_report flips to true');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT ok((SELECT show_avatar FROM ctx), 'show_avatar true when preference report exists');

WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT avatar_storage_path FROM ctx), 'avatars/ctx_default.png', 'avatar path returned when avatar shown');

-- 3) Member joins, seeds a mood entry, and mention toggles mention flag
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT public.homes_join(
  (SELECT code FROM public.invites WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'home') AND revoked_at IS NULL LIMIT 1)
);

INSERT INTO public.home_mood_entries (
  id,
  home_id,
  user_id,
  mood,
  created_at,
  iso_week_year,
  iso_week
) VALUES (
  '00000000-0000-4000-8000-000000000e02',
  (SELECT home_id FROM tmp_homes WHERE label = 'home'),
  (SELECT user_id FROM tmp_users WHERE label = 'member'),
  'sunny',
  now(),
  date_part('isoyear', now())::int,
  date_part('week', now())::int
) ON CONFLICT (id) DO NOTHING;

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
  (SELECT user_id FROM tmp_users WHERE label = 'member'),
  'sunny',
  'Thanks!',
  'mention_only',
  '00000000-0000-4000-8000-000000000e02',
  now()
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
WITH ctx AS (SELECT * FROM public.user_context_v1())
SELECT is((SELECT has_personal_mentions FROM ctx), true, 'has_personal_mentions is true after a mention');

-- 4) gratitude_wall_stats aggregates

-- Posts
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
INSERT INTO public.gratitude_wall_posts (home_id, author_user_id, mood, message, created_at)
VALUES
  ((SELECT home_id FROM tmp_homes WHERE label = 'home'),
   (SELECT user_id FROM tmp_users WHERE label = 'owner'),
   'sunny',
   'Old gratitude',
   now() - interval '2 days'),
  ((SELECT home_id FROM tmp_homes WHERE label = 'home'),
   (SELECT user_id FROM tmp_users WHERE label = 'member'),
   'partially_sunny',
   'New gratitude',
   now() - interval '6 hours');

-- Mark owner read yesterday so only the recent post is unread
INSERT INTO public.gratitude_wall_reads (home_id, user_id, last_read_at)
VALUES (
  (SELECT home_id FROM tmp_homes WHERE label = 'home'),
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  now() - interval '1 day'
)
ON CONFLICT (home_id, user_id) DO UPDATE
SET last_read_at = EXCLUDED.last_read_at;

WITH stats AS (
  SELECT * FROM public.gratitude_wall_stats((SELECT home_id FROM tmp_homes WHERE label = 'home'))
)
SELECT is((SELECT total_posts FROM stats), 2, 'total_posts counts all posts');

WITH stats AS (
  SELECT * FROM public.gratitude_wall_stats((SELECT home_id FROM tmp_homes WHERE label = 'home'))
)
SELECT is((SELECT unread_count FROM stats), 1, 'unread_count respects last_read_at');

WITH stats AS (
  SELECT * FROM public.gratitude_wall_stats((SELECT home_id FROM tmp_homes WHERE label = 'home'))
)
SELECT ok((SELECT last_read_at FROM stats) IS NOT NULL, 'last_read_at echoed from reads');

SELECT * FROM finish();
ROLLBACK;
