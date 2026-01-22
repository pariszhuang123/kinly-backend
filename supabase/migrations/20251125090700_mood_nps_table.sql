-- =====================================================================
--  Enums
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'mood_scale'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.mood_scale AS ENUM (
      'sunny',
      'partially_sunny',
      'cloudy',
      'rainy',
      'thunderstorm'
    );
  END IF;
END
$$;

COMMENT ON TYPE public.mood_scale IS
  'Scale for household mood: sunny, partially_sunny, cloudy, rainy, thunderstorm.';


-- =====================================================================
--  Core Tables: Gratitude & Mood
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.gratitude_wall_posts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id         uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  author_user_id  uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  mood            public.mood_scale NOT NULL,
  message         text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_gratitude_wall_posts_message_len
    CHECK (message IS NULL OR char_length(message) <= 500)
);

COMMENT ON TABLE public.gratitude_wall_posts IS
  'Immutable gratitude messages shared on the home gratitude wall.';

COMMENT ON COLUMN public.gratitude_wall_posts.id IS
  'Unique identifier for the gratitude wall post.';

COMMENT ON COLUMN public.gratitude_wall_posts.home_id IS
  'ID of the home this gratitude post belongs to.';

COMMENT ON COLUMN public.gratitude_wall_posts.author_user_id IS
  'Profile ID of the user who authored this gratitude post.';

COMMENT ON COLUMN public.gratitude_wall_posts.mood IS
  'Mood selected when the gratitude post was created (from mood_scale).';

COMMENT ON COLUMN public.gratitude_wall_posts.message IS
  'User-supplied gratitude message. May be NULL when no text was provided. Max 500 characters.';

COMMENT ON COLUMN public.gratitude_wall_posts.created_at IS
  'Timestamp when this gratitude post was created.';

CREATE INDEX IF NOT EXISTS idx_gratitude_wall_posts_home_created_desc
  ON public.gratitude_wall_posts (home_id, created_at DESC, id DESC);


CREATE TABLE IF NOT EXISTS public.home_mood_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id           uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  mood              public.mood_scale NOT NULL,
  comment           text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  iso_week_year     int  NOT NULL,
  iso_week          int  NOT NULL,
  gratitude_post_id uuid REFERENCES public.gratitude_wall_posts(id) ON DELETE SET NULL,

  CONSTRAINT chk_home_mood_entries_comment_len
    CHECK (comment IS NULL OR char_length(comment) <= 500),

  -- One mood per user per ISO week across ALL homes
  CONSTRAINT uq_home_mood_entries_user_week
    UNIQUE (user_id, iso_week_year, iso_week)
);

COMMENT ON TABLE public.home_mood_entries IS
  'Weekly mood capture per user (one entry per ISO week across all homes; home_id records which home they were in).';

COMMENT ON COLUMN public.home_mood_entries.id IS
  'Unique identifier for the mood entry.';

COMMENT ON COLUMN public.home_mood_entries.home_id IS
  'ID of the home this mood entry is associated with.';

COMMENT ON COLUMN public.home_mood_entries.user_id IS
  'Profile ID of the user whose mood is recorded in this entry.';

COMMENT ON COLUMN public.home_mood_entries.mood IS
  'Mood selected by the user for this ISO week (from mood_scale).';

COMMENT ON COLUMN public.home_mood_entries.comment IS
  'Optional user comment about how the home feels this week. May be NULL. Max 500 characters.';

COMMENT ON COLUMN public.home_mood_entries.created_at IS
  'Timestamp when this mood entry was created.';

COMMENT ON COLUMN public.home_mood_entries.iso_week_year IS
  'ISO year number for this mood entry (e.g. 2025).';

COMMENT ON COLUMN public.home_mood_entries.iso_week IS
  'ISO week number for this mood entry (1–53).';

COMMENT ON COLUMN public.home_mood_entries.gratitude_post_id IS
  'Optional link to a gratitude wall post created from this mood entry (if the user chose to share).';

-- Helpful index for per-user weekly checks (one mood per week across all homes)
CREATE INDEX IF NOT EXISTS idx_home_mood_entries_user_week
  ON public.home_mood_entries (user_id, iso_week_year, iso_week);

-- Keep the per-home, per-user index if you still want it
CREATE INDEX IF NOT EXISTS idx_home_mood_entries_home_user
  ON public.home_mood_entries (home_id, user_id);


CREATE TABLE IF NOT EXISTS public.gratitude_wall_reads (
  home_id      uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_read_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_gratitude_wall_reads PRIMARY KEY (home_id, user_id)
);

COMMENT ON TABLE public.gratitude_wall_reads IS
  'Tracks when each user last read the gratitude wall for a given home.';

COMMENT ON COLUMN public.gratitude_wall_reads.home_id IS
  'ID of the home whose gratitude wall is being tracked.';

COMMENT ON COLUMN public.gratitude_wall_reads.user_id IS
  'Profile ID of the user whose last read time is stored.';

COMMENT ON COLUMN public.gratitude_wall_reads.last_read_at IS
  'Timestamp when the user last marked the gratitude wall as read for this home.';


-- =====================================================================
--  NPS Counters & NPS Responses
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.home_mood_feedback_counters (
  home_id                  uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  user_id                  uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  feedback_count           integer NOT NULL DEFAULT 0,
  first_feedback_at        timestamptz,
  last_feedback_at         timestamptz,

  -- NPS tracking
  last_nps_at              timestamptz,
  last_nps_score           integer,
  last_nps_feedback_count  integer NOT NULL DEFAULT 0,
  nps_required             boolean NOT NULL DEFAULT false,

  CONSTRAINT pk_home_mood_feedback_counters PRIMARY KEY (home_id, user_id),

  CONSTRAINT chk_home_mood_feedback_counters_last_nps_score
    CHECK (last_nps_score IS NULL OR last_nps_score BETWEEN 0 AND 10)
);

COMMENT ON TABLE public.home_mood_feedback_counters IS
  'Per-home per-user counters for Harmony feedback and NPS state.';

COMMENT ON COLUMN public.home_mood_feedback_counters.feedback_count IS
  'Total number of mood feedback entries submitted by this user in this home.';

COMMENT ON COLUMN public.home_mood_feedback_counters.last_nps_feedback_count IS
  'Feedback_count value at which the last NPS was completed (0 = never).';

COMMENT ON COLUMN public.home_mood_feedback_counters.nps_required IS
  'TRUE when an NPS answer is required and must be completed before normal use.';


CREATE TABLE IF NOT EXISTS public.home_nps (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id             uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  user_id             uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  score               integer NOT NULL CHECK (score BETWEEN 0 AND 10),
  created_at          timestamptz NOT NULL DEFAULT now(),

  -- Feedback milestone at which this NPS was answered (e.g. 13, 26, 39...)
  nps_feedback_count  integer NOT NULL
);

COMMENT ON TABLE public.home_nps IS
  'History of NPS responses per home and user, tied to feedback milestones.';

COMMENT ON COLUMN public.home_nps.nps_feedback_count IS
  'Value of feedback_count at the time this NPS was submitted (e.g. 13, 26, 39...).';

CREATE INDEX IF NOT EXISTS idx_home_nps_home_created_desc
  ON public.home_nps (home_id, created_at DESC, id DESC);

-- =====================================================================
--  Trigger: Maintain home_mood_feedback_counters
-- =====================================================================

CREATE OR REPLACE FUNCTION public.home_mood_feedback_counters_inc()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row       public.home_mood_feedback_counters%ROWTYPE;
  v_milestone integer;
  v_step      constant integer := 13; -- feedbacks per NPS milestone
BEGIN
  -- Ensure caller is authenticated; membership checks already happen in mood_submit
  PERFORM public._assert_authenticated();

  -- Upsert basic counters
  INSERT INTO public.home_mood_feedback_counters AS c (
    home_id,
    user_id,
    feedback_count,
    first_feedback_at,
    last_feedback_at
  )
  VALUES (
    NEW.home_id,
    NEW.user_id,
    1,
    NEW.created_at,
    NEW.created_at
  )
  ON CONFLICT (home_id, user_id)
  DO UPDATE
    SET feedback_count   = c.feedback_count + 1,
        last_feedback_at = NEW.created_at;

  -- Fetch updated row
  SELECT *
  INTO v_row
  FROM public.home_mood_feedback_counters
  WHERE home_id = NEW.home_id
    AND user_id = NEW.user_id;

  -- Compute current milestone and decide if NPS is required.
  -- Example: feedback_count = 13 -> milestone = 13
  --          feedback_count = 20 -> milestone = 13
  --          feedback_count = 26 -> milestone = 26
  IF v_row.feedback_count >= v_step THEN
    v_milestone := (v_row.feedback_count / v_step) * v_step;

    IF v_milestone > 0
       AND v_milestone > v_row.last_nps_feedback_count
    THEN
      UPDATE public.home_mood_feedback_counters
      SET nps_required = TRUE
      WHERE home_id = NEW.home_id
        AND user_id = NEW.user_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.home_mood_feedback_counters_inc() IS
  'Trigger to maintain per-home per-user feedback counters and mark when NPS is required.';

DROP TRIGGER IF EXISTS trg_home_mood_feedback_counters_inc
  ON public.home_mood_entries;

CREATE TRIGGER trg_home_mood_feedback_counters_inc
AFTER INSERT ON public.home_mood_entries
FOR EACH ROW
EXECUTE FUNCTION public.home_mood_feedback_counters_inc();


-- =====================================================================
--  RLS + Table Privileges (no direct table access; RPCs only)
-- =====================================================================


REVOKE ALL ON public.gratitude_wall_posts,
               public.home_mood_entries,
               public.gratitude_wall_reads,
               public.home_mood_feedback_counters,
               public.home_nps
  FROM anon, authenticated;


-- =====================================================================
--  RPCs (SECURITY DEFINER)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mood_submit(
  p_home_id     uuid,
  p_mood        public.mood_scale,
  p_comment     text DEFAULT NULL,
  p_add_to_wall boolean DEFAULT FALSE
) RETURNS TABLE (
  entry_id           uuid,
  gratitude_post_id  uuid
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_iso_week      int;
  v_iso_week_year int;
  v_post_id       uuid;
  v_comment_trim  text;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  PERFORM public.api_assert(
    p_home_id IS NOT NULL,
    'INVALID_HOME',
    'Home id is required.',
    '22023'
  );

  PERFORM public.api_assert(
    p_mood IS NOT NULL,
    'INVALID_MOOD',
    'Mood is required.',
    '22023'
  );

  SELECT extract('week' FROM timezone('UTC', now()))::int,
         extract('isoyear' FROM timezone('UTC', now()))::int
    INTO v_iso_week, v_iso_week_year;

    PERFORM public.api_assert(
    NOT EXISTS (
        SELECT 1
        FROM public.home_mood_entries e
        WHERE e.user_id       = v_user_id
        AND e.iso_week_year = v_iso_week_year
        AND e.iso_week      = v_iso_week
    ),
    'MOOD_ALREADY_SUBMITTED',
    'Mood already submitted for this ISO week (across all homes).',
    'P0001',
    jsonb_build_object('isoWeek', v_iso_week, 'isoYear', v_iso_week_year)
    );

  -- Normalise comment: trim whitespace, turn empty string into NULL, then cap length at 500
  v_comment_trim := NULLIF(btrim(p_comment), '');

  INSERT INTO public.home_mood_entries (
    home_id,
    user_id,
    mood,
    comment,
    iso_week_year,
    iso_week
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_mood,
    CASE
      WHEN v_comment_trim IS NULL THEN NULL
      ELSE left(v_comment_trim, 500)
    END,
    v_iso_week_year,
    v_iso_week
  )
  RETURNING id INTO entry_id;

  IF COALESCE(p_add_to_wall, FALSE) AND p_mood IN ('sunny','partially_sunny') THEN
    INSERT INTO public.gratitude_wall_posts (
      home_id,
      author_user_id,
      mood,
      message
    )
    VALUES (
      p_home_id,
      v_user_id,
      p_mood,
      CASE
        WHEN v_comment_trim IS NULL THEN NULL
        ELSE left(v_comment_trim, 500)
      END
    )
    RETURNING id INTO v_post_id;

    UPDATE public.home_mood_entries
    SET gratitude_post_id = v_post_id
    WHERE id = entry_id;
  END IF;

  gratitude_post_id := v_post_id;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.mood_submit(uuid, public.mood_scale, text, boolean) IS
  'Submit the current user''s weekly mood for a home. '
  'Enforces one entry per user per ISO week across all homes. '
  'Optionally creates a gratitude wall post when mood is positive (sunny/partially_sunny) and p_add_to_wall is true. '
  'Parameters: p_home_id (home ID), p_mood (mood_scale value), p_comment (optional text), p_add_to_wall (whether to post to gratitude wall). '
  'Returns: entry_id (mood entry ID), gratitude_post_id (ID of created gratitude wall post, or NULL).';


CREATE OR REPLACE FUNCTION public.mood_get_current_weekly(
  p_home_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_iso_week      int;
  v_iso_week_year int;
  v_exists        boolean;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT extract('week' FROM timezone('UTC', now()))::int,
         extract('isoyear' FROM timezone('UTC', now()))::int
  INTO v_iso_week, v_iso_week_year;

  SELECT EXISTS (
    SELECT 1
    FROM public.home_mood_entries e
    WHERE e.user_id       = v_user_id
      AND e.iso_week_year = v_iso_week_year
      AND e.iso_week      = v_iso_week
  )
  INTO v_exists;

  RETURN v_exists;
END;
$$;

COMMENT ON FUNCTION public.mood_get_current_weekly(uuid) IS
  'Returns TRUE if the user already submitted a mood entry for the current ISO week (in ANY home), otherwise FALSE. '
  'The p_home_id parameter is used only for membership and home-active checks.';


CREATE OR REPLACE FUNCTION public.gratitude_wall_list(
  p_home_id            uuid,
  p_limit              int DEFAULT 20,
  p_cursor_created_at  timestamptz DEFAULT NULL,
  p_cursor_id          uuid DEFAULT NULL
) RETURNS TABLE (
  post_id        uuid,
  author_user_id uuid,
  mood           public.mood_scale,
  message        text,
  created_at     timestamptz
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit int := LEAST(COALESCE(p_limit, 20), 100);
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  RETURN QUERY
  SELECT p.id,
         p.author_user_id,
         p.mood,
         p.message,
         p.created_at
  FROM public.gratitude_wall_posts p
  WHERE p.home_id = p_home_id
    AND (
      p_cursor_created_at IS NULL
      OR (
        p.created_at < p_cursor_created_at
        OR (
          p_cursor_id IS NOT NULL
          AND p.created_at = p_cursor_created_at
          AND p.id < p_cursor_id
        )
      )
    )
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION public.gratitude_wall_list(uuid, int, timestamptz, uuid) IS
  'List gratitude wall posts for a home, ordered newest to oldest, with cursor-based pagination. '
  'Parameters: p_home_id (home ID), p_limit (max rows, default 20, capped at 100), '
  'p_cursor_created_at (created_at of last seen post for pagination), p_cursor_id (ID of last seen post). '
  'Returns: post_id, author_user_id, mood, message, created_at.';


CREATE OR REPLACE FUNCTION public.gratitude_wall_mark_read(
  p_home_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  INSERT INTO public.gratitude_wall_reads (home_id, user_id, last_read_at)
  VALUES (p_home_id, v_user_id, now())
  ON CONFLICT (home_id, user_id)
  DO UPDATE SET last_read_at = EXCLUDED.last_read_at;

  -- If we got here without error, we consider it a success.
  RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION public.gratitude_wall_mark_read(uuid) IS
  'Mark the gratitude wall as read for the current user in the specified home. '
  'Inserts or updates the last_read_at timestamp in gratitude_wall_reads. '
  'Parameters: p_home_id (home ID). '
  'Returns: boolean (TRUE on success).';

-- =====================================================================
--  RPC: home_nps_get_status  (minimal)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.home_nps_get_status(
  p_home_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_required boolean;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT c.nps_required
  INTO v_required
  FROM public.home_mood_feedback_counters c
  WHERE c.home_id = p_home_id
    AND c.user_id = v_user_id;

  RETURN COALESCE(v_required, FALSE);
END;
$$;

COMMENT ON FUNCTION public.home_nps_get_status(uuid) IS
  'Returns TRUE if an NPS response is currently required for this user in the given home, otherwise FALSE.';

-- =====================================================================
--  RPC: home_nps_submit (score only)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.home_nps_submit(
  p_home_id  uuid,
  p_score    integer
) RETURNS public.home_nps
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id  uuid := auth.uid();
  v_counters public.home_mood_feedback_counters%ROWTYPE;
  v_row      public.home_nps%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Validate score
  PERFORM public.api_assert(
    p_score BETWEEN 0 AND 10,
    'INVALID_NPS_SCORE',
    'NPS score must be between 0 and 10.',
    '22023'
  );

  -- Get counters row
  SELECT *
  INTO v_counters
  FROM public.home_mood_feedback_counters
  WHERE home_id = p_home_id
    AND user_id = v_user_id;

  -- Must have some feedback history
  PERFORM public.api_assert(
    v_counters.home_id IS NOT NULL,
    'NPS_NOT_ELIGIBLE',
    'NPS cannot be submitted before any mood feedback.',
    '22023'
  );

  -- NPS must actually be required right now
  PERFORM public.api_assert(
    v_counters.nps_required IS TRUE,
    'NPS_NOT_REQUIRED',
    'NPS is not currently required.',
    '22023'
  );

  INSERT INTO public.home_nps (
    home_id,
    user_id,
    score,
    nps_feedback_count
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_score,
    v_counters.feedback_count
  )
  RETURNING * INTO v_row;

  -- Update counters with latest NPS info and clear the requirement
  UPDATE public.home_mood_feedback_counters
  SET last_nps_at             = v_row.created_at,
      last_nps_score          = v_row.score,
      last_nps_feedback_count = v_row.nps_feedback_count,
      nps_required            = FALSE
  WHERE home_id = p_home_id
    AND user_id = v_user_id;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.home_nps_submit(uuid, integer) IS
  'Submit an NPS response (0–10) for a home when NPS is required. '
  'Uses current feedback_count as nps_feedback_count, records the score, '
  'and clears nps_required in home_mood_feedback_counters.';


-- =====================================================================
--  RPC Grants
-- =====================================================================

REVOKE ALL ON FUNCTION public.mood_submit(uuid, public.mood_scale, text, boolean)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.mood_get_current_weekly(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.gratitude_wall_list(uuid, int, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.gratitude_wall_mark_read(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.home_nps_get_status(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.home_nps_submit(uuid, integer)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.mood_submit(uuid, public.mood_scale, text, boolean)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.mood_get_current_weekly(uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.gratitude_wall_list(uuid, int, timestamptz, uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.gratitude_wall_mark_read(uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.home_nps_get_status(uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.home_nps_submit(uuid, integer)
  TO authenticated;
