CREATE OR REPLACE FUNCTION public.house_pulse_compute_week(
  p_home_id uuid,
  p_iso_week_year int DEFAULT NULL,
  p_iso_week int DEFAULT NULL,
  p_contract_version text DEFAULT 'v1'
)
RETURNS public.house_pulse_weekly
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := now();
  v_iso_week int;
  v_iso_week_year int;

  v_member_count int := 0;
  v_reflection_count int := 0;

  v_light_count int := 0;
  v_neutral_count int := 0;
  v_heavy_count int := 0;

  v_distinct_participants int := 0;
  v_has_any_comment boolean := false;

  v_heavy_ratio numeric := 0;
  v_light_ratio numeric := 0;
  v_participation_ratio numeric := 0;

  v_has_thunderstorm boolean := false;
  v_has_complexity_note boolean := false; -- heavy mood + comment
  v_has_weekly_personal_mention boolean := false;

  v_care_present boolean := false;
  v_friction_present boolean := false;
  v_complexity_present boolean := false;

  v_weather_mode public.mood_scale;
  v_pulse_state public.house_pulse_state;
  v_weather_for_display public.mood_scale;

  v_row public.house_pulse_weekly;

  v_missing_label boolean := false;
  v_cv text := COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1');

  v_required_reflections int := 0;
BEGIN
  PERFORM public._assert_authenticated();

  -- Home checks
  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Resolve week (UTC ISO week/year) using v_now for consistency
  SELECT
    COALESCE(
      p_iso_week,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IW')::int
    ),
    COALESCE(
      p_iso_week_year,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IYYY')::int
    )
  INTO v_iso_week, v_iso_week_year;

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

  -- Advisory lock: serialize compute per (home, week, contract) using bigint hash
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      format('house_pulse:%s:%s:%s:%s', p_home_id::text, v_iso_week_year::text, v_iso_week::text, v_cv),
      0
    )
  );

  -- Current member count (current home composition)
  SELECT COUNT(*)
    INTO v_member_count
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current = TRUE;

  -- Consolidated aggregation for week entries (from CURRENT members)
  WITH current_members AS (
    SELECT m.user_id
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE
  ),
  week_entries AS (
    SELECT e.id, e.user_id, e.mood, e.comment
    FROM public.home_mood_entries e
    JOIN current_members cm ON cm.user_id = e.user_id
    WHERE e.home_id = p_home_id
      AND e.iso_week_year = v_iso_week_year
      AND e.iso_week = v_iso_week
  ),
  counts AS (
    SELECT
      we.mood,
      COUNT(*) AS cnt,
      CASE we.mood
        WHEN 'thunderstorm' THEN 5
        WHEN 'rainy' THEN 4
        WHEN 'cloudy' THEN 3
        WHEN 'partially_sunny' THEN 2
        WHEN 'sunny' THEN 1
        ELSE 0
      END AS weight
    FROM week_entries we
    GROUP BY we.mood
  ),
  mention_presence AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.gratitude_wall_personal_items i
      JOIN week_entries we ON we.id = i.source_entry_id
      WHERE i.home_id = p_home_id
        AND i.author_user_id <> i.recipient_user_id
    ) AS has_weekly_personal_mention
  )
  SELECT
    -- bucket counts
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood IN ('sunny','partially_sunny')), 0) AS light_count,
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood = 'cloudy'), 0) AS neutral_count,
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood IN ('rainy','thunderstorm')), 0) AS heavy_count,
    COALESCE(SUM(c.cnt), 0) AS total_count,

    -- flags
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood = 'thunderstorm'), 0) > 0 AS has_thunderstorm,

    -- deterministic mode mood (stable tie-break)
    (
      SELECT c2.mood
      FROM counts c2
      ORDER BY c2.cnt DESC, c2.weight DESC, c2.mood ASC
      LIMIT 1
    ) AS weather_mode,

    -- complexity note: ONLY count non-empty comments on rainy/thunderstorm
    EXISTS (
      SELECT 1
      FROM week_entries we2
      WHERE we2.mood IN ('rainy','thunderstorm')
        AND NULLIF(btrim(we2.comment), '') IS NOT NULL
    ) AS has_complexity_note,

    -- care amplifier: personal mention exists for that week
    (SELECT mp.has_weekly_personal_mention FROM mention_presence mp) AS has_weekly_personal_mention,

    -- additional care signals
    (SELECT COUNT(DISTINCT we3.user_id) FROM week_entries we3) AS distinct_participants,
    EXISTS (
      SELECT 1 FROM week_entries we4
      WHERE NULLIF(btrim(we4.comment), '') IS NOT NULL
    ) AS has_any_comment
  FROM counts c
  INTO
    v_light_count, v_neutral_count, v_heavy_count,
    v_reflection_count,
    v_has_thunderstorm,
    v_weather_mode,
    v_has_complexity_note,
    v_has_weekly_personal_mention,
    v_distinct_participants,
    v_has_any_comment;

  IF v_reflection_count > 0 THEN
    v_heavy_ratio := v_heavy_count::numeric / v_reflection_count::numeric;
    v_light_ratio := v_light_count::numeric / v_reflection_count::numeric;
  END IF;

  IF v_member_count > 0 THEN
    v_participation_ratio := v_reflection_count::numeric / v_member_count::numeric;
  END IF;

  -- Softer FORMING gate:
  -- required reflections scales with home size but caps at 4, floor at 2 (unless solo home)
  v_required_reflections :=
    CASE
      WHEN v_member_count <= 1 THEN 1
      ELSE LEAST(4, GREATEST(2, CEIL(v_member_count * 0.35)::int))
    END;

  -- complexity_present is separate (no longer drives friction)
  v_complexity_present := v_has_complexity_note;

  -- care_present requires participation and at least one care signal:
  -- (>=25% light) OR (weekly personal mention) OR (any comment) OR (enough distinct participants)
  v_care_present :=
    v_reflection_count > 0 AND (
      v_light_ratio >= 0.25
      OR v_has_weekly_personal_mention
      OR v_has_any_comment
      OR (v_member_count >= 2 AND v_distinct_participants >= LEAST(3, CEIL(v_member_count * 0.50)::int))
    );

  -- friction_present is tension/conflict risk only:
  v_friction_present :=
    v_has_thunderstorm
    OR (v_reflection_count > 0 AND v_heavy_ratio >= 0.30);

  -- Participation gate (FORMING is "insufficient signal")
  v_pulse_state := NULL;

  IF v_member_count <= 0 THEN
    v_pulse_state := 'forming';
  ELSIF v_reflection_count < v_required_reflections THEN
    v_pulse_state := 'forming';
  ELSIF v_participation_ratio < 0.30 THEN
    v_pulse_state := 'forming';
  END IF;

  -- If not forming, classify
  IF v_pulse_state IS NULL THEN
    IF v_has_thunderstorm THEN
      v_pulse_state := 'thunderstorm';

    ELSIF v_reflection_count > 0 AND v_heavy_ratio >= 0.30 THEN
      IF v_care_present THEN
        v_pulse_state := 'rainy_supported';
      ELSE
        v_pulse_state := 'rainy_unsupported';
      END IF;

    ELSIF v_reflection_count > 0 AND v_light_ratio >= 0.60 AND v_care_present AND NOT v_friction_present THEN
      v_pulse_state := 'sunny_calm';

    ELSIF v_reflection_count > 0 AND v_light_ratio >= 0.40 AND v_care_present AND v_friction_present THEN
      v_pulse_state := 'sunny_bumpy';

    ELSIF v_reflection_count > 0 AND v_weather_mode = 'partially_sunny' AND v_care_present THEN
      v_pulse_state := 'partly_supported';

    ELSIF v_reflection_count > 0 AND v_weather_mode = 'cloudy' THEN
      IF v_friction_present THEN
        v_pulse_state := 'cloudy_tense';
      ELSE
        v_pulse_state := 'cloudy_steady';
      END IF;

    ELSE
      IF v_friction_present THEN
        v_pulse_state := 'cloudy_tense';
      ELSE
        v_pulse_state := 'cloudy_steady';
      END IF;
    END IF;
  END IF;

  -- Assert mapping exists (table-driven)
  SELECT NOT EXISTS (
    SELECT 1
    FROM public.house_pulse_labels l
    WHERE l.contract_version = v_cv
      AND l.pulse_state = v_pulse_state
      AND l.is_active = TRUE
  )
  INTO v_missing_label;

  PERFORM public.api_assert(
    v_missing_label = FALSE,
    'PULSE_LABEL_MISSING',
    'Missing house_pulse_labels mapping for contract/state.',
    'P0001',
    jsonb_build_object('contractVersion', v_cv, 'pulseState', v_pulse_state)
  );

  -- Optional display weather token
  v_weather_for_display := CASE v_pulse_state
    WHEN 'forming' THEN NULL
    WHEN 'thunderstorm' THEN 'thunderstorm'
    WHEN 'rainy_supported' THEN 'rainy'
    WHEN 'rainy_unsupported' THEN 'rainy'
    WHEN 'partly_supported' THEN 'partially_sunny'
    WHEN 'sunny_calm' THEN 'sunny'
    WHEN 'sunny_bumpy' THEN 'sunny'
    ELSE 'cloudy'
  END;

  INSERT INTO public.house_pulse_weekly (
    home_id, iso_week_year, iso_week, contract_version,
    member_count, reflection_count, weather_display,
    care_present, friction_present, complexity_present,
    pulse_state,
    computed_at
  )
  VALUES (
    p_home_id, v_iso_week_year, v_iso_week, v_cv,
    COALESCE(v_member_count, 0), COALESCE(v_reflection_count, 0), v_weather_for_display,
    COALESCE(v_care_present, FALSE), COALESCE(v_friction_present, FALSE), COALESCE(v_complexity_present, FALSE),
    v_pulse_state,
    v_now
  )
  ON CONFLICT (home_id, iso_week_year, iso_week, contract_version)
  DO UPDATE SET
    member_count = EXCLUDED.member_count,
    reflection_count = EXCLUDED.reflection_count,
    weather_display = EXCLUDED.weather_display,
    care_present = EXCLUDED.care_present,
    friction_present = EXCLUDED.friction_present,
    complexity_present = EXCLUDED.complexity_present,
    pulse_state = EXCLUDED.pulse_state,
    computed_at = EXCLUDED.computed_at
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

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
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT
    COALESCE(
      p_iso_week,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IW')::int
    ),
    COALESCE(
      p_iso_week_year,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IYYY')::int
    )
  INTO v_iso_week, v_iso_week_year;

  SELECT *
    INTO v_row
    FROM public.house_pulse_weekly w
   WHERE w.home_id = p_home_id
     AND w.iso_week_year = v_iso_week_year
     AND w.iso_week = v_iso_week
     AND w.contract_version = v_cv;

  IF FOUND THEN
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

CREATE OR REPLACE FUNCTION public.house_pulse_mark_seen(
  p_home_id uuid,
  p_iso_week_year int DEFAULT NULL,
  p_iso_week int DEFAULT NULL,
  p_contract_version text DEFAULT 'v1'
)
RETURNS public.house_pulse_reads
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid;
  v_now timestamptz := now();
  v_iso_week int;
  v_iso_week_year int;
  v_cv text := COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1');

  v_payload jsonb;
  v_pulse jsonb;
  v_row public.house_pulse_reads;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT
    COALESCE(
      p_iso_week,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IW')::int
    ),
    COALESCE(
      p_iso_week_year,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IYYY')::int
    )
  INTO v_iso_week, v_iso_week_year;

  -- single-call friendly: get-or-compute payload (jsonb with pulse/label/seen)
  v_payload := public.house_pulse_weekly_get(p_home_id, v_iso_week_year, v_iso_week, v_cv);
  v_pulse := v_payload->'pulse';

  INSERT INTO public.house_pulse_reads (
    home_id, user_id, iso_week_year, iso_week, contract_version,
    last_seen_pulse_state, last_seen_computed_at, seen_at
  )
  VALUES (
    p_home_id, v_user, v_iso_week_year, v_iso_week, v_cv,
    (v_pulse->>'pulse_state')::public.house_pulse_state,
    (v_pulse->>'computed_at')::timestamptz,
    v_now
  )
  ON CONFLICT (home_id, user_id, iso_week_year, iso_week, contract_version)
  DO UPDATE SET
    last_seen_pulse_state = EXCLUDED.last_seen_pulse_state,
    last_seen_computed_at = EXCLUDED.last_seen_computed_at,
    seen_at = EXCLUDED.seen_at
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;
