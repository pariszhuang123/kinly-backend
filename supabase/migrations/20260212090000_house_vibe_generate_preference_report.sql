-- House Vibe v1 backend schema (labels, mapping effects, snapshot cache, triggers, RPC stub)
-- Full adjusted code per latest decisions:
-- - memberships is_current is GENERATED from valid_to; "rejoin" = INSERT new row, UPDATE only closes row (valid_to NULL->NOT NULL)
-- - One current home per user is enforced by uq_memberships_user_one_current (provided)
-- - Temporary helpers do NOT count toward house vibe (and with one-current-home invariant, they should NOT be represented as is_current memberships)
-- - Keep computed_at behavior as-is (it updates on invalidation), but ADD invalidated_at timestamptz
-- - Prefix hot-path indexes with feature name
-- - Axis remains text + CHECK, coarse hand-authored weights
-- - Use provided _touch_updated_at() trigger on house_vibe_labels
-- - Share tracking Option 1 only: feature='house_vibe'

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -------------------------------------------------------------------
-- Versions
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.house_vibe_versions (
  mapping_version        text PRIMARY KEY,
  min_side_count_small   int NOT NULL DEFAULT 1, -- when coverage_total <= 3
  min_side_count_large   int NOT NULL DEFAULT 2, -- when coverage_total >= 4
  status                text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active')),
  created_at            timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.house_vibe_versions (mapping_version, min_side_count_small, min_side_count_large, status)
VALUES ('v1', 1, 2, 'active')
ON CONFLICT (mapping_version) DO NOTHING;

-- -------------------------------------------------------------------
-- Label registry (presentation) ✅ version-safe PK
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.house_vibe_labels (
  label_id        text NOT NULL,
  mapping_version text NOT NULL REFERENCES public.house_vibe_versions(mapping_version),
  title_key       text NOT NULL,
  summary_key     text NOT NULL,
  image_key       text NOT NULL,
  ui              jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active       boolean NOT NULL DEFAULT true,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_house_vibe_labels PRIMARY KEY (mapping_version, label_id)
);

INSERT INTO public.house_vibe_labels (label_id, mapping_version, title_key, summary_key, image_key, ui)
VALUES
  ('insufficient_data', 'v1', 'vibe.insufficient.title', 'vibe.insufficient.summary', 'vibe_insufficient_v1', '{"badge_token":"info"}'),
  ('mixed_home',        'v1', 'vibe.mixed.title',         'vibe.mixed.summary',         'vibe_mixed_v1',         '{"badge_token":"varied"}'),
  ('default_home',      'v1', 'vibe.default.title',       'vibe.default.summary',       'vibe_default_v1',       '{"badge_token":"calm"}'),
  ('quiet_care_home',   'v1', 'vibe.quietCare.title',     'vibe.quietCare.summary',     'vibe_quiet_care_v1',    '{"accent_token":"tealBrand","badge_token":"calm"}'),
  ('social_home',       'v1', 'vibe.social.title',        'vibe.social.summary',        'vibe_social_v1',        '{"accent_token":"pinkJoy","badge_token":"social"}'),
  ('structured_home',   'v1', 'vibe.structured.title',    'vibe.structured.summary',    'vibe_structured_v1',    '{"accent_token":"blueFocus","badge_token":"structured"}'),
  ('easygoing_home',    'v1', 'vibe.easygoing.title',     'vibe.easygoing.summary',     'vibe_easygoing_v1',     '{"accent_token":"yellowWarmth","badge_token":"ease"}'),
  ('independent_home',  'v1', 'vibe.independent.title',   'vibe.independent.summary',   'vibe_independent_v1',   '{"accent_token":"slate","badge_token":"quiet"}')
ON CONFLICT (mapping_version, label_id) DO NOTHING;

-- -------------------------------------------------------------------
-- Touch updated_at trigger (provided)
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_house_vibe_labels_touch_updated_at ON public.house_vibe_labels;
CREATE TRIGGER trg_house_vibe_labels_touch_updated_at
BEFORE UPDATE ON public.house_vibe_labels
FOR EACH ROW
EXECUTE FUNCTION public._touch_updated_at();

-- -------------------------------------------------------------------
-- Mapping effects (pref_id → axis deltas)
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.house_vibe_mapping_effects (
  mapping_version text NOT NULL REFERENCES public.house_vibe_versions(mapping_version),
  preference_id   text NOT NULL REFERENCES public.preference_taxonomy(preference_id),
  option_index    smallint NOT NULL CHECK (option_index BETWEEN 0 AND 2),
  axis            text NOT NULL CHECK (axis IN (
    'energy_level',
    'structure_level',
    'social_level',
    'repair_style',
    'noise_tolerance',
    'cleanliness_rhythm'
  )),
  delta           smallint NOT NULL CHECK (delta IN (-1, 0, 1)),
  weight          numeric(4,2) NOT NULL CHECK (weight >= 0.10 AND weight <= 3.00),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_house_vibe_mapping_effects PRIMARY KEY (mapping_version, preference_id, option_index, axis)
);

INSERT INTO public.house_vibe_mapping_effects (mapping_version, preference_id, option_index, axis, delta, weight)
VALUES
  -- environment_noise_tolerance
  ('v1','environment_noise_tolerance',0,'noise_tolerance',-1,1.25),
  ('v1','environment_noise_tolerance',0,'energy_level',   -1,0.40),
  ('v1','environment_noise_tolerance',2,'noise_tolerance', 1,1.25),
  ('v1','environment_noise_tolerance',2,'energy_level',    1,0.40),
  -- environment_light_preference
  ('v1','environment_light_preference',0,'energy_level',-1,0.40),
  ('v1','environment_light_preference',2,'energy_level', 1,0.40),
  -- environment_scent_sensitivity
  ('v1','environment_scent_sensitivity',0,'cleanliness_rhythm',-1,0.50),
  ('v1','environment_scent_sensitivity',2,'cleanliness_rhythm', 1,0.50),
  -- schedule_quiet_hours_preference
  ('v1','schedule_quiet_hours_preference',0,'noise_tolerance',-1,1.00),
  ('v1','schedule_quiet_hours_preference',1,'noise_tolerance',-1,0.60),
  ('v1','schedule_quiet_hours_preference',2,'noise_tolerance', 1,1.00),
  -- schedule_sleep_timing
  ('v1','schedule_sleep_timing',0,'energy_level',-1,1.00),
  ('v1','schedule_sleep_timing',2,'energy_level', 1,1.00),
  -- communication_channel
  ('v1','communication_channel',0,'social_level',-1,0.50),
  ('v1','communication_channel',1,'social_level', 1,0.30),
  ('v1','communication_channel',2,'social_level', 1,0.80),
  -- communication_directness
  ('v1','communication_directness',0,'repair_style',-1,1.10),
  ('v1','communication_directness',1,'repair_style', 0,0.60),
  ('v1','communication_directness',2,'repair_style', 1,1.10),
  -- cleanliness_shared_space_tolerance
  ('v1','cleanliness_shared_space_tolerance',0,'cleanliness_rhythm',-1,1.30),
  ('v1','cleanliness_shared_space_tolerance',2,'cleanliness_rhythm', 1,1.30),
  -- privacy_room_entry
  ('v1','privacy_room_entry',0,'social_level',-1,0.80),
  ('v1','privacy_room_entry',1,'social_level',-1,0.40),
  ('v1','privacy_room_entry',2,'social_level', 1,0.80),
  -- privacy_notifications
  ('v1','privacy_notifications',0,'social_level',-1,0.60),
  ('v1','privacy_notifications',1,'social_level',-1,0.30),
  ('v1','privacy_notifications',2,'social_level', 1,0.60),
  -- social_hosting_frequency
  ('v1','social_hosting_frequency',0,'social_level',-1,1.10),
  ('v1','social_hosting_frequency',0,'energy_level',-1,0.60),
  ('v1','social_hosting_frequency',1,'social_level', 1,0.50),
  ('v1','social_hosting_frequency',2,'social_level', 1,1.10),
  ('v1','social_hosting_frequency',2,'energy_level', 1,0.60),
  -- social_togetherness
  ('v1','social_togetherness',0,'social_level',-1,1.20),
  ('v1','social_togetherness',2,'social_level', 1,1.20),
  -- routine_planning_style
  ('v1','routine_planning_style',0,'structure_level',-1,1.30),
  ('v1','routine_planning_style',2,'structure_level', 1,1.30),
  -- conflict_resolution_style
  ('v1','conflict_resolution_style',0,'repair_style',-1,1.00),
  ('v1','conflict_resolution_style',1,'repair_style', 0,0.60),
  ('v1','conflict_resolution_style',2,'repair_style', 1,1.00)
ON CONFLICT DO NOTHING;

-- -------------------------------------------------------------------
-- Snapshot cache (+ invalidated_at) ✅
-- -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.house_vibes (
  home_id           uuid PRIMARY KEY REFERENCES public.homes(id) ON DELETE CASCADE,
  mapping_version   text NOT NULL REFERENCES public.house_vibe_versions(mapping_version),
  label_id          text NOT NULL,
  confidence        numeric NOT NULL,
  coverage_answered int NOT NULL,
  coverage_total    int NOT NULL,
  axes              jsonb NOT NULL DEFAULT '{}'::jsonb,
  computed_at       timestamptz NOT NULL DEFAULT now(),
  out_of_date       boolean NOT NULL DEFAULT false,
  invalidated_at    timestamptz NULL,
  CONSTRAINT chk_house_vibes_confidence_0_1 CHECK (confidence >= 0 AND confidence <= 1),
  CONSTRAINT chk_house_vibes_coverage_nonneg CHECK (coverage_answered >= 0 AND coverage_total >= 0),
  CONSTRAINT chk_house_vibes_coverage_order CHECK (coverage_answered <= coverage_total),
  CONSTRAINT fk_house_vibes_label_version
    FOREIGN KEY (mapping_version, label_id)
    REFERENCES public.house_vibe_labels(mapping_version, label_id)
);

-- If the table already existed before invalidated_at was added in CREATE TABLE:
ALTER TABLE public.house_vibes
ADD COLUMN IF NOT EXISTS invalidated_at timestamptz NULL;

-- -------------------------------------------------------------------
-- RLS + grants (RPC/service-role only)
-- -------------------------------------------------------------------
ALTER TABLE public.house_vibe_versions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.house_vibe_labels          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.house_vibe_mapping_effects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.house_vibes                ENABLE ROW LEVEL SECURITY;

-- No policies: direct table access is blocked by RLS and REVOKE below.

REVOKE ALL ON public.house_vibe_versions        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.house_vibe_labels          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.house_vibe_mapping_effects FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.house_vibes                FROM PUBLIC, anon, authenticated;

GRANT ALL ON public.house_vibe_versions        TO service_role;
GRANT ALL ON public.house_vibe_labels          TO service_role;
GRANT ALL ON public.house_vibe_mapping_effects TO service_role;
GRANT ALL ON public.house_vibes                TO service_role;

-- -------------------------------------------------------------------
-- Performance: hot-path partial indexes for invalidation triggers ✅
-- Note: uq_memberships_user_one_current already exists in your schema and covers (user_id) WHERE is_current.
-- We keep a feature-prefixed index name for readability; this one may be redundant, but harmless.
-- The (home_id) current index is still useful because you only have a unique owner-current index, not a general home-current index.
-- -------------------------------------------------------------------
DROP INDEX IF EXISTS public.memberships_home_current_idx;
DROP INDEX IF EXISTS public.memberships_user_current_idx;

CREATE INDEX IF NOT EXISTS house_vibe_memberships_home_current_idx
ON public.memberships(home_id)
WHERE is_current = true;

-- Optional / likely redundant with uq_memberships_user_one_current, but keeps query plans stable if you ever change that unique index:
CREATE INDEX IF NOT EXISTS house_vibe_memberships_user_current_idx
ON public.memberships(user_id)
WHERE is_current = true;

-- -------------------------------------------------------------------
-- Out-of-date helper (UPSERT-safe + known-safe placeholder) ✅
-- - Keeps your computed_at behavior (updates on invalidation, as requested)
-- - Adds invalidated_at = now()
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._house_vibes_mark_out_of_date(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total int;
  v_mapping_version text := 'v1';
BEGIN
  SELECT COUNT(*)
    INTO v_total
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current = true;

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
    'insufficient_data',
    0,
    0,
    COALESCE(v_total, 0),
    '{}'::jsonb,
    now(),
    true,
    now()
  )
  ON CONFLICT (home_id) DO UPDATE
    SET out_of_date       = true,
        mapping_version   = EXCLUDED.mapping_version,
        label_id          = EXCLUDED.label_id,
        confidence        = EXCLUDED.confidence,
        coverage_answered = EXCLUDED.coverage_answered,
        coverage_total    = EXCLUDED.coverage_total,
        axes              = EXCLUDED.axes,
        computed_at       = EXCLUDED.computed_at,
        invalidated_at    = EXCLUDED.invalidated_at;
END;
$$;

-- -------------------------------------------------------------------
-- Membership invalidation trigger (meaningful changes only)
-- memberships.is_current is GENERATED from valid_to; treat valid_to transitions as current-set changes.
-- ✅ TG_OP-safe OLD/NEW usage
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._house_vibes_mark_out_of_date_memberships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old_home uuid := null;
  v_new_home uuid := null;
  v_should_invalidate boolean := false;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new_home := NEW.home_id;

    -- Only if inserted row is current.
    IF NEW.valid_to IS NULL THEN
      v_should_invalidate := true;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    v_old_home := OLD.home_id;

    -- Only if deleted row was current.
    IF OLD.valid_to IS NULL THEN
      v_should_invalidate := true;
    END IF;

  ELSE
    -- UPDATE
    v_old_home := OLD.home_id;
    v_new_home := NEW.home_id;

    -- 1) current -> not current (leave/kick): valid_to NULL -> NOT NULL
    IF OLD.valid_to IS NULL AND NEW.valid_to IS NOT NULL THEN
      v_should_invalidate := true;
    END IF;

    -- 2) valid_from changed (rare, but affects validity window)
    IF OLD.valid_from IS DISTINCT FROM NEW.valid_from THEN
      v_should_invalidate := true;
    END IF;

    -- 3) role changed (owner transfer etc.) – only matters for current row
    IF NEW.valid_to IS NULL AND OLD.role IS DISTINCT FROM NEW.role THEN
      v_should_invalidate := true;
    END IF;

    -- 4) home_id changed (rare) – invalidate both homes
    IF OLD.home_id IS DISTINCT FROM NEW.home_id THEN
      v_should_invalidate := true;
    END IF;
  END IF;

  IF v_should_invalidate THEN
    IF v_old_home IS NOT NULL THEN
      PERFORM public._house_vibes_mark_out_of_date(v_old_home);
    END IF;

    IF v_new_home IS NOT NULL AND v_new_home IS DISTINCT FROM v_old_home THEN
      PERFORM public._house_vibes_mark_out_of_date(v_new_home);
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_house_vibes_memberships_out_of_date ON public.memberships;
CREATE TRIGGER trg_house_vibes_memberships_out_of_date
AFTER INSERT OR UPDATE OR DELETE ON public.memberships
FOR EACH ROW
EXECUTE FUNCTION public._house_vibes_mark_out_of_date_memberships();

-- -------------------------------------------------------------------
-- Preference invalidation trigger (home-scoped via "one current home per user")
-- preference_responses are globally stored, but house_vibe uses the user's current membership.
-- ✅ handles DELETE + TG_OP-safe OLD/NEW usage
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._house_vibes_mark_out_of_date_preferences()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
  v_user_id uuid := null;
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    v_user_id := NEW.user_id;
  ELSIF TG_OP = 'DELETE' THEN
    v_user_id := OLD.user_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- One current home per user is enforced by uq_memberships_user_one_current (provided).
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user_id
     AND m.is_current = true
   LIMIT 1;

  IF v_home_id IS NOT NULL THEN
    PERFORM public._house_vibes_mark_out_of_date(v_home_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_house_vibes_preference_responses_out_of_date ON public.preference_responses;
CREATE TRIGGER trg_house_vibes_preference_responses_out_of_date
AFTER INSERT OR UPDATE OR DELETE ON public.preference_responses
FOR EACH ROW
EXECUTE FUNCTION public._house_vibes_mark_out_of_date_preferences();

-- -------------------------------------------------------------------
-- Function permissions (no direct access for clients)
-- -------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._house_vibes_mark_out_of_date(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_vibes_mark_out_of_date_memberships() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_vibes_mark_out_of_date_preferences() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._house_vibes_mark_out_of_date(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._house_vibes_mark_out_of_date_memberships() TO service_role;
GRANT EXECUTE ON FUNCTION public._house_vibes_mark_out_of_date_preferences() TO service_role;

-- -------------------------------------------------------------------
-- RPC stub: house_vibe_compute (logic to be implemented per contract)
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.house_vibe_compute(
  p_home_id uuid,
  p_force boolean DEFAULT false,
  p_include_axes boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- TODO: implement aggregation + mapping per contracts:
  -- - house_vibe_aggregation_contract_v1.md
  -- - house_vibe_mapping_contract_v1.md
  -- Must take advisory lock per (home_id, mapping_version).
  -- Must join house_vibe_labels to return render-ready payload.
  -- Should set out_of_date=false and invalidated_at=NULL when snapshot is refreshed.
  RAISE EXCEPTION 'house_vibe_compute not yet implemented';
END;
$$;

REVOKE ALL ON FUNCTION public.house_vibe_compute(uuid, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.house_vibe_compute(uuid, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.house_vibe_compute(uuid, boolean, boolean) TO service_role;

-- ===================================================================
-- Share tracking: Option 1 only
-- - You share the summary card + image as ONE event => use feature='house_vibe'
-- ===================================================================

ALTER TABLE public.share_events
DROP CONSTRAINT IF EXISTS share_feature_valid;

ALTER TABLE public.share_events
ADD CONSTRAINT share_feature_valid CHECK (
  feature = ANY (
    ARRAY[
      'invite_button'::text,
      'invite_housemate'::text,
      'gratitude_wall_house'::text,
      'gratitude_wall_personal'::text,
      'house_rules_detailed'::text,
      'house_rules_summary'::text,
      'preferences_detailed'::text,
      'preferences_summary'::text,
      'house_vibe'::text,
      'other'::text
    ]
  )
);

-- No RPC change needed for Option 1.
-- From the client, log:
--   share_log_event(p_home_id := <home_id>, p_feature := 'house_vibe', p_channel := 'system_share' | 'copy_link' | ...)

CREATE OR REPLACE FUNCTION public.preference_reports_generate(
  p_template_key text,
  p_locale text,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();

  v_template public.preference_report_templates%ROWTYPE;
  v_report public.preference_reports%ROWTYPE;

  v_all_pref_ids text[];
  v_answered_pref_ids text[];

  v_responses jsonb;
  v_resolved jsonb;

  v_unresolved_missing jsonb;
  v_unresolved_nulls jsonb;
  v_unresolved jsonb;

  v_sections jsonb;

  v_generated jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  -- normalize to base locale for templates/reports
  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  -- Collision-safe advisory lock per (user, key, locale)
  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_user::text || ':' || p_template_key || ':' || p_locale, 0)
  );

  SELECT *
    INTO v_template
  FROM public.preference_report_templates t
  WHERE t.template_key = p_template_key
    AND t.locale = p_locale
  LIMIT 1;

  IF v_template.id IS NULL THEN
    PERFORM public.api_error(
      'TEMPLATE_NOT_FOUND',
      'No preference report template found for the requested key/locale.',
      'P0001',
      jsonb_build_object('template_key', p_template_key, 'locale', p_locale)
    );
  END IF;

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = v_user
    AND r.template_key = p_template_key
    AND r.locale = p_locale
  LIMIT 1;

  IF v_report.id IS NOT NULL
     AND p_force = false
     AND v_report.status <> 'out_of_date' THEN
    RETURN jsonb_build_object('ok', true, 'report_id', v_report.id, 'status', 'unchanged');
  END IF;

  -- all_pref_ids := active taxonomy defs
  SELECT COALESCE(array_agg(t.preference_id ORDER BY t.preference_id), ARRAY[]::text[])
    INTO v_all_pref_ids
  FROM public.preference_taxonomy t
  JOIN public.preference_taxonomy_defs d USING (preference_id)
  WHERE t.is_active = true;

  PERFORM public.api_assert(
    COALESCE(array_length(v_all_pref_ids, 1), 0) > 0,
    'INVALID_TAXONOMY_STATE',
    'No active preference taxonomy defs exist; cannot generate report.',
    '22023'
  );

  -- answered_pref_ids := responses for user
  SELECT COALESCE(array_agg(pr.preference_id ORDER BY pr.preference_id), ARRAY[]::text[])
    INTO v_answered_pref_ids
  FROM public.preference_responses pr
  WHERE pr.user_id = v_user;

  -- responses/resolved for answered only
  WITH resolved_rows AS (
    SELECT
      pr.preference_id,
      pr.option_index,
      (v_template.body->'preferences'->pr.preference_id->(pr.option_index::int)) AS resolved_obj
    FROM public.preference_responses pr
    WHERE pr.user_id = v_user
  )
  SELECT
    COALESCE(jsonb_object_agg(preference_id, option_index), '{}'::jsonb),
    COALESCE(jsonb_object_agg(preference_id, resolved_obj), '{}'::jsonb),
    COALESCE(
      jsonb_agg(preference_id)
        FILTER (WHERE resolved_obj IS NULL OR resolved_obj = 'null'::jsonb),
      '[]'::jsonb
    )
  INTO v_responses, v_resolved, v_unresolved_nulls
  FROM resolved_rows;

  -- unresolved_missing := all_pref_ids EXCEPT answered_pref_ids
  SELECT COALESCE(
    jsonb_agg(x),
    '[]'::jsonb
  )
  INTO v_unresolved_missing
  FROM (
    SELECT unnest(v_all_pref_ids) AS x
    EXCEPT
    SELECT unnest(v_answered_pref_ids) AS x
  ) s;

  -- unresolved := union(missing, nulls), dedup
  SELECT COALESCE(
    jsonb_agg(DISTINCT e.value),
    '[]'::jsonb
  )
  INTO v_unresolved
  FROM jsonb_array_elements(v_unresolved_missing || v_unresolved_nulls) AS e(value);

  -- Build personalized section text from resolved preferences by domain.
  v_sections := v_template.body->'sections';

  WITH section_items AS (
    SELECT value AS section, ord
    FROM jsonb_array_elements(v_sections) WITH ORDINALITY AS e(value, ord)
  ),
  resolved_texts AS (
    SELECT
      d.domain,
      pr.preference_id,
      (v_template.body->'preferences'->pr.preference_id->(pr.option_index::int)->>'text') AS text
    FROM public.preference_responses pr
    JOIN public.preference_taxonomy t USING (preference_id)
    JOIN public.preference_taxonomy_defs d USING (preference_id)
    WHERE pr.user_id = v_user
      AND t.is_active = true
  ),
  per_domain AS (
    SELECT
      domain,
      string_agg(text, ' ' ORDER BY preference_id) AS section_text
    FROM resolved_texts
    WHERE text IS NOT NULL AND btrim(text) <> ''
    GROUP BY domain
  )
  SELECT COALESCE(
    jsonb_agg(
      CASE
        WHEN pd.section_text IS NULL OR btrim(pd.section_text) = '' THEN section
        ELSE jsonb_set(section, '{text}', to_jsonb(pd.section_text), true)
      END
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_sections
  FROM section_items si
  LEFT JOIN per_domain pd
    ON pd.domain = (si.section->>'section_key');

  v_generated := jsonb_build_object(
    'template_key', p_template_key,
    'locale', p_locale,
    'summary', v_template.body->'summary',
    'sections', v_sections,
    'responses', v_responses,
    'resolved', v_resolved,
    'unresolved_pref_ids', v_unresolved
  );

  INSERT INTO public.preference_reports (
    subject_user_id,
    template_key,
    locale,
    status,
    generated_content,
    published_content,
    generated_at,
    published_at
  ) VALUES (
    v_user,
    p_template_key,
    p_locale,
    'published',
    v_generated,
    v_generated,
    now(),
    now()
  )
  ON CONFLICT (subject_user_id, template_key, locale)
  DO UPDATE SET
    status            = 'published',
    generated_content = EXCLUDED.generated_content,
    generated_at      = EXCLUDED.generated_at,

    -- never-edited rule
    published_content =
      CASE
        WHEN public.preference_reports.last_edited_at IS NULL
          THEN EXCLUDED.published_content
        ELSE public.preference_reports.published_content
      END,

    published_at =
      CASE
        WHEN public.preference_reports.last_edited_at IS NULL
          THEN EXCLUDED.published_at
        ELSE public.preference_reports.published_at
      END
  RETURNING * INTO v_report;

  RETURN jsonb_build_object(
    'ok', true,
    'report_id', v_report.id,
    'status', 'generated',
    'unresolved_pref_ids', v_unresolved
  );
END;
$$;
