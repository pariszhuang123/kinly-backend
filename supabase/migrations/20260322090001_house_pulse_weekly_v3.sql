-- Canonical UTC ISO week/year resolver (single source of truth)
CREATE OR REPLACE FUNCTION public._iso_week_utc(
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE (
  iso_week_year int,
  iso_week int
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    to_char((p_at AT TIME ZONE 'UTC')::date, 'IYYY')::int AS iso_week_year,
    to_char((p_at AT TIME ZONE 'UTC')::date, 'IW')::int   AS iso_week;
$$;

REVOKE ALL ON FUNCTION public._iso_week_utc(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._iso_week_utc(timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.house_pulse_weekly_get(
  p_home_id uuid,
  p_iso_week_year int DEFAULT NULL,
  p_iso_week int DEFAULT NULL,
  p_contract_version text DEFAULT 'v1'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := now();
  v_iso_week int;
  v_iso_week_year int;

  v_cv text := COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1');

  v_row public.house_pulse_weekly;
  v_label public.house_pulse_labels;
  v_seen public.house_pulse_reads;

  v_latest_entry_at timestamptz;
  v_needs_recompute boolean := false;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Fix 3: canonical iso week/year (UTC ISO)
  SELECT
    COALESCE(p_iso_week_year, w.iso_week_year),
    COALESCE(p_iso_week, w.iso_week)
  INTO v_iso_week_year, v_iso_week
  FROM public._iso_week_utc(v_now) w;

  PERFORM public.api_assert(
    p_iso_week IS NULL OR (p_iso_week BETWEEN 1 AND 53),
    'INVALID_ARGUMENT',
    'iso_week must be between 1 and 53.',
    '22023'
  );

  PERFORM public.api_assert(
    p_iso_week_year IS NULL OR (p_iso_week_year BETWEEN 2000 AND 2100),
    'INVALID_ARGUMENT',
    'iso_week_year is out of supported range.',
    '22023'
  );

  SELECT *
    INTO v_row
    FROM public.house_pulse_weekly w
   WHERE w.home_id = p_home_id
     AND w.iso_week_year = v_iso_week_year
     AND w.iso_week = v_iso_week
     AND w.contract_version = v_cv;

  IF FOUND THEN
    -- Fix 1: determine whether new relevant entries exist since computed_at
    -- Only consider entries authored by CURRENT members (matches compute semantics)
    SELECT MAX(e.created_at)
      INTO v_latest_entry_at
      FROM public.home_mood_entries e
      JOIN public.memberships m
        ON m.home_id = p_home_id
       AND m.user_id = e.user_id
       AND m.is_current = TRUE
     WHERE e.home_id = p_home_id
       AND e.iso_week_year = v_iso_week_year
       AND e.iso_week = v_iso_week;

    v_needs_recompute :=
      (v_latest_entry_at IS NOT NULL)
      AND (v_latest_entry_at > v_row.computed_at);

    IF v_needs_recompute THEN
      v_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, v_cv);
    END IF;

    SELECT *
      INTO v_seen
      FROM public.house_pulse_reads r
     WHERE r.home_id = p_home_id
       AND r.user_id = auth.uid()
       AND r.iso_week_year = v_iso_week_year
       AND r.iso_week = v_iso_week
       AND r.contract_version = v_cv;

    SELECT *
      INTO v_label
      FROM public.house_pulse_labels l
     WHERE l.contract_version = v_cv
       AND l.pulse_state = v_row.pulse_state
       AND l.is_active = TRUE;

    RETURN jsonb_build_object(
      'pulse', to_jsonb(v_row),
      'label', to_jsonb(v_label),
      'seen', to_jsonb(v_seen)
    );
  END IF;

  -- No snapshot yet -> compute
  v_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, v_cv);

  SELECT *
    INTO v_seen
    FROM public.house_pulse_reads r
   WHERE r.home_id = p_home_id
     AND r.user_id = auth.uid()
     AND r.iso_week_year = v_iso_week_year
     AND r.iso_week = v_iso_week
     AND r.contract_version = v_cv;

  SELECT *
    INTO v_label
    FROM public.house_pulse_labels l
   WHERE l.contract_version = v_cv
     AND l.pulse_state = v_row.pulse_state
     AND l.is_active = TRUE;

  RETURN jsonb_build_object(
    'pulse', to_jsonb(v_row),
    'label', to_jsonb(v_label),
    'seen', to_jsonb(v_seen)
  );
END;
$$;


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

  -- Fix 2: computed snapshot row (optional return use; we just force refresh)
  v_pulse_row public.house_pulse_weekly;
BEGIN
  PERFORM public._assert_authenticated();
  v_user_id := auth.uid();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public.api_assert(p_mood IS NOT NULL, 'INVALID_MOOD', 'Mood is required.', '22023');

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Fix 3: canonical UTC ISO week/year
  SELECT w.iso_week_year, w.iso_week
    INTO v_iso_week_year, v_iso_week
    FROM public._iso_week_utc(v_now) w;

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

  -- Fix 2: eagerly recompute weekly pulse snapshot after a new entry
  -- Keeps the UI fresh even if weekly_get hits an existing snapshot.
  v_pulse_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, 'v1');

  v_publish_requested :=
    COALESCE(p_public_wall, FALSE)
    OR COALESCE(array_length(v_mentions_raw, 1), 0) > 0;

  IF NOT v_publish_requested THEN
    RETURN jsonb_build_object(
      'entry_id', v_entry_id,
      'public_post_id', NULL,
      'mention_count', 0,
      -- optional: nice for immediate UI refresh without an extra call
      'pulse', to_jsonb(v_pulse_row)
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
    'mention_count', v_mention_count,
    -- optional: return pulse so UI can update instantly
    'pulse', to_jsonb(v_pulse_row)
  );
END;
$$;
