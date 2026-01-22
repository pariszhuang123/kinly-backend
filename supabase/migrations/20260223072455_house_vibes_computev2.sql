INSERT INTO public.house_vibe_labels (label_id, mapping_version, title_key, summary_key, image_key, ui)
VALUES
  -- NEW (covers default holes)
  ('warm_social_home',  'v1', 'vibe.warmSocial.title',    'vibe.warmSocial.summary',    'vibe_warm_social_v1',   '{"accent_token":"coral","badge_token":"social"}'),
  ('cozy_social_home',  'v1', 'vibe.cozySocial.title',    'vibe.cozySocial.summary',    'vibe_cozySocial_v1',    '{"accent_token":"lavender","badge_token":"social"}'),
  ('steady_home',       'v1', 'vibe.steady.title',        'vibe.steady.summary',        'vibe_steady_v1',        '{"accent_token":"green","badge_token":"steady"}')
ON CONFLICT (mapping_version, label_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.house_vibe_compute(
  p_home_id uuid,
  p_force boolean DEFAULT false,
  p_include_axes boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_mapping_version text;
  v_min_side int;
  v_required_n int;

  v_cached public.house_vibes%ROWTYPE;

  v_total int := 0;
  v_contributed int := 0;
  v_ratio numeric := 0;

  -- axis leans + confidences (default to balanced/0 if absent)
  v_energy_lean text := 'balanced';
  v_energy_conf numeric := 0;

  v_structure_lean text := 'balanced';
  v_structure_conf numeric := 0;

  v_social_lean text := 'balanced';
  v_social_conf numeric := 0;

  v_repair_lean text := 'balanced';
  v_repair_conf numeric := 0;

  v_noise_lean text := 'balanced';
  v_noise_conf numeric := 0;

  v_clean_lean text := 'balanced';
  v_clean_conf numeric := 0;

  v_axes jsonb := '{}'::jsonb;

  v_label_id text := 'insufficient_data';
  v_label_conf numeric := 0;
  v_confidence_kind text := 'coverage';

  v_candidate_score numeric;
  v_best_score numeric := -1;
  v_best_label text := null;

  v_label_title_key text;
  v_label_summary_key text;
  v_label_image_key text;
  v_label_ui jsonb;

  -- time anchor to avoid drift
  v_now timestamptz := now();

BEGIN
  --------------------------------------------------------------------
  -- AuthZ guards (SECURITY DEFINER, but still enforce caller rights)
  --------------------------------------------------------------------
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._assert_home_member(p_home_id);

  --------------------------------------------------------------------
  -- Resolve mapping_version (active)
  --------------------------------------------------------------------
  SELECT hv.mapping_version
    INTO v_mapping_version
  FROM public.house_vibe_versions hv
  WHERE hv.status = 'active'
  ORDER BY hv.created_at DESC
  LIMIT 1;

  IF v_mapping_version IS NULL THEN
    v_mapping_version := 'v1';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_home_id::text || ':' || v_mapping_version, 0)
  );

  --------------------------------------------------------------------
  -- Return cached snapshot if not forcing and not out_of_date
  --------------------------------------------------------------------
  SELECT *
    INTO v_cached
  FROM public.house_vibes
  WHERE home_id = p_home_id
    AND mapping_version = v_mapping_version;

  IF v_cached.home_id IS NOT NULL
     AND p_force = false
     AND v_cached.out_of_date = false THEN

    SELECT title_key, summary_key, image_key, ui
      INTO v_label_title_key, v_label_summary_key, v_label_image_key, v_label_ui
    FROM public.house_vibe_labels
    WHERE mapping_version = v_cached.mapping_version
      AND label_id = v_cached.label_id
    LIMIT 1;

    RETURN jsonb_build_object(
      'ok', true,
      'source', 'cache',
      'home_id', v_cached.home_id,
      'mapping_version', v_cached.mapping_version,
      'label_id', v_cached.label_id,
      'confidence', v_cached.confidence,
      'confidence_kind', public._house_vibe_confidence_kind(v_cached.label_id),
      'coverage', jsonb_build_object(
        'answered', v_cached.coverage_answered,
        'total', v_cached.coverage_total
      ),
      'coverage_ratio', CASE
        WHEN v_cached.coverage_total = 0 THEN 0
        ELSE ROUND((v_cached.coverage_answered::numeric / v_cached.coverage_total::numeric), 3)
      END,
      'computed_at', v_cached.computed_at,
      'presentation', jsonb_build_object(
        'title_key', v_label_title_key,
        'summary_key', v_label_summary_key,
        'image_key', v_label_image_key,
        'ui', COALESCE(v_label_ui, '{}'::jsonb)
      ),
      'axes', CASE WHEN p_include_axes THEN COALESCE(v_cached.axes, '{}'::jsonb) ELSE '{}'::jsonb END
    );
  END IF;

  --------------------------------------------------------------------
  -- Total current members for this home
  --------------------------------------------------------------------
  SELECT COUNT(*)
    INTO v_total
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.is_current = true;

  --------------------------------------------------------------------
  -- Determine "complete set" requirement for this mapping version
  --------------------------------------------------------------------
  SELECT COUNT(DISTINCT me.preference_id)
    INTO v_required_n
  FROM public.house_vibe_mapping_effects me
  WHERE me.mapping_version = v_mapping_version;

  IF COALESCE(v_required_n, 0) <= 0 THEN
    RAISE EXCEPTION
      'house_vibe_compute: mapping_version % has no mapping_effects; cannot derive required preference count',
      v_mapping_version;
  END IF;

  --------------------------------------------------------------------
  -- min_side_count depends on total size
  --------------------------------------------------------------------
  SELECT CASE
           WHEN v_total <= 3 THEN hv.min_side_count_small
           ELSE hv.min_side_count_large
         END
    INTO v_min_side
  FROM public.house_vibe_versions hv
  WHERE hv.mapping_version = v_mapping_version
  ORDER BY hv.created_at DESC
  LIMIT 1;

  IF v_min_side IS NULL THEN
    v_min_side := 2;
  END IF;

  --------------------------------------------------------------------
  -- Contributors + Axes (single pass)
  --------------------------------------------------------------------
  WITH
  current_members AS (
    SELECT m.user_id
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.is_current = true
  ),
  required_prefs AS (
    SELECT DISTINCT me.preference_id
    FROM public.house_vibe_mapping_effects me
    WHERE me.mapping_version = v_mapping_version
  ),
  per_user_required AS (
    SELECT
      pr.user_id,
      COUNT(DISTINCT pr.preference_id) AS answered_required_n
    FROM public.preference_responses pr
    JOIN current_members cm
      ON cm.user_id = pr.user_id
    JOIN required_prefs rp
      ON rp.preference_id = pr.preference_id
    GROUP BY pr.user_id
  ),
  contributors AS (
    SELECT pur.user_id
    FROM per_user_required pur
    WHERE pur.answered_required_n >= v_required_n
  ),
  contributed_count AS (
    SELECT COUNT(*)::int AS n
    FROM contributors
  ),
  mapped AS (
    SELECT
      pr.user_id,
      me.axis,
      me.delta,
      me.weight
    FROM public.preference_responses pr
    JOIN contributors c
      ON c.user_id = pr.user_id
    JOIN public.house_vibe_mapping_effects me
      ON me.mapping_version = v_mapping_version
     AND me.preference_id = pr.preference_id
     AND me.option_index = pr.option_index
  ),
  member_axis AS (
    SELECT
      user_id,
      axis,
      CASE
        WHEN SUM(weight) = 0 THEN NULL
        ELSE (SUM((delta::numeric) * weight) / SUM(weight))
      END AS score
    FROM mapped
    GROUP BY user_id, axis
  ),
  member_votes AS (
    SELECT
      axis,
      user_id,
      score,
      CASE
        WHEN score IS NULL THEN 'none'
        WHEN score > 0.20 THEN 'high'
        WHEN score < -0.20 THEN 'low'
        ELSE 'neutral'
      END AS vote
    FROM member_axis
  ),
  axis_counts AS (
    SELECT
      axis,
      COUNT(*) FILTER (WHERE vote = 'high')    AS high_n,
      COUNT(*) FILTER (WHERE vote = 'low')     AS low_n,
      COUNT(*) FILTER (WHERE vote = 'neutral') AS neutral_n,
      COUNT(*) FILTER (WHERE vote <> 'none')   AS contributed_n,
      AVG(score)                               AS score_avg
    FROM member_votes
    GROUP BY axis
  ),
  axis_resolved AS (
    SELECT
      ac.axis,
      ac.high_n,
      ac.low_n,
      ac.neutral_n,
      ac.contributed_n,
      ac.score_avg,
      CASE
        WHEN ac.high_n >= v_min_side AND ac.low_n >= v_min_side THEN 'mixed'
        WHEN ac.high_n >= v_min_side AND ac.high_n > ac.low_n THEN 'leans_high'
        WHEN ac.low_n  >= v_min_side AND ac.low_n  > ac.high_n THEN 'leans_low'
        ELSE 'balanced'
      END AS lean,
      LEAST(
        1,
        GREATEST(
          0,
          -- contributors-only coverage term:
          (ac.contributed_n::numeric / NULLIF((SELECT n FROM contributed_count), 0)::numeric)
          *
          -- imbalance term (includes neutrals in denominator):
          (CASE
             WHEN (ac.high_n + ac.low_n + ac.neutral_n) = 0 THEN 0
             ELSE (ABS(ac.high_n - ac.low_n)::numeric / (ac.high_n + ac.low_n + ac.neutral_n)::numeric)
           END)
        )
      ) AS confidence
    FROM axis_counts ac
  )
  SELECT
    (SELECT n FROM contributed_count) AS contributed_n,
    COALESCE(
      jsonb_object_agg(
        ar.axis,
        jsonb_build_object(
          'lean', ar.lean,
          'score', ROUND(COALESCE(ar.score_avg, 0)::numeric, 3),
          'confidence', ROUND(COALESCE(ar.confidence, 0)::numeric, 3),
          'counts', jsonb_build_object(
            'high', COALESCE(ar.high_n, 0),
            'low', COALESCE(ar.low_n, 0),
            'neutral', COALESCE(ar.neutral_n, 0),
            'contributed', COALESCE(ar.contributed_n, 0),
            'contributors_total', (SELECT n FROM contributed_count),
            'total_members', v_total
          )
        )
      ) FILTER (WHERE ar.axis IS NOT NULL),
      '{}'::jsonb
    ) AS axes_json
  INTO v_contributed, v_axes
  FROM axis_resolved ar;

  v_contributed := COALESCE(v_contributed, 0);
  v_axes := COALESCE(v_axes, '{}'::jsonb);

  -- coverage ratio for label gating remains contributor share of total members
  IF v_total > 0 THEN
    v_ratio := (v_contributed::numeric / v_total::numeric);
  ELSE
    v_ratio := 0;
  END IF;

  --------------------------------------------------------------------
  -- Extract axis lean/conf from v_axes JSON
  --------------------------------------------------------------------
  v_energy_lean := COALESCE(v_axes #>> '{energy_level,lean}', 'balanced');
  v_energy_conf := COALESCE((v_axes #>> '{energy_level,confidence}')::numeric, 0);

  v_structure_lean := COALESCE(v_axes #>> '{structure_level,lean}', 'balanced');
  v_structure_conf := COALESCE((v_axes #>> '{structure_level,confidence}')::numeric, 0);

  v_social_lean := COALESCE(v_axes #>> '{social_level,lean}', 'balanced');
  v_social_conf := COALESCE((v_axes #>> '{social_level,confidence}')::numeric, 0);

  v_repair_lean := COALESCE(v_axes #>> '{repair_style,lean}', 'balanced');
  v_repair_conf := COALESCE((v_axes #>> '{repair_style,confidence}')::numeric, 0);

  v_noise_lean := COALESCE(v_axes #>> '{noise_tolerance,lean}', 'balanced');
  v_noise_conf := COALESCE((v_axes #>> '{noise_tolerance,confidence}')::numeric, 0);

  v_clean_lean := COALESCE(v_axes #>> '{cleanliness_rhythm,lean}', 'balanced');
  v_clean_conf := COALESCE((v_axes #>> '{cleanliness_rhythm,confidence}')::numeric, 0);

  --------------------------------------------------------------------
  -- Deterministic resolution
  --------------------------------------------------------------------
  IF v_total = 0
     OR v_contributed < 2
     OR v_ratio < 0.4
  THEN
    v_label_id := 'insufficient_data';
    v_label_conf := CASE WHEN v_total = 0 THEN 0 ELSE v_ratio END;

  ELSE
    -- Any axis in 'mixed' -> mixed_home
    IF v_energy_lean = 'mixed'
       OR v_structure_lean = 'mixed'
       OR v_social_lean = 'mixed'
       OR v_repair_lean = 'mixed'
       OR v_noise_lean = 'mixed'
       OR v_clean_lean = 'mixed'
    THEN
      v_label_id := 'mixed_home';

      v_label_conf := 1;
      IF v_energy_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_energy_conf); END IF;
      IF v_structure_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_structure_conf); END IF;
      IF v_social_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_social_conf); END IF;
      IF v_repair_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_repair_conf); END IF;
      IF v_noise_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_noise_conf); END IF;
      IF v_clean_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_clean_conf); END IF;

    ELSE
      v_best_score := -1;
      v_best_label := NULL;

      -- --------------------------------------------------------------
      -- SOCIAL VARIANTS (close holes where social is high but energy/noise aren't)
      -- --------------------------------------------------------------

      -- cozy_social_home: social high + (energy low OR noise low)
      IF v_social_lean = 'leans_high'
         AND (v_energy_lean = 'leans_low' OR v_noise_lean = 'leans_low')
      THEN
        SELECT AVG(x)::numeric
          INTO v_candidate_score
        FROM (VALUES
          (v_social_conf),
          (CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf END),
          (CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf END)
        ) t(x)
        WHERE x IS NOT NULL;

        IF v_candidate_score IS NOT NULL AND v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'cozy_social_home';
        END IF;
      END IF;

      -- social_home: social high + energy high
      IF v_social_lean = 'leans_high' AND v_energy_lean = 'leans_high' THEN
        v_candidate_score := (v_social_conf + v_energy_conf) / 2;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'social_home';
        END IF;
      END IF;

      -- warm_social_home: social high + energy not high
      IF v_social_lean = 'leans_high'
         AND v_energy_lean <> 'leans_high'
      THEN
        v_candidate_score := v_social_conf;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'warm_social_home';
        END IF;
      END IF;

      -- --------------------------------------------------------------
      -- STRUCTURE / EASE
      -- --------------------------------------------------------------

      -- structured_home
      IF v_structure_lean = 'leans_high' AND v_clean_lean = 'leans_high' THEN
        v_candidate_score := (v_structure_conf + v_clean_conf) / 2;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'structured_home';
        END IF;
      END IF;

      -- easygoing_home
      IF (v_structure_lean = 'leans_low' OR v_clean_lean = 'leans_low')
         AND NOT (v_noise_lean = 'leans_low')
      THEN
        v_candidate_score := (v_structure_conf + v_clean_conf + v_noise_conf) / 3;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'easygoing_home';
        END IF;
      END IF;

      -- --------------------------------------------------------------
      -- INDEPENDENCE / QUIET CARE
      -- --------------------------------------------------------------

      -- independent_home
      IF v_social_lean = 'leans_low'
         AND (v_structure_lean = 'balanced' OR v_structure_lean = 'leans_high')
      THEN
        v_candidate_score := (v_social_conf + v_structure_conf) / 2;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'independent_home';
        END IF;
      END IF;

      -- quiet_care_home: (energy low OR noise low) AND social not high
      IF (v_energy_lean = 'leans_low' OR v_noise_lean = 'leans_low')
         AND NOT (v_social_lean = 'leans_high')
      THEN
        SELECT AVG(x)::numeric
          INTO v_candidate_score
        FROM (VALUES
          (CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf END),
          (CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf END),
          (CASE WHEN v_social_lean <> 'leans_high' THEN v_social_conf END)
        ) t(x)
        WHERE x IS NOT NULL;

        IF v_candidate_score IS NOT NULL AND v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'quiet_care_home';
        END IF;
      END IF;

      -- --------------------------------------------------------------
      -- steady_home: social balanced + not structured/easygoing + action signals
      -- (lets repair/clean contribute without dominating the whole taxonomy)
      -- --------------------------------------------------------------
      IF v_social_lean = 'balanced'
         AND v_energy_lean <> 'leans_low'
         AND v_noise_lean <> 'leans_low'
         AND v_structure_lean <> 'leans_high'   -- avoids structured-like emphasis
         AND v_structure_lean <> 'leans_low'    -- avoids easygoing via structure low
         AND v_clean_lean <> 'leans_low'        -- avoids easygoing via clean low
         AND (v_clean_lean = 'leans_high' OR v_repair_lean = 'leans_high')
      THEN
        SELECT AVG(x)::numeric
          INTO v_candidate_score
        FROM (VALUES
          (v_social_conf),
          (CASE WHEN v_clean_lean = 'leans_high' THEN v_clean_conf END),
          (CASE WHEN v_repair_lean = 'leans_high' THEN v_repair_conf END)
        ) t(x)
        WHERE x IS NOT NULL;

        IF v_candidate_score IS NOT NULL AND v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'steady_home';
        END IF;
      END IF;

      -- Finalize label
      IF v_best_label IS NULL THEN
        v_label_id := 'default_home';
        v_label_conf := CASE WHEN v_total = 0 THEN 0 ELSE v_ratio END;
      ELSE
        v_label_id := v_best_label;

        -- Confidence per label (min/least of contributing axes)
        IF v_label_id = 'cozy_social_home' THEN
          v_label_conf := LEAST(
            v_social_conf,
            CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf ELSE 1 END,
            CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf  ELSE 1 END
          );

        ELSIF v_label_id = 'social_home' THEN
          v_label_conf := LEAST(v_social_conf, v_energy_conf);

        ELSIF v_label_id = 'warm_social_home' THEN
          v_label_conf := v_social_conf;

        ELSIF v_label_id = 'structured_home' THEN
          v_label_conf := LEAST(v_structure_conf, v_clean_conf);

        ELSIF v_label_id = 'easygoing_home' THEN
          v_label_conf := LEAST(v_structure_conf, LEAST(v_clean_conf, v_noise_conf));

        ELSIF v_label_id = 'independent_home' THEN
          v_label_conf := LEAST(v_social_conf, v_structure_conf);

        ELSIF v_label_id = 'quiet_care_home' THEN
          SELECT LEAST(1, GREATEST(0, MIN(x)))::numeric
            INTO v_label_conf
          FROM (VALUES
            (CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf END),
            (CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf END),
            (CASE WHEN v_social_lean <> 'leans_high' THEN v_social_conf END)
          ) t(x)
          WHERE x IS NOT NULL;

        ELSIF v_label_id = 'steady_home' THEN
          SELECT LEAST(1, GREATEST(0, MIN(x)))::numeric
            INTO v_label_conf
          FROM (VALUES
            (v_social_conf),
            (CASE WHEN v_clean_lean = 'leans_high' THEN v_clean_conf END),
            (CASE WHEN v_repair_lean = 'leans_high' THEN v_repair_conf END)
          ) t(x)
          WHERE x IS NOT NULL;

        ELSE
          v_label_id := 'default_home';
          v_label_conf := CASE WHEN v_total = 0 THEN 0 ELSE v_ratio END;
        END IF;

        v_label_conf := LEAST(1, GREATEST(0, COALESCE(v_label_conf, 0)));
      END IF;
    END IF;
  END IF;

  -- single source of truth (cache + compute)
  v_confidence_kind := public._house_vibe_confidence_kind(v_label_id);

  --------------------------------------------------------------------
  -- Persist snapshot (Model B upsert on (home_id, mapping_version))
  --------------------------------------------------------------------
  INSERT INTO public.house_vibes (
    home_id,
    mapping_version,
    label_id,
    confidence,
    coverage_answered,
    coverage_total,
    axes,
    computed_at,
    out_of_date,
    invalidated_at
  )
  VALUES (
    p_home_id,
    v_mapping_version,
    v_label_id,
    v_label_conf,
    v_contributed,
    v_total,
    COALESCE(v_axes, '{}'::jsonb),
    v_now,
    false,
    NULL
  )
  ON CONFLICT (home_id, mapping_version) DO UPDATE
    SET label_id          = EXCLUDED.label_id,
        confidence        = EXCLUDED.confidence,
        coverage_answered = EXCLUDED.coverage_answered,
        coverage_total    = EXCLUDED.coverage_total,
        axes              = EXCLUDED.axes,
        computed_at       = EXCLUDED.computed_at,
        out_of_date       = false,
        invalidated_at    = NULL;

  --------------------------------------------------------------------
  -- Presentation join
  --------------------------------------------------------------------
  SELECT title_key, summary_key, image_key, ui
    INTO v_label_title_key, v_label_summary_key, v_label_image_key, v_label_ui
  FROM public.house_vibe_labels
  WHERE mapping_version = v_mapping_version
    AND label_id = v_label_id
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'source', 'computed',
    'home_id', p_home_id,
    'mapping_version', v_mapping_version,
    'label_id', v_label_id,
    'confidence', v_label_conf,
    'confidence_kind', v_confidence_kind,
    'coverage', jsonb_build_object('answered', v_contributed, 'total', v_total),
    'coverage_ratio', ROUND(v_ratio, 3),
    'computed_at', v_now,
    'presentation', jsonb_build_object(
      'title_key', v_label_title_key,
      'summary_key', v_label_summary_key,
      'image_key', v_label_image_key,
      'ui', COALESCE(v_label_ui, '{}'::jsonb)
    ),
    'axes', CASE WHEN p_include_axes THEN COALESCE(v_axes, '{}'::jsonb) ELSE '{}'::jsonb END
  );
END;
$$;
