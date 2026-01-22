-- =====================================================================
--  Gratitude Mentions v2 (FULL, ADJUSTED) — Split publish pathways + RPC-only
--
--  Final decisions applied (per latest):
--   - Split (B): mood_submit_v2 ONLY creates weekly entry and returns { entry_id }
--   - Publish later via RPCs (public wall post, private inbox, mentions, etc.)
--   - Reintroduce idempotency anchor on gratitude_wall_posts: source_entry_id
--       * Backfill from legacy home_mood_entries.gratitude_post_id
--       * Enforce 1 post per entry via PARTIAL UNIQUE INDEX
--   - DO NOT drop home_mood_entries.gratitude_post_id yet (legacy RPCs still use it)
--   - No direct table reads from clients:
--       * RLS enabled
--       * NO policies
--       * REVOKE ALL on tables from anon/authenticated
--       * Access ONLY via SECURITY DEFINER RPCs
--       * DB owner/postgres can still view via Studio UI
--   - Remove citext extension from this script (your DB already uses it via profiles)
--   - Rename message_snapshot -> message (personal items)
--   - First publish wins (idempotent inserts; no “upgrade” of personal items later)
--   - home_id drift in mentions is acceptable by design (capturing original context)
--   - Weekly entries are immutable / append-only (no deletes expected)
--   - Remove redundant idx_home_mood_entries_user_week (unique constraint already indexes it)
--   - Make advisory lock “boring” (two-key lock to reduce collision risk)
--   - Add posts index for home wall status hot-path
--   - Enforce pagination cursor: both-or-neither (p_before_at + p_before_id)
--
--  NOTE:
--   - Assumes you already have helper functions:
--       public._assert_authenticated()
--       public._assert_home_member(uuid)
--       public._assert_home_active(uuid)
--       public.api_assert(boolean, text, text, text, jsonb default null)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 1) Anchor on gratitude_wall_posts (source_entry_id) + backfill
-- ---------------------------------------------------------------------

ALTER TABLE public.gratitude_wall_posts
  ADD COLUMN IF NOT EXISTS source_entry_id uuid NULL
    REFERENCES public.home_mood_entries(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.gratitude_wall_posts.source_entry_id IS
  'Origin weekly entry (home_mood_entries.id) that produced this post. Nullable for legacy/manual posts.';

-- Backfill anchor using legacy link home_mood_entries.gratitude_post_id (safe to re-run)
UPDATE public.gratitude_wall_posts p
SET source_entry_id = e.id
FROM public.home_mood_entries e
WHERE e.gratitude_post_id = p.id
  AND p.source_entry_id IS NULL;

-- Enforce: at most one post per entry when anchored (NULLs allowed)
CREATE UNIQUE INDEX IF NOT EXISTS uq_gratitude_wall_posts_source_entry_id
ON public.gratitude_wall_posts (source_entry_id)
WHERE source_entry_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_gratitude_wall_posts_source_entry_id
ON public.gratitude_wall_posts (source_entry_id)
WHERE source_entry_id IS NOT NULL;

-- NEW: hot-path for home wall status query
CREATE INDEX IF NOT EXISTS idx_gratitude_wall_posts_home_created_desc
ON public.gratitude_wall_posts (home_id, created_at DESC, id DESC);

-- ---------------------------------------------------------------------
-- 2) Mentions + Personal wall tables (stable IDs only)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.gratitude_wall_mentions (
  post_id           uuid NOT NULL REFERENCES public.gratitude_wall_posts(id) ON DELETE CASCADE,
  home_id           uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  mentioned_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_gratitude_wall_mentions PRIMARY KEY (post_id, mentioned_user_id)
);

COMMENT ON TABLE public.gratitude_wall_mentions IS
  'Mention edges for home gratitude wall posts. Display fields resolved at read time from profiles. home_id is stored as original context.';

CREATE INDEX IF NOT EXISTS idx_gratitude_wall_mentions_home_post
  ON public.gratitude_wall_mentions (home_id, post_id);

CREATE INDEX IF NOT EXISTS idx_gratitude_wall_mentions_user_created_desc
  ON public.gratitude_wall_mentions (mentioned_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.gratitude_wall_personal_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  home_id           uuid NOT NULL REFERENCES public.homes(id) ON DELETE RESTRICT,
  author_user_id    uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  mood              public.mood_scale NOT NULL,
  message           text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  source_kind       text NOT NULL CHECK (source_kind IN ('home_post','mention_only')),
  source_post_id    uuid NULL REFERENCES public.gratitude_wall_posts(id) ON DELETE RESTRICT,
  source_entry_id   uuid NOT NULL REFERENCES public.home_mood_entries(id) ON DELETE CASCADE,

  -- Idempotency for personal inbox: one item per (recipient, entry)
  -- First publish wins (no later enrichment/upgrades).
  CONSTRAINT uq_personal_items_recipient_entry
    UNIQUE (recipient_user_id, source_entry_id)
);

COMMENT ON TABLE public.gratitude_wall_personal_items IS
  'Recipient-owned, immutable personal gratitude inbox items. Stable IDs only; resolve display fields at read time. First publish wins.';

CREATE INDEX IF NOT EXISTS idx_personal_items_recipient_created_desc
  ON public.gratitude_wall_personal_items (recipient_user_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_personal_items_recipient_author
  ON public.gratitude_wall_personal_items (recipient_user_id, author_user_id);

CREATE INDEX IF NOT EXISTS idx_personal_items_recipient_home
  ON public.gratitude_wall_personal_items (recipient_user_id, home_id);

CREATE TABLE IF NOT EXISTS public.gratitude_wall_personal_reads (
  user_id      uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_read_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.gratitude_wall_personal_reads IS
  'Recipient-only read cursor for the personal gratitude inbox.';

-- If an older iteration created this table, remove it (Option A legacy)
DROP TABLE IF EXISTS public.gratitude_wall_personal_mentions;

-- ---------------------------------------------------------------------
-- 3) RPC-only access: enable RLS + revoke table privileges
-- ---------------------------------------------------------------------

ALTER TABLE public.gratitude_wall_posts              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gratitude_wall_mentions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gratitude_wall_personal_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gratitude_wall_personal_reads     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gratitude_wall_reads              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_mood_entries                 ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.gratitude_wall_posts          FROM anon, authenticated;
REVOKE ALL ON TABLE public.gratitude_wall_mentions       FROM anon, authenticated;
REVOKE ALL ON TABLE public.gratitude_wall_personal_items FROM anon, authenticated;
REVOKE ALL ON TABLE public.gratitude_wall_personal_reads FROM anon, authenticated;
REVOKE ALL ON TABLE public.gratitude_wall_reads          FROM anon, authenticated;
REVOKE ALL ON TABLE public.home_mood_entries             FROM anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) Supporting indexes (safe no-ops)
-- ---------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS memberships_home_user_current_idx
ON public.memberships (home_id, user_id)
WHERE is_current = TRUE;

-- IMPORTANT:
-- Do NOT create idx_home_mood_entries_user_week here.
-- The UNIQUE constraint uq_home_mood_entries_user_week already provides the index.

CREATE INDEX IF NOT EXISTS idx_home_mood_entries_home_user
ON public.home_mood_entries (home_id, user_id);

-- ---------------------------------------------------------------------
-- 5) RPC A: mood_submit_v2 (weekly entry ONLY)
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.mood_submit_v2(uuid, public.mood_scale, text, boolean, uuid[]);

CREATE OR REPLACE FUNCTION public.mood_submit_v2(
  p_home_id      uuid,
  p_mood         public.mood_scale,
  p_comment      text DEFAULT NULL,
  p_public_wall  boolean DEFAULT FALSE,
  p_mentions     uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id        uuid;
  v_now            timestamptz := now();
  v_iso_week       int;
  v_iso_week_year  int;

  v_entry_id       uuid;
  v_comment_trim   text;

  v_message        text;
  v_post_id        uuid;
  v_source_kind    text;

  v_mentions_raw   uuid[] := COALESCE(p_mentions, ARRAY[]::uuid[]);
  v_mentions_dedup uuid[] := ARRAY[]::uuid[];
  v_mention_count  int := 0;

  v_publish_requested boolean;
BEGIN
  PERFORM public._assert_authenticated();
  v_user_id := auth.uid();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public.api_assert(p_mood IS NOT NULL, 'INVALID_MOOD', 'Mood is required.', '22023');

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT extract('week' FROM timezone('UTC', v_now))::int,
         extract('isoyear' FROM timezone('UTC', v_now))::int
    INTO v_iso_week, v_iso_week_year;

  v_comment_trim := NULLIF(btrim(p_comment), '');

  BEGIN
    INSERT INTO public.home_mood_entries (
      home_id, user_id, mood, comment, iso_week_year, iso_week
    )
    VALUES (
      p_home_id,
      v_user_id,
      p_mood,
      CASE WHEN v_comment_trim IS NULL THEN NULL ELSE left(v_comment_trim, 500) END,
      v_iso_week_year,
      v_iso_week
    )
    RETURNING id INTO v_entry_id;
  EXCEPTION
    WHEN unique_violation THEN
      PERFORM public.api_assert(
        FALSE,
        'MOOD_ALREADY_SUBMITTED',
        'Mood already submitted for this ISO week (across all homes).',
        'P0001',
        jsonb_build_object('isoWeek', v_iso_week, 'isoYear', v_iso_week_year)
      );
  END;

  v_publish_requested :=
    COALESCE(p_public_wall, FALSE)
    OR COALESCE(array_length(v_mentions_raw, 1), 0) > 0;

  IF NOT v_publish_requested THEN
    RETURN jsonb_build_object(
      'entry_id', v_entry_id,
      'public_post_id', NULL,
      'mention_count', 0
    );
  END IF;

  IF p_mood NOT IN ('sunny','partially_sunny') THEN
    PERFORM public.api_assert(
      FALSE,
      'NOT_POSITIVE_MOOD',
      'Publishing gratitude is only available for Sunny or Partially Sunny weeks.',
      '22023'
    );
  END IF;

  v_message := NULLIF(btrim(COALESCE(v_comment_trim, '')), '');
  IF v_message IS NOT NULL THEN
    v_message := left(v_message, 500);
  END IF;

  PERFORM public.api_assert(
    NOT EXISTS (SELECT 1 FROM unnest(v_mentions_raw) m WHERE m IS NULL),
    'INVALID_MENTION_USER',
    'Mention list cannot contain nulls.',
    '22023'
  );

  v_mentions_dedup := COALESCE((
    SELECT array_agg(m ORDER BY m)
    FROM (SELECT DISTINCT m FROM unnest(v_mentions_raw) m) s(m)
  ), ARRAY[]::uuid[]);

  v_mention_count := COALESCE(array_length(v_mentions_dedup, 1), 0);

  IF array_length(v_mentions_raw, 1) IS NOT NULL
     AND array_length(v_mentions_raw, 1) <> v_mention_count THEN
    PERFORM public.api_assert(FALSE, 'DUPLICATE_MENTIONS_NOT_ALLOWED', 'Mentions must be unique.', '22023');
  END IF;

  IF v_mention_count > 5 THEN
    PERFORM public.api_assert(FALSE, 'MENTION_LIMIT_EXCEEDED', 'You can mention at most 5 people.', '22023');
  END IF;

  IF v_user_id = ANY (v_mentions_dedup) THEN
    PERFORM public.api_assert(FALSE, 'SELF_MENTION_NOT_ALLOWED', 'You cannot mention yourself.', '22023');
  END IF;

  IF v_mention_count > 0 THEN
    PERFORM public.api_assert(
      NOT EXISTS (
        SELECT 1
        FROM unnest(v_mentions_dedup) m
        LEFT JOIN public.profiles p ON p.id = m
        LEFT JOIN public.memberships mem
               ON mem.home_id = p_home_id
              AND mem.user_id = m
              AND mem.is_current = TRUE
        WHERE p.id IS NULL OR mem.user_id IS NULL
      ),
      'MENTION_NOT_HOME_MEMBER',
      'All mentions must be existing profiles and current members of the home.',
      '22023'
    );
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('mood_submit_v2_publish'),
    hashtext(v_entry_id::text)
  );

  -- Idempotent insert without ON CONFLICT requirement
  IF COALESCE(p_public_wall, FALSE) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.gratitude_wall_posts WHERE source_entry_id = v_entry_id
    ) THEN
      INSERT INTO public.gratitude_wall_posts (
        home_id, author_user_id, mood, message, created_at, source_entry_id
      )
      SELECT p_home_id, v_user_id, p_mood, v_message, v_now, v_entry_id;
    END IF;

    SELECT id
      INTO v_post_id
      FROM public.gratitude_wall_posts
     WHERE source_entry_id = v_entry_id
     LIMIT 1;
  END IF;

  IF v_post_id IS NOT NULL AND v_mention_count > 0 THEN
    INSERT INTO public.gratitude_wall_mentions (post_id, home_id, mentioned_user_id, created_at)
    SELECT v_post_id, p_home_id, m, v_now
    FROM unnest(v_mentions_dedup) m
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_mention_count > 0 THEN
    v_source_kind := CASE WHEN v_post_id IS NULL THEN 'mention_only' ELSE 'home_post' END;

    INSERT INTO public.gratitude_wall_personal_items (
      recipient_user_id, home_id, author_user_id, mood, message,
      source_kind, source_post_id, source_entry_id, created_at
    )
    SELECT
      m, p_home_id, v_user_id, p_mood, v_message,
      v_source_kind, v_post_id, v_entry_id, v_now
    FROM unnest(v_mentions_dedup) m
    ON CONFLICT (recipient_user_id, source_entry_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'entry_id', v_entry_id,
    'public_post_id', v_post_id,
    'mention_count', v_mention_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.mood_submit_v2(uuid, public.mood_scale, text, boolean, uuid[])
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.mood_submit_v2(uuid, public.mood_scale, text, boolean, uuid[])
  TO authenticated;

COMMENT ON FUNCTION public.mood_submit_v2(uuid, public.mood_scale, text, boolean, uuid[]) IS
  'Single-call submit: creates weekly entry and optionally publishes (wall + mentions). '
  'Publishing allowed only for sunny/partially_sunny. First publish wins.';


-- ---------------------------------------------------------------------
-- 8) Personal inbox: status + mark read (nudge only if truly unread)
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.personal_gratitude_wall_status_v1();

CREATE OR REPLACE FUNCTION public.personal_gratitude_wall_status_v1()
RETURNS TABLE (
  has_unread   boolean,
  last_read_at timestamptz
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id           uuid := auth.uid();
  v_latest_created_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT r.last_read_at
    INTO last_read_at
  FROM public.gratitude_wall_personal_reads r
  WHERE r.user_id = v_user_id
  LIMIT 1;

  SELECT i.created_at
    INTO v_latest_created_at
  FROM public.gratitude_wall_personal_items i
  WHERE i.recipient_user_id = v_user_id
    AND i.author_user_id <> v_user_id
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT 1;

  has_unread :=
    CASE
      WHEN v_latest_created_at IS NULL THEN FALSE
      WHEN last_read_at IS NULL THEN TRUE
      ELSE v_latest_created_at > last_read_at
    END;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_wall_status_v1()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_wall_status_v1()
  TO authenticated;

DROP FUNCTION IF EXISTS public.personal_gratitude_wall_mark_read_v1();

CREATE OR REPLACE FUNCTION public.personal_gratitude_wall_mark_read_v1()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  INSERT INTO public.gratitude_wall_personal_reads (user_id, last_read_at)
  VALUES (v_user_id, now())
  ON CONFLICT (user_id)
  DO UPDATE SET last_read_at = EXCLUDED.last_read_at;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_wall_mark_read_v1()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_wall_mark_read_v1()
  TO authenticated;

-- ---------------------------------------------------------------------
-- 9) Personal inbox list (paged) — resolves author username + avatar storage_path
--     Enforce cursor: both or neither (p_before_at + p_before_id)
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid);

CREATE OR REPLACE FUNCTION public.personal_gratitude_inbox_list_v1(
  p_limit     int DEFAULT 30,
  p_before_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
) RETURNS TABLE (
  id                 uuid,
  created_at         timestamptz,
  home_id            uuid,
  mood               public.mood_scale,
  message            text,
  source_kind        text,
  source_post_id     uuid,
  source_entry_id    uuid,

  author_user_id     uuid,
  author_username    public.citext,
  author_avatar_id   uuid,
  author_avatar_path text
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  p_limit := GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));

  -- Enforce: both cursor parts must be provided together, or neither.
  PERFORM public.api_assert(
    (p_before_at IS NULL AND p_before_id IS NULL)
    OR (p_before_at IS NOT NULL AND p_before_id IS NOT NULL),
    'INVALID_PAGINATION_CURSOR',
    'Pagination cursor requires both before_at and before_id, or neither.',
    '22023',
    jsonb_build_object('before_at', p_before_at, 'before_id', p_before_id)
  );

  RETURN QUERY
  SELECT
    i.id,
    i.created_at,
    i.home_id,
    i.mood,
    i.message,
    i.source_kind,
    i.source_post_id,
    i.source_entry_id,

    p.id           AS author_user_id,
    p.username     AS author_username,
    p.avatar_id    AS author_avatar_id,
    a.storage_path AS author_avatar_path
  FROM public.gratitude_wall_personal_items i
  JOIN public.profiles p
    ON p.id = i.author_user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE i.recipient_user_id = v_user_id
    AND (
      p_before_at IS NULL
      OR i.created_at < p_before_at
      OR (i.created_at = p_before_at AND i.id < p_before_id)
    )
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid)
  TO authenticated;

COMMENT ON FUNCTION public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid) IS
  'Recipient personal gratitude inbox list (paged). Resolves author username + avatar storage_path at read time. Cursor requires both before_at and before_id.';

-- ---------------------------------------------------------------------
-- 10) Personal gratitude showcase stats (no p_since)
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.personal_gratitude_showcase_stats_v1(boolean);

CREATE OR REPLACE FUNCTION public.personal_gratitude_showcase_stats_v1(
  p_exclude_self boolean DEFAULT TRUE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_total   bigint;
  v_authors bigint;
  v_homes   bigint;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT
    COUNT(*)::bigint,
    COUNT(DISTINCT i.author_user_id)::bigint,
    COUNT(DISTINCT i.home_id)::bigint
  INTO v_total, v_authors, v_homes
  FROM public.gratitude_wall_personal_items i
  WHERE i.recipient_user_id = v_user_id
    AND (NOT p_exclude_self OR i.author_user_id <> v_user_id);

  RETURN jsonb_build_object(
    'total_received',     COALESCE(v_total, 0),
    'unique_individuals', COALESCE(v_authors, 0),
    'unique_homes',       COALESCE(v_homes, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_showcase_stats_v1(boolean)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_showcase_stats_v1(boolean)
  TO authenticated;

COMMENT ON FUNCTION public.personal_gratitude_showcase_stats_v1(boolean) IS
  'Showcase stats for auth.uid() from personal gratitude inbox: total received items, unique authors, unique homes.';
