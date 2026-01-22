-- =====================================================================
-- Kinly · Preferences (Fresh schema, no versioning) — FULL ADJUSTED BLOCK
-- Canonical template schema:
--   template.body.preferences[pref_id] = array[3] of objects:
--     { value_key: text, title: text, text: text }
--
-- Key changes vs your last block:
-- - No ALTER/DO scaffolding (assumes nothing deployed yet)
-- - Fixed unresolved detection = taxonomy minus answered (plus JSON null safety)
-- - Enforced "complete all answers at one go" via preference_responses_submit(jsonb)
-- - Template validator returns rich error details (bad_shape, bad_option, mismatches)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 0) Helper primitives (self-contained)
-- ---------------------------------------------------------------------

-- Updated-at convenience trigger
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

-- ---------------------------------------------------------------------
-- 1) Taxonomy registry: authoritative list of preference IDs
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.preference_taxonomy (
  preference_id text PRIMARY KEY,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_taxonomy_preference_id_format
    CHECK (preference_id ~ '^[a-z0-9_]{1,64}$')
);

-- ---------------------------------------------------------------------
-- 2) Taxonomy definitions: canonical meanings + UI/aggregation metadata
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.preference_taxonomy_defs (
  preference_id text PRIMARY KEY
    REFERENCES public.preference_taxonomy(preference_id) ON DELETE CASCADE,

  domain        text NOT NULL,
  label         text NOT NULL DEFAULT '',
  description   text NOT NULL,

  -- length 3, where:
  -- value_keys[1] maps to option_index=0
  -- value_keys[2] maps to option_index=1
  -- value_keys[3] maps to option_index=2
  value_keys    text[] NOT NULL,

  aggregation   text NOT NULL DEFAULT 'mode',
  safety_notes  text[] NOT NULL DEFAULT ARRAY[]::text[],

  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_defs_domain_format
    CHECK (domain ~ '^[a-z0-9_]{1,32}$'),

  CONSTRAINT chk_defs_value_keys_len_3
    CHECK (array_length(value_keys, 1) = 3),

  CONSTRAINT chk_defs_value_keys_each_format
    CHECK (
      value_keys[1] ~ '^[a-z0-9_]{1,64}$' AND
      value_keys[2] ~ '^[a-z0-9_]{1,64}$' AND
      value_keys[3] ~ '^[a-z0-9_]{1,64}$'
    )
);

CREATE INDEX IF NOT EXISTS idx_preference_taxonomy_defs_domain
  ON public.preference_taxonomy_defs (domain);

DROP TRIGGER IF EXISTS trg_preference_taxonomy_defs_touch
  ON public.preference_taxonomy_defs;

CREATE TRIGGER trg_preference_taxonomy_defs_touch
BEFORE UPDATE ON public.preference_taxonomy_defs
FOR EACH ROW
EXECUTE FUNCTION public._touch_updated_at();

-- ---------------------------------------------------------------------
-- 3) View: active defs for UI discovery
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.preference_taxonomy_active_defs AS
SELECT
  t.preference_id,
  d.domain,
  d.label,
  d.description,
  d.value_keys,
  d.aggregation,
  d.safety_notes
FROM public.preference_taxonomy t
JOIN public.preference_taxonomy_defs d USING (preference_id)
WHERE t.is_active = true;

-- ---------------------------------------------------------------------
-- 3.1) Seed taxonomy + defs (v1 contract)
-- ---------------------------------------------------------------------
INSERT INTO public.preference_taxonomy (preference_id, is_active)
VALUES
  ('environment_noise_tolerance', true),
  ('environment_light_preference', true),
  ('environment_scent_sensitivity', true),
  ('schedule_quiet_hours_preference', true),
  ('schedule_sleep_timing', true),
  ('communication_channel', true),
  ('communication_directness', true),
  ('cleanliness_shared_space_tolerance', true),
  ('privacy_room_entry', true),
  ('privacy_notifications', true),
  ('social_hosting_frequency', true),
  ('social_togetherness', true),
  ('routine_planning_style', true),
  ('conflict_resolution_style', true)
ON CONFLICT (preference_id) DO UPDATE
  SET is_active = EXCLUDED.is_active;

INSERT INTO public.preference_taxonomy_defs (
  preference_id, domain, label, description, value_keys, aggregation, safety_notes
)
VALUES
  (
    'environment_noise_tolerance',
    'environment',
    'Noise tolerance',
    'Comfort with ambient noise in shared spaces.',
    ARRAY['low','medium','high'],
    'mode_distribution',
    ARRAY[]::text[]
  ),
  (
    'environment_light_preference',
    'environment',
    'Light preference',
    'Lighting comfort in shared spaces.',
    ARRAY['dim','balanced','bright'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'environment_scent_sensitivity',
    'environment',
    'Scent sensitivity',
    'Sensitivity to strong scents (cleaners, candles).',
    ARRAY['sensitive','neutral','tolerant'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'schedule_quiet_hours_preference',
    'schedule',
    'Quiet hours',
    'Preferred quiet time window for the individual.',
    ARRAY['early_evening','late_evening_or_night','none'],
    'distribution',
    ARRAY['do_not_expose_exact_hours_in_vibe']
  ),
  (
    'schedule_sleep_timing',
    'schedule',
    'Sleep timing',
    'When the person typically sleeps.',
    ARRAY['early','standard','late'],
    'mode_range',
    ARRAY['aggregate_only_avoid_singling_out']
  ),
  (
    'communication_channel',
    'communication',
    'Preferred channel',
    'Preferred coordination channel.',
    ARRAY['text','call','in_person'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'communication_directness',
    'communication',
    'Directness',
    'Comfort with direct feedback vs. soft framing.',
    ARRAY['gentle','balanced','direct'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'cleanliness_shared_space_tolerance',
    'cleanliness',
    'Shared-space tidiness',
    'Tolerance for clutter in shared areas.',
    ARRAY['low','medium','high'],
    'mode_mixed_extremes_note',
    ARRAY[]::text[]
  ),
  (
    'privacy_room_entry',
    'privacy',
    'Room entry',
    'Preference for knock/ask before entering room.',
    ARRAY['always_ask','usually_ask','open_door'],
    'distribution',
    ARRAY['do_not_imply_permissions_as_rules']
  ),
  (
    'privacy_notifications',
    'privacy',
    'After-hours notifications',
    'Comfort with notifications after quiet hours.',
    ARRAY['none','limited','ok'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'social_hosting_frequency',
    'social',
    'Guests/hosting',
    'Comfort with guests visiting the home.',
    ARRAY['rare','sometimes','often'],
    'mode_distribution',
    ARRAY[]::text[]
  ),
  (
    'social_togetherness',
    'social',
    'Togetherness',
    'Preference for shared activities vs. solo time.',
    ARRAY['mostly_solo','balanced','mostly_together'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'routine_planning_style',
    'routine',
    'Planning style',
    'Preference for planning vs. spontaneity.',
    ARRAY['planner','mixed','spontaneous'],
    'mode',
    ARRAY[]::text[]
  ),
  (
    'conflict_resolution_style',
    'conflict',
    'Conflict repair',
    'Preferred approach to resolving disagreements.',
    ARRAY['cool_off','talk_soon','mediate'],
    'mode',
    ARRAY[]::text[]
  )
ON CONFLICT (preference_id) DO UPDATE
  SET domain       = EXCLUDED.domain,
      label        = EXCLUDED.label,
      description  = EXCLUDED.description,
      value_keys   = EXCLUDED.value_keys,
      aggregation  = EXCLUDED.aggregation,
      safety_notes = EXCLUDED.safety_notes;

-- ---------------------------------------------------------------------
-- 4) Responses: current truth only (PK user_id + preference_id)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.preference_responses (
  user_id       uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  preference_id text NOT NULL REFERENCES public.preference_taxonomy(preference_id),
  option_index  int2 NOT NULL,
  captured_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_preference_option_index CHECK (option_index BETWEEN 0 AND 2),
  CONSTRAINT pk_preference_responses PRIMARY KEY (user_id, preference_id)
);

-- ---------------------------------------------------------------------
-- 5) Templates: dashboard-only, schema-enforced option objects
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.preference_report_templates (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_key text NOT NULL,
  locale       text NOT NULL,
  body         jsonb NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_template_key_format CHECK (template_key ~ '^[a-z0-9_]{1,64}$'),
  CONSTRAINT chk_template_locale_base CHECK (locale ~ '^[a-z]{2}$'),
  CONSTRAINT uq_preference_report_templates UNIQUE (template_key, locale)
);

CREATE INDEX IF NOT EXISTS idx_preference_report_templates_lookup
  ON public.preference_report_templates (template_key, locale);

DROP TRIGGER IF EXISTS trg_preference_report_templates_touch
  ON public.preference_report_templates;

CREATE TRIGGER trg_preference_report_templates_touch
BEFORE UPDATE ON public.preference_report_templates
FOR EACH ROW
EXECUTE FUNCTION public._touch_updated_at();

-- ---------------------------------------------------------------------
-- 5.1) Template validation trigger (rich details)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._preference_templates_validate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pref jsonb;

  v_template_keys text[];
  v_tax_keys text[];
  v_extra text[];
  v_missing text[];

  v_bad_shape_pref_ids jsonb;
  v_bad_option_pref_ids jsonb;

  v_mismatch_pref_ids jsonb;
  v_mismatch_details jsonb;

BEGIN
  v_pref := NEW.body->'preferences';

  PERFORM public.api_assert(
    jsonb_typeof(v_pref) = 'object',
    'INVALID_TEMPLATE_SCHEMA',
    'Template body.preferences must be a JSON object.',
    '22023',
    jsonb_build_object('path', '{preferences}')
  );

  -- preferences[pref_id] must be array length 3
  SELECT COALESCE(
    jsonb_agg(key) FILTER (WHERE NOT (
      jsonb_typeof(value) = 'array' AND jsonb_array_length(value) = 3
    )),
    '[]'::jsonb
  )
  INTO v_bad_shape_pref_ids
  FROM jsonb_each(v_pref);

  PERFORM public.api_assert(
    jsonb_array_length(v_bad_shape_pref_ids) = 0,
    'INVALID_TEMPLATE_SCHEMA',
    'Each preferences[pref_id] must be an array of length 3.',
    '22023',
    jsonb_build_object('bad_shape_pref_ids', v_bad_shape_pref_ids)
  );

  -- Collect template keys
  SELECT COALESCE(array_agg(k ORDER BY k), ARRAY[]::text[])
    INTO v_template_keys
  FROM jsonb_object_keys(v_pref) AS k;

  -- Collect active taxonomy keys that have defs
  SELECT COALESCE(array_agg(t.preference_id ORDER BY t.preference_id), ARRAY[]::text[])
    INTO v_tax_keys
  FROM public.preference_taxonomy t
  JOIN public.preference_taxonomy_defs d USING (preference_id)
  WHERE t.is_active = true;

  PERFORM public.api_assert(
    COALESCE(array_length(v_tax_keys, 1), 0) > 0,
    'INVALID_TEMPLATE_KEYS',
    'No active preference taxonomy defs exist; cannot validate template keys.',
    '22023',
    '{}'::jsonb
  );

  -- Extra keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_extra
  FROM (
    SELECT unnest(v_template_keys) AS x
    EXCEPT
    SELECT unnest(v_tax_keys) AS x
  ) s;

  -- Missing keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_missing
  FROM (
    SELECT unnest(v_tax_keys) AS x
    EXCEPT
    SELECT unnest(v_template_keys) AS x
  ) s;

  PERFORM public.api_assert(
    COALESCE(array_length(v_extra, 1), 0) = 0
    AND COALESCE(array_length(v_missing, 1), 0) = 0,
    'INVALID_TEMPLATE_KEYS',
    'Template preference keys must exactly match active preference_taxonomy_defs for active taxonomy IDs.',
    '22023',
    jsonb_build_object(
      'extra_pref_ids', COALESCE(to_jsonb(v_extra), '[]'::jsonb),
      'missing_pref_ids', COALESCE(to_jsonb(v_missing), '[]'::jsonb)
    )
  );

  -- Enforce option object schema everywhere
  WITH each_pref AS (
    SELECT e.key AS preference_id, e.value AS arr
    FROM jsonb_each(v_pref) e(key, value)
  ),
  bad AS (
    SELECT preference_id
    FROM each_pref
    WHERE
      jsonb_typeof(arr->0) <> 'object'
      OR jsonb_typeof(arr->1) <> 'object'
      OR jsonb_typeof(arr->2) <> 'object'
      OR jsonb_typeof(arr->0->'value_key') <> 'string'
      OR jsonb_typeof(arr->1->'value_key') <> 'string'
      OR jsonb_typeof(arr->2->'value_key') <> 'string'
      OR jsonb_typeof(arr->0->'title') <> 'string'
      OR jsonb_typeof(arr->1->'title') <> 'string'
      OR jsonb_typeof(arr->2->'title') <> 'string'
      OR jsonb_typeof(arr->0->'text') <> 'string'
      OR jsonb_typeof(arr->1->'text') <> 'string'
      OR jsonb_typeof(arr->2->'text') <> 'string'
  )
  SELECT COALESCE(jsonb_agg(preference_id), '[]'::jsonb)
  INTO v_bad_option_pref_ids
  FROM bad;

  PERFORM public.api_assert(
    jsonb_array_length(v_bad_option_pref_ids) = 0,
    'INVALID_TEMPLATE_OPTION_SCHEMA',
    'Each preferences[pref_id][0..2] must be an object with string keys: value_key, title, text.',
    '22023',
    jsonb_build_object('bad_option_pref_ids', v_bad_option_pref_ids)
  );

  -- Enforce value_key matches defs.value_keys by index order (0..2)
  WITH mismatches AS (
    SELECT
      t.preference_id,
      jsonb_build_object(
        'expected', jsonb_build_array(d.value_keys[1], d.value_keys[2], d.value_keys[3]),
        'got', jsonb_build_array(
          COALESCE(NEW.body->'preferences'->t.preference_id->0->>'value_key', ''),
          COALESCE(NEW.body->'preferences'->t.preference_id->1->>'value_key', ''),
          COALESCE(NEW.body->'preferences'->t.preference_id->2->>'value_key', '')
        )
      ) AS details
    FROM public.preference_taxonomy t
    JOIN public.preference_taxonomy_defs d USING (preference_id)
    WHERE t.is_active = true
      AND (
        COALESCE(NEW.body->'preferences'->t.preference_id->0->>'value_key', '') <> d.value_keys[1]
        OR COALESCE(NEW.body->'preferences'->t.preference_id->1->>'value_key', '') <> d.value_keys[2]
        OR COALESCE(NEW.body->'preferences'->t.preference_id->2->>'value_key', '') <> d.value_keys[3]
      )
  )
  SELECT
    COALESCE(jsonb_agg(preference_id), '[]'::jsonb),
    COALESCE(jsonb_object_agg(preference_id, details), '{}'::jsonb)
  INTO v_mismatch_pref_ids, v_mismatch_details
  FROM mismatches;

  PERFORM public.api_assert(
    jsonb_array_length(v_mismatch_pref_ids) = 0,
    'INVALID_TEMPLATE_VALUE_KEYS',
    'Template option value_key must match preference_taxonomy_defs.value_keys in index order (0..2).',
    '22023',
    jsonb_build_object(
      'mismatched_value_key_pref_ids', v_mismatch_pref_ids,
      'mismatches', v_mismatch_details
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_preference_templates_validate
  ON public.preference_report_templates;

CREATE TRIGGER trg_preference_templates_validate
BEFORE INSERT OR UPDATE ON public.preference_report_templates
FOR EACH ROW
EXECUTE FUNCTION public._preference_templates_validate();

-- ---------------------------------------------------------------------
-- 6) Reports (global, per subject/template/locale)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.preference_reports (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_user_id   uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  template_key      text NOT NULL,
  locale            text NOT NULL,

  status            text NOT NULL DEFAULT 'published',
  generated_content jsonb NOT NULL,
  published_content jsonb NOT NULL,
  generated_at      timestamptz NOT NULL DEFAULT now(),
  published_at      timestamptz NOT NULL DEFAULT now(),

  last_edited_at    timestamptz,
  last_edited_by    uuid REFERENCES public.profiles(id),

  CONSTRAINT chk_preference_reports_status CHECK (status IN ('published', 'out_of_date')),
  CONSTRAINT chk_reports_template_key_format CHECK (template_key ~ '^[a-z0-9_]{1,64}$'),
  CONSTRAINT chk_reports_locale CHECK (locale ~ '^[a-z]{2}$'),
  CONSTRAINT uq_preference_reports_subject_tpl_locale UNIQUE (subject_user_id, template_key, locale)
);

CREATE INDEX IF NOT EXISTS idx_preference_reports_subject
  ON public.preference_reports (subject_user_id);

-- Revisions (audit trail for edits)
CREATE TABLE IF NOT EXISTS public.preference_report_revisions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id      uuid NOT NULL REFERENCES public.preference_reports(id) ON DELETE CASCADE,
  editor_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  edited_at      timestamptz NOT NULL DEFAULT now(),
  content        jsonb NOT NULL,
  change_summary text
);

CREATE INDEX IF NOT EXISTS idx_preference_report_revisions_report
  ON public.preference_report_revisions (report_id, edited_at DESC);

-- Optional acknowledgements
CREATE TABLE IF NOT EXISTS public.preference_report_acknowledgements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id       uuid NOT NULL REFERENCES public.preference_reports(id) ON DELETE CASCADE,
  viewer_user_id  uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  acknowledged_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_preference_report_ack UNIQUE (report_id, viewer_user_id)
);

-- Mark subject's reports out_of_date when responses change
CREATE OR REPLACE FUNCTION public._preference_reports_mark_out_of_date()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := COALESCE(NEW.user_id, OLD.user_id);
BEGIN
  UPDATE public.preference_reports pr
     SET status = 'out_of_date'
   WHERE pr.subject_user_id = v_user
     AND pr.status <> 'out_of_date';

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_preference_responses_out_of_date
  ON public.preference_responses;

CREATE TRIGGER trg_preference_responses_out_of_date
AFTER INSERT OR UPDATE ON public.preference_responses
FOR EACH ROW
EXECUTE FUNCTION public._preference_reports_mark_out_of_date();

-- ---------------------------------------------------------------------
-- 7) RLS lockdown (RPC-only; dashboard edits happen with privileged role)
-- ---------------------------------------------------------------------
ALTER TABLE public.preference_taxonomy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preference_taxonomy_defs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preference_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preference_report_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preference_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preference_report_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.preference_report_acknowledgements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.preference_taxonomy FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.preference_taxonomy_defs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.preference_responses FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.preference_report_templates FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.preference_reports FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.preference_report_revisions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.preference_report_acknowledgements FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8) RPCs
-- ---------------------------------------------------------------------

-- 8.1 Submit ALL answers in one go (atomic, complete set required)
-- Input shape:
--   p_answers = { "environment_noise_tolerance": 2, "environment_light_preference": 1, ... }
CREATE OR REPLACE FUNCTION public.preference_responses_submit(
  p_answers jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();

  v_tax_keys text[];
  v_answer_keys text[];

  v_extra text[];
  v_missing text[];

  v_bad_value_keys jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    jsonb_typeof(p_answers) = 'object',
    'INVALID_ANSWERS',
    'Answers must be a JSON object of { preference_id: option_index }.',
    '22023',
    jsonb_build_object('expected', 'object')
  );

  -- Active taxonomy keys (must have defs)
  SELECT COALESCE(array_agg(t.preference_id ORDER BY t.preference_id), ARRAY[]::text[])
    INTO v_tax_keys
  FROM public.preference_taxonomy t
  JOIN public.preference_taxonomy_defs d USING (preference_id)
  WHERE t.is_active = true;

  PERFORM public.api_assert(
    COALESCE(array_length(v_tax_keys, 1), 0) > 0,
    'INVALID_TAXONOMY_STATE',
    'No active preference taxonomy defs exist; cannot accept answers.',
    '22023'
  );

  -- Answer keys
  SELECT COALESCE(array_agg(k ORDER BY k), ARRAY[]::text[])
    INTO v_answer_keys
  FROM jsonb_object_keys(p_answers) AS k;

  -- Extra keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_extra
  FROM (
    SELECT unnest(v_answer_keys) AS x
    EXCEPT
    SELECT unnest(v_tax_keys) AS x
  ) s;

  -- Missing keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_missing
  FROM (
    SELECT unnest(v_tax_keys) AS x
    EXCEPT
    SELECT unnest(v_answer_keys) AS x
  ) s;

  PERFORM public.api_assert(
    COALESCE(array_length(v_extra, 1), 0) = 0
    AND COALESCE(array_length(v_missing, 1), 0) = 0,
    'INCOMPLETE_ANSWERS',
    'You must answer every preference in one submission (no missing or extra keys).',
    '22023',
    jsonb_build_object(
      'extra_pref_ids', COALESCE(to_jsonb(v_extra), '[]'::jsonb),
      'missing_pref_ids', COALESCE(to_jsonb(v_missing), '[]'::jsonb)
    )
  );

  -- Validate each value is an integer 0..2 without unsafe casts.
  SELECT COALESCE(
    jsonb_agg(k) FILTER (WHERE NOT (
      CASE
        WHEN jsonb_typeof(p_answers->k) = 'number'
          AND (p_answers->>k) ~ '^[0-9]+$'
          THEN ((p_answers->>k)::int BETWEEN 0 AND 2)
        ELSE false
      END
    )),
    '[]'::jsonb
  )
  INTO v_bad_value_keys
  FROM unnest(v_answer_keys) AS k;

  PERFORM public.api_assert(
    jsonb_array_length(v_bad_value_keys) = 0,
    'INVALID_OPTION_INDEX',
    'All option_index values must be integers between 0 and 2.',
    '22023',
    jsonb_build_object('bad_pref_ids', v_bad_value_keys)
  );

  -- Atomic upsert of full set
  INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
  SELECT
    v_user,
    k AS preference_id,
    (p_answers->>k)::int2 AS option_index,
    now() AS captured_at
  FROM unnest(v_answer_keys) AS k
  ON CONFLICT (user_id, preference_id)
  DO UPDATE SET
    option_index = EXCLUDED.option_index,
    captured_at  = EXCLUDED.captured_at
  WHERE public.preference_responses.option_index IS DISTINCT FROM EXCLUDED.option_index;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- 8.2 Generate preference report from template row
-- - Canonical schema: template.body.preferences[pref_id][option_index] -> object
-- - Unresolved = (active taxonomy) minus (answered) plus any null resolutions
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

  v_generated := jsonb_build_object(
    'template_key', p_template_key,
    'locale', p_locale,
    'summary', v_template.body->'summary',
    'sections', v_template.body->'sections',
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

-- 8.3 Edit (published-only): subject edits ONE section's text only
CREATE OR REPLACE FUNCTION public.preference_reports_edit_section_text(
  p_template_key text,
  p_locale text,
  p_section_key text,
  p_new_text text,
  p_change_summary text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_report public.preference_reports%ROWTYPE;

  v_sections jsonb;
  v_new_sections jsonb;
  v_match_count int := 0;

  v_new_content jsonb;
  v_old_text text;
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

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  PERFORM public.api_assert(
    p_section_key IS NOT NULL AND length(trim(p_section_key)) > 0
      AND p_section_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_SECTION_KEY',
    'Section key is required and must match ^[a-z0-9_]{1,64}$.',
    '22023'
  );

  PERFORM public.api_assert(
    p_new_text IS NOT NULL,
    'INVALID_TEXT',
    'Section text cannot be null.',
    '22023'
  );

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = v_user
    AND r.template_key = p_template_key
    AND r.locale = p_locale
    AND r.status = 'published'
  LIMIT 1;

  IF v_report.id IS NULL THEN
    PERFORM public.api_error(
      'REPORT_NOT_FOUND',
      'No published preference report found to edit.',
      'P0001',
      jsonb_build_object('template_key', p_template_key, 'locale', p_locale)
    );
  END IF;

  -- Advisory lock per report
  PERFORM pg_advisory_xact_lock(hashtextextended(v_report.id::text, 0));

  v_sections := v_report.published_content->'sections';

  PERFORM public.api_assert(
    jsonb_typeof(v_sections) = 'array',
    'INVALID_REPORT_SHAPE',
    'published_content.sections must be an array.',
    '22023'
  );

  SELECT COUNT(*)
    INTO v_match_count
  FROM jsonb_array_elements(v_sections) AS s(value)
  WHERE (value->>'section_key') = p_section_key;

  PERFORM public.api_assert(
    v_match_count = 1,
    'SECTION_NOT_FOUND_OR_DUPLICATE',
    'Expected exactly 1 section with the given section_key.',
    '22023',
    jsonb_build_object('section_key', p_section_key, 'match_count', v_match_count)
  );

  -- no-op if unchanged
  SELECT (value->>'text')
    INTO v_old_text
  FROM jsonb_array_elements(v_sections) AS s(value)
  WHERE (value->>'section_key') = p_section_key
  LIMIT 1;

  IF v_old_text IS NOT DISTINCT FROM p_new_text THEN
    RETURN jsonb_build_object('ok', true, 'report_id', v_report.id, 'status', 'unchanged');
  END IF;

  -- rebuild sections
  SELECT COALESCE(
    jsonb_agg(
      CASE
        WHEN (value->>'section_key') = p_section_key THEN
          (value || jsonb_build_object('text', to_jsonb(p_new_text)))
        ELSE
          value
      END
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_new_sections
  FROM jsonb_array_elements(v_sections) WITH ORDINALITY AS e(value, ord);

  v_new_content := jsonb_set(v_report.published_content, '{sections}', v_new_sections, true);

  UPDATE public.preference_reports
     SET published_content = v_new_content,
         last_edited_at = now(),
         last_edited_by = v_user
   WHERE id = v_report.id;

  INSERT INTO public.preference_report_revisions (
    report_id, editor_user_id, edited_at, content, change_summary
  ) VALUES (
    v_report.id, v_user, now(), v_new_content,
    COALESCE(p_change_summary, 'Edited section ' || p_section_key)
  );

  RETURN jsonb_build_object('ok', true, 'report_id', v_report.id, 'status', 'edited');
END;
$$;

-- Deprecate / remove old edit RPC that accepted arbitrary JSON (if present)
DROP FUNCTION IF EXISTS public.preference_reports_edit(text, text, jsonb, text);

-- 8.4 Get published report in a HOME context (viewer must be member; subject must be current member)
-- NOTE: requires your existing home asserts: _assert_home_member, _assert_home_active
CREATE OR REPLACE FUNCTION public.preference_reports_get_for_home(
  p_home_id uuid,
  p_subject_user_id uuid,
  p_template_key text,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_report public.preference_reports%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

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

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  -- only current members visible
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      WHERE m.home_id = p_home_id
        AND m.user_id = p_subject_user_id
        AND m.is_current = true
    ),
    'SUBJECT_NOT_IN_HOME',
    'Subject user is not a current member of this home.',
    '22023'
  );

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = p_subject_user_id
    AND r.template_key = p_template_key
    AND r.locale = p_locale
    AND r.status = 'published'
  LIMIT 1;

  IF v_report.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'found', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'found', true,
    'report', jsonb_build_object(
      'id', v_report.id,
      'subject_user_id', v_report.subject_user_id,
      'template_key', v_report.template_key,
      'locale', v_report.locale,
      'published_at', v_report.published_at,
      'published_content', v_report.published_content,
      'last_edited_at', v_report.last_edited_at,
      'last_edited_by', v_report.last_edited_by
    )
  );
END;
$$;

-- 8.5 List published reports for CURRENT members of a home (summary)
CREATE OR REPLACE FUNCTION public.preference_reports_list_for_home(
  p_home_id uuid,
  p_template_key text,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

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

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'items',
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'report_id', r.id,
            'subject_user_id', r.subject_user_id,
            'published_at', r.published_at,
            'last_edited_at', r.last_edited_at
          )
          ORDER BY r.published_at DESC NULLS LAST
        )
        FROM public.memberships m
        JOIN public.preference_reports r
          ON r.subject_user_id = m.user_id
         AND r.template_key = p_template_key
         AND r.locale = p_locale
         AND r.status = 'published'
        WHERE m.home_id = p_home_id
          AND m.is_current = true
      ),
      '[]'::jsonb
    )
  );
END;
$$;

-- 8.6 Optional: Acknowledge (viewer must share at least one current home with subject)
CREATE OR REPLACE FUNCTION public.preference_reports_acknowledge(
  p_report_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_subject uuid;
  v_status text;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT r.subject_user_id, r.status
    INTO v_subject, v_status
  FROM public.preference_reports r
  WHERE r.id = p_report_id
  LIMIT 1;

  IF v_subject IS NULL THEN
    PERFORM public.api_error('REPORT_NOT_FOUND', 'No preference report found to acknowledge.', 'P0001');
  END IF;

  IF v_status <> 'published' THEN
    PERFORM public.api_error('REPORT_NOT_PUBLISHED', 'Only published reports can be acknowledged.', 'P0001');
  END IF;

  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships a
      JOIN public.memberships b
        ON b.home_id = a.home_id
       AND b.user_id = v_subject
       AND b.is_current = true
      WHERE a.user_id = v_user
        AND a.is_current = true
    ),
    'NOT_IN_SAME_HOME',
    'You can only acknowledge reports for someone in a home you share.',
    '22023'
  );

  INSERT INTO public.preference_report_acknowledgements (
    report_id, viewer_user_id, acknowledged_at
  ) VALUES (
    p_report_id, v_user, now()
  )
  ON CONFLICT (report_id, viewer_user_id) DO NOTHING;

  RETURN jsonb_build_object('ok', true);
END;
$$;


-- 2) Helper: locale_base('en-NZ') => 'en', locale_base('en') => 'en'
CREATE OR REPLACE FUNCTION public.locale_base(p_locale text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    CASE
      WHEN p_locale IS NULL OR length(trim(p_locale)) = 0 THEN NULL
      ELSE lower(split_part(p_locale, '-', 1))
    END
$$;

-- 3) RPC: fetch best template for current user (base-locale match, fallback en)
--    - If user's notification_preferences.locale is missing/invalid => fallback en
--    - If base language template not found => fallback en
CREATE OR REPLACE FUNCTION public.preference_templates_get_for_user(
  p_template_key text DEFAULT 'personal_preferences_v1'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_user_locale text;
  v_base text;
  v_resolved text;
  v_template public.preference_report_templates%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  -- Validate template key
  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  -- Read user's locale (e.g. en-NZ) from notification_preferences
  SELECT np.locale
    INTO v_user_locale
  FROM public.notification_preferences np
  WHERE np.user_id = v_user
  LIMIT 1;

  v_base := public.locale_base(v_user_locale);

  -- Only allow supported languages; otherwise fallback to en
  IF v_base NOT IN ('en','es','ar') THEN
    v_base := 'en';
  END IF;

  -- Prefer base match if exists, else fallback en
  SELECT t.*
    INTO v_template
  FROM public.preference_report_templates t
  WHERE t.template_key = p_template_key
    AND t.locale = v_base
  LIMIT 1;

  IF v_template.id IS NOT NULL THEN
    v_resolved := v_base;
  ELSE
    SELECT t.*
      INTO v_template
    FROM public.preference_report_templates t
    WHERE t.template_key = p_template_key
      AND t.locale = 'en'
    LIMIT 1;

    v_resolved := 'en';
  END IF;

  IF v_template.id IS NULL THEN
    PERFORM public.api_error(
      'TEMPLATE_NOT_FOUND',
      'No template found for template_key (neither user locale nor fallback en).',
      'P0001',
      jsonb_build_object(
        'template_key', p_template_key,
        'requested_locale', v_user_locale,
        'base_locale', v_base
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'template_key', v_template.template_key,
    'requested_locale', v_user_locale,
    'resolved_locale', v_resolved,
    'body', v_template.body
  );
END;
$$;

-- 4) Seed templates (en, es, ar) for scenarios + answer copy.
-- Canonical schema:
-- body = {
--   summary: {...},
--   sections: [{section_key,title,text}, ...],
--   preferences: { pref_id: [ {value_key,title,text}, {..}, {..} ], ... }
-- }

-- -----------------------------
-- EN template (personal_preferences_v1)
-- -----------------------------
INSERT INTO public.preference_report_templates (template_key, locale, body)
VALUES (
  'personal_preferences_v1',
  'en',
  jsonb_build_object(
    'summary', jsonb_build_object(
      'title', 'Personal preferences',
      'subtitle', 'This helps housemates understand comfort styles. Not rules.'
    ),
    'sections', jsonb_build_array(
      jsonb_build_object('section_key','environment','title','Environment','text','How you prefer the shared space to feel.'),
      jsonb_build_object('section_key','schedule','title','Schedule','text','Timing preferences that affect comfort.'),
      jsonb_build_object('section_key','communication','title','Communication','text','How you like to coordinate and give feedback.'),
      jsonb_build_object('section_key','cleanliness','title','Cleanliness','text','What “tidy enough” means to you.'),
      jsonb_build_object('section_key','privacy','title','Privacy','text','Boundaries that help you feel at ease.'),
      jsonb_build_object('section_key','social','title','Social','text','Your comfort with guests and togetherness.'),
      jsonb_build_object('section_key','routine','title','Routine','text','Planning vs spontaneity.'),
      jsonb_build_object('section_key','conflict','title','Repair','text','What helps after small tension.')
    ),
    'preferences', jsonb_build_object(
      -- environment_noise_tolerance: low | medium | high
      'environment_noise_tolerance', jsonb_build_array(
        jsonb_build_object('value_key','low',    'title','Low',    'text','I’m most comfortable when shared spaces are mostly quiet.'),
        jsonb_build_object('value_key','medium', 'title','Medium', 'text','Some background noise is fine, especially at reasonable hours.'),
        jsonb_build_object('value_key','high',   'title','High',   'text','I’m generally okay with lively noise in shared spaces.')
      ),
      -- environment_light_preference: dim | balanced | bright
      'environment_light_preference', jsonb_build_array(
        jsonb_build_object('value_key','dim',      'title','Dim',      'text','I prefer softer lighting in shared spaces.'),
        jsonb_build_object('value_key','balanced', 'title','Balanced', 'text','I’m comfortable with a mix of natural and indoor light.'),
        jsonb_build_object('value_key','bright',   'title','Bright',   'text','I feel best with brighter lighting in shared areas.')
      ),
      -- environment_scent_sensitivity: sensitive | neutral | tolerant
      'environment_scent_sensitivity', jsonb_build_array(
        jsonb_build_object('value_key','sensitive','title','Sensitive','text','Strong scents can bother me, so I prefer mild/no fragrance.'),
        jsonb_build_object('value_key','neutral',  'title','Neutral',  'text','I’m okay with light scents in moderation.'),
        jsonb_build_object('value_key','tolerant', 'title','Tolerant', 'text','Scent usually doesn’t affect me much.')
      ),
      -- schedule_quiet_hours_preference: early_evening | late_evening_or_night | none
      'schedule_quiet_hours_preference', jsonb_build_array(
        jsonb_build_object('value_key','early_evening',        'title','Early evening', 'text','I prefer things to wind down earlier in the evening.'),
        jsonb_build_object('value_key','late_evening_or_night','title','Late evening',  'text','Later evenings are fine for me if people are mindful.'),
        jsonb_build_object('value_key','none',                 'title','No preference', 'text','I don’t have a strong quiet-hours preference.')
      ),
      -- schedule_sleep_timing: early | standard | late
      'schedule_sleep_timing', jsonb_build_array(
        jsonb_build_object('value_key','early',   'title','Early',    'text','I usually sleep and wake earlier.'),
        jsonb_build_object('value_key','standard','title','Standard', 'text','My sleep timing is fairly typical.'),
        jsonb_build_object('value_key','late',    'title','Late',     'text','I tend to sleep and wake later.')
      ),
      -- communication_channel: text | call | in_person
      'communication_channel', jsonb_build_array(
        jsonb_build_object('value_key','text',     'title','Text',      'text','I prefer messages for quick coordination.'),
        jsonb_build_object('value_key','call',     'title','Call',      'text','I prefer a quick call when something matters.'),
        jsonb_build_object('value_key','in_person','title','In person', 'text','I prefer talking face-to-face when possible.')
      ),
      -- communication_directness: gentle | balanced | direct
      'communication_directness', jsonb_build_array(
        jsonb_build_object('value_key','gentle',  'title','Gentle',   'text','I prefer softer phrasing and good timing.'),
        jsonb_build_object('value_key','balanced','title','Balanced', 'text','I’m okay with a mix of directness and tact.'),
        jsonb_build_object('value_key','direct',  'title','Direct',   'text','I’m most comfortable being straightforward.')
      ),
      -- cleanliness_shared_space_tolerance: low | medium | high
      'cleanliness_shared_space_tolerance', jsonb_build_array(
        jsonb_build_object('value_key','low',   'title','Low',    'text','I prefer shared areas to stay consistently tidy.'),
        jsonb_build_object('value_key','medium','title','Medium', 'text','A bit of clutter happens, but resets are important.'),
        jsonb_build_object('value_key','high',  'title','High',   'text','I’m generally okay with some clutter in shared spaces.')
      ),
      -- privacy_room_entry: always_ask | usually_ask | open_door
      'privacy_room_entry', jsonb_build_array(
        jsonb_build_object('value_key','always_ask', 'title','Always ask',  'text','Please ask/knock before entering my room.'),
        jsonb_build_object('value_key','usually_ask','title','Usually ask', 'text','A knock is great; urgent things can be flexible.'),
        jsonb_build_object('value_key','open_door',  'title','Open door',   'text','I’m generally okay with casual entry if respectful.')
      ),
      -- privacy_notifications: none | limited | ok
      'privacy_notifications', jsonb_build_array(
        jsonb_build_object('value_key','none',   'title','None',    'text','I prefer not to be contacted after quiet hours.'),
        jsonb_build_object('value_key','limited','title','Limited', 'text','Only important messages after quiet hours.'),
        jsonb_build_object('value_key','ok',     'title','Okay',    'text','After-hours messages are generally okay for me.')
      ),
      -- social_hosting_frequency: rare | sometimes | often
      'social_hosting_frequency', jsonb_build_array(
        jsonb_build_object('value_key','rare',     'title','Rare',      'text','I’m most comfortable with guests occasionally.'),
        jsonb_build_object('value_key','sometimes','title','Sometimes', 'text','Guests sometimes is fine with a heads-up.'),
        jsonb_build_object('value_key','often',    'title','Often',     'text','I’m comfortable with guests fairly often.')
      ),
      -- social_togetherness: mostly_solo | balanced | mostly_together
      'social_togetherness', jsonb_build_array(
        jsonb_build_object('value_key','mostly_solo',    'title','Mostly solo', 'text','I recharge best with more solo time at home.'),
        jsonb_build_object('value_key','balanced',       'title','Balanced',   'text','I like a mix of solo time and shared moments.'),
        jsonb_build_object('value_key','mostly_together','title','Together',   'text','I enjoy a more social, shared-home vibe.')
      ),
      -- routine_planning_style: planner | mixed | spontaneous
      'routine_planning_style', jsonb_build_array(
        jsonb_build_object('value_key','planner',     'title','Planner',     'text','I like plans and clear expectations.'),
        jsonb_build_object('value_key','mixed',       'title','Mixed',       'text','Some planning helps, but I’m flexible.'),
        jsonb_build_object('value_key','spontaneous', 'title','Spontaneous', 'text','I prefer to keep things open and adapt as we go.')
      ),
      -- conflict_resolution_style: cool_off | talk_soon | mediate
      'conflict_resolution_style', jsonb_build_array(
        jsonb_build_object('value_key','cool_off', 'title','Cool off', 'text','A little space first helps me reset.'),
        jsonb_build_object('value_key','talk_soon','title','Talk soon','text','Talking it through sooner helps me feel okay again.'),
        jsonb_build_object('value_key','mediate',  'title','Check-in','text','A gentle, timed check-in helps most.')
      )
    )
  )
)
ON CONFLICT (template_key, locale) DO UPDATE
SET body = EXCLUDED.body;

-- -----------------------------
-- ES template (simple, friendly Spanish)
-- -----------------------------
INSERT INTO public.preference_report_templates (template_key, locale, body)
VALUES (
  'personal_preferences_v1',
  'es',
  jsonb_build_object(
    'summary', jsonb_build_object(
      'title', 'Preferencias personales',
      'subtitle', 'Esto ayuda a entender estilos de convivencia. No son reglas.'
    ),
    'sections', jsonb_build_array(
      jsonb_build_object('section_key','environment','title','Ambiente','text','Cómo te gusta que se sienta el espacio compartido.'),
      jsonb_build_object('section_key','schedule','title','Horario','text','Preferencias de tiempo que afectan la comodidad.'),
      jsonb_build_object('section_key','communication','title','Comunicación','text','Cómo coordinas y das feedback.'),
      jsonb_build_object('section_key','cleanliness','title','Limpieza','text','Qué significa “suficientemente ordenado” para ti.'),
      jsonb_build_object('section_key','privacy','title','Privacidad','text','Límites que te ayudan a estar tranquilo/a.'),
      jsonb_build_object('section_key','social','title','Social','text','Tu comodidad con visitas y vida en común.'),
      jsonb_build_object('section_key','routine','title','Rutina','text','Planificación vs espontaneidad.'),
      jsonb_build_object('section_key','conflict','title','Reparación','text','Qué ayuda después de una pequeña tensión.')
    ),
    'preferences', jsonb_build_object(
      'environment_noise_tolerance', jsonb_build_array(
        jsonb_build_object('value_key','low',    'title','Baja',  'text','Me siento mejor cuando los espacios comunes están mayormente en silencio.'),
        jsonb_build_object('value_key','medium', 'title','Media', 'text','Un poco de ruido de fondo está bien en horarios razonables.'),
        jsonb_build_object('value_key','high',   'title','Alta',  'text','Generalmente estoy bien con más actividad/ruido en espacios comunes.')
      ),
      'environment_light_preference', jsonb_build_array(
        jsonb_build_object('value_key','dim',      'title','Suave',     'text','Prefiero una luz más tenue en espacios comunes.'),
        jsonb_build_object('value_key','balanced', 'title','Equilibrada','text','Me acomoda una mezcla de luz natural y artificial.'),
        jsonb_build_object('value_key','bright',   'title','Brillante', 'text','Me siento mejor con espacios comunes bien iluminados.')
      ),
      'environment_scent_sensitivity', jsonb_build_array(
        jsonb_build_object('value_key','sensitive','title','Sensible', 'text','Los olores fuertes me molestan; prefiero fragancias suaves o nada.'),
        jsonb_build_object('value_key','neutral',  'title','Neutral',  'text','Estoy bien con aromas leves con moderación.'),
        jsonb_build_object('value_key','tolerant', 'title','Tolerante','text','Los aromas normalmente no me afectan mucho.')
      ),
      'schedule_quiet_hours_preference', jsonb_build_array(
        jsonb_build_object('value_key','early_evening',        'title','Temprano', 'text','Prefiero que el ambiente se calme más temprano en la noche.'),
        jsonb_build_object('value_key','late_evening_or_night','title','Tarde',    'text','Me va bien que sea más tarde si se es considerado/a.'),
        jsonb_build_object('value_key','none',                 'title','Sin preferencia','text','No tengo una preferencia fuerte de horario silencioso.')
      ),
      'schedule_sleep_timing', jsonb_build_array(
        jsonb_build_object('value_key','early',   'title','Temprano','text','Suelo dormir y despertar temprano.'),
        jsonb_build_object('value_key','standard','title','Normal',  'text','Mi horario de sueño es bastante típico.'),
        jsonb_build_object('value_key','late',    'title','Tarde',   'text','Suelo dormir y despertar más tarde.')
      ),
      'communication_channel', jsonb_build_array(
        jsonb_build_object('value_key','text',     'title','Mensajes','text','Prefiero mensajes para coordinar rápido.'),
        jsonb_build_object('value_key','call',     'title','Llamada', 'text','Prefiero una llamada corta cuando importa.'),
        jsonb_build_object('value_key','in_person','title','En persona','text','Prefiero hablar cara a cara cuando se puede.')
      ),
      'communication_directness', jsonb_build_array(
        jsonb_build_object('value_key','gentle',  'title','Suave',    'text','Prefiero un enfoque más suave y buen timing.'),
        jsonb_build_object('value_key','balanced','title','Equilibrado','text','Me va bien una mezcla de claridad y tacto.'),
        jsonb_build_object('value_key','direct',  'title','Directo',  'text','Me siento más cómodo/a siendo directo/a.')
      ),
      'cleanliness_shared_space_tolerance', jsonb_build_array(
        jsonb_build_object('value_key','low',   'title','Baja',  'text','Prefiero que las áreas comunes se mantengan ordenadas.'),
        jsonb_build_object('value_key','medium','title','Media', 'text','Un poco de desorden pasa, pero es importante resetear.'),
        jsonb_build_object('value_key','high',  'title','Alta',  'text','Generalmente estoy bien con algo de desorden en áreas comunes.')
      ),
      'privacy_room_entry', jsonb_build_array(
        jsonb_build_object('value_key','always_ask', 'title','Siempre preguntar','text','Por favor tocar/preguntar antes de entrar a mi habitación.'),
        jsonb_build_object('value_key','usually_ask','title','Usualmente preguntar','text','Tocar está genial; urgencias pueden ser flexibles.'),
        jsonb_build_object('value_key','open_door',  'title','Puerta abierta','text','En general estoy bien si hay respeto.')
      ),
      'privacy_notifications', jsonb_build_array(
        jsonb_build_object('value_key','none',   'title','Nada',     'text','Prefiero no recibir mensajes después de horas tranquilas.'),
        jsonb_build_object('value_key','limited','title','Limitado', 'text','Solo mensajes importantes después de horas tranquilas.'),
        jsonb_build_object('value_key','ok',     'title','Ok',       'text','En general está bien recibir mensajes tarde.')
      ),
      'social_hosting_frequency', jsonb_build_array(
        jsonb_build_object('value_key','rare',     'title','Rara vez','text','Me siento mejor con visitas de vez en cuando.'),
        jsonb_build_object('value_key','sometimes','title','A veces', 'text','A veces está bien con un aviso.'),
        jsonb_build_object('value_key','often',    'title','A menudo','text','Me siento cómodo/a con visitas bastante seguido.')
      ),
      'social_togetherness', jsonb_build_array(
        jsonb_build_object('value_key','mostly_solo',    'title','Más solo','text','Recargo mejor con más tiempo a solas en casa.'),
        jsonb_build_object('value_key','balanced',       'title','Equilibrado','text','Me gusta un mix de tiempo a solas y momentos compartidos.'),
        jsonb_build_object('value_key','mostly_together','title','Más juntos','text','Disfruto un hogar más social y compartido.')
      ),
      'routine_planning_style', jsonb_build_array(
        jsonb_build_object('value_key','planner',     'title','Planificador','text','Me gustan los planes y expectativas claras.'),
        jsonb_build_object('value_key','mixed',       'title','Mixto',       'text','Algo de planificación ayuda, pero soy flexible.'),
        jsonb_build_object('value_key','spontaneous', 'title','Espontáneo',  'text','Prefiero mantenerlo abierto y adaptarnos.')
      ),
      'conflict_resolution_style', jsonb_build_array(
        jsonb_build_object('value_key','cool_off', 'title','Pausar',    'text','Un poco de espacio primero me ayuda a resetear.'),
        jsonb_build_object('value_key','talk_soon','title','Hablar pronto','text','Hablarlo pronto me ayuda a estar bien.'),
        jsonb_build_object('value_key','mediate',  'title','Chequeo suave','text','Un chequeo amable en el momento adecuado ayuda.')
      )
    )
  )
)
ON CONFLICT (template_key, locale) DO UPDATE
SET body = EXCLUDED.body;

-- -----------------------------
-- AR template (simple Modern Standard Arabic)
-- -----------------------------
INSERT INTO public.preference_report_templates (template_key, locale, body)
VALUES (
  'personal_preferences_v1',
  'ar',
  jsonb_build_object(
    'summary', jsonb_build_object(
      'title', 'تفضيلات شخصية',
      'subtitle', 'هذا يساعد على فهم أساليب الراحة في السكن. ليست قواعد.'
    ),
    'sections', jsonb_build_array(
      jsonb_build_object('section_key','environment','title','البيئة','text','كيف تحب أن يكون الجو في المساحات المشتركة.'),
      jsonb_build_object('section_key','schedule','title','الوقت','text','تفضيلات التوقيت التي تؤثر على الراحة.'),
      jsonb_build_object('section_key','communication','title','التواصل','text','كيف تفضّل التنسيق وإبداء الملاحظات.'),
      jsonb_build_object('section_key','cleanliness','title','النظافة','text','ماذا يعني “مرتب بما يكفي” بالنسبة لك.'),
      jsonb_build_object('section_key','privacy','title','الخصوصية','text','حدود تساعدك على الشعور بالارتياح.'),
      jsonb_build_object('section_key','social','title','الاجتماعي','text','مدى راحتك مع الضيوف والوقت المشترك.'),
      jsonb_build_object('section_key','routine','title','الروتين','text','التخطيط مقابل العفوية.'),
      jsonb_build_object('section_key','conflict','title','الإصلاح','text','ما الذي يساعد بعد توتر بسيط.')
    ),
    'preferences', jsonb_build_object(
      'environment_noise_tolerance', jsonb_build_array(
        jsonb_build_object('value_key','low',    'title','منخفض', 'text','أرتاح أكثر عندما تكون المساحات المشتركة هادئة غالبًا.'),
        jsonb_build_object('value_key','medium', 'title','متوسط', 'text','لا بأس بضوضاء خفيفة في أوقات مناسبة.'),
        jsonb_build_object('value_key','high',   'title','مرتفع', 'text','عادةً لا تزعجني الأجواء الحيوية في المساحات المشتركة.')
      ),
      'environment_light_preference', jsonb_build_array(
        jsonb_build_object('value_key','dim',      'title','إضاءة خافتة', 'text','أفضل إضاءة أهدأ في المساحات المشتركة.'),
        jsonb_build_object('value_key','balanced', 'title','متوازنة',     'text','أرتاح لمزيج من الضوء الطبيعي والداخلي.'),
        jsonb_build_object('value_key','bright',   'title','ساطعة',       'text','أشعر أفضل مع إضاءة قوية في المساحات المشتركة.')
      ),
      'environment_scent_sensitivity', jsonb_build_array(
        jsonb_build_object('value_key','sensitive','title','حسّاس',  'text','الروائح القوية قد تزعجني؛ أفضّل بدون عطور أو عطور خفيفة.'),
        jsonb_build_object('value_key','neutral',  'title','محايد',  'text','لا بأس بروائح خفيفة باعتدال.'),
        jsonb_build_object('value_key','tolerant', 'title','متسامح', 'text','الروائح عادةً لا تؤثر علي كثيرًا.')
      ),
      'schedule_quiet_hours_preference', jsonb_build_array(
        jsonb_build_object('value_key','early_evening',        'title','مبكرًا', 'text','أفضل أن يهدأ الجو في وقت أبكر من المساء.'),
        jsonb_build_object('value_key','late_evening_or_night','title','متأخرًا', 'text','المساء المتأخر مناسب إذا كان الجميع مراعيًا.'),
        jsonb_build_object('value_key','none',                 'title','لا تفضيل', 'text','ليس لدي تفضيل قوي لساعات الهدوء.')
      ),
      'schedule_sleep_timing', jsonb_build_array(
        jsonb_build_object('value_key','early',   'title','مبكر',   'text','عادةً أنام وأستيقظ مبكرًا.'),
        jsonb_build_object('value_key','standard','title','عادي',   'text','نمط نومي معتدل.'),
        jsonb_build_object('value_key','late',    'title','متأخر',  'text','عادةً أنام وأستيقظ متأخرًا.')
      ),
      'communication_channel', jsonb_build_array(
        jsonb_build_object('value_key','text',     'title','رسائل',     'text','أفضل الرسائل للتنسيق السريع.'),
        jsonb_build_object('value_key','call',     'title','مكالمة',    'text','أفضل مكالمة قصيرة عندما يكون الأمر مهمًا.'),
        jsonb_build_object('value_key','in_person','title','وجهًا لوجه','text','أفضل الحديث وجهًا لوجه عندما يمكن.')
      ),
      'communication_directness', jsonb_build_array(
        jsonb_build_object('value_key','gentle',  'title','بلطف',     'text','أفضل أسلوبًا لطيفًا وتوقيتًا مناسبًا.'),
        jsonb_build_object('value_key','balanced','title','متوازن',   'text','لا بأس بمزيج من الصراحة واللباقة.'),
        jsonb_build_object('value_key','direct',  'title','مباشر',    'text','أرتاح أكثر مع الصراحة المباشرة.')
      ),
      'cleanliness_shared_space_tolerance', jsonb_build_array(
        jsonb_build_object('value_key','low',   'title','منخفض', 'text','أفضل أن تبقى المساحات المشتركة مرتبة باستمرار.'),
        jsonb_build_object('value_key','medium','title','متوسط', 'text','قد يحدث بعض الفوضى، لكن من المهم إعادة الترتيب.'),
        jsonb_build_object('value_key','high',  'title','مرتفع', 'text','لا تزعجني بعض الفوضى في المساحات المشتركة.')
      ),
      'privacy_room_entry', jsonb_build_array(
        jsonb_build_object('value_key','always_ask', 'title','اسأل دائمًا',    'text','يفضل أن تطرق/تسأل قبل دخول غرفتي.'),
        jsonb_build_object('value_key','usually_ask','title','غالبًا اسأل',    'text','الطرق ممتاز؛ في الحالات العاجلة يمكن المرونة.'),
        jsonb_build_object('value_key','open_door',  'title','لا بأس',         'text','عادةً لا مانع لدي إذا كان هناك احترام.')
      ),
      'privacy_notifications', jsonb_build_array(
        jsonb_build_object('value_key','none',   'title','لا',      'text','أفضل عدم تلقي رسائل بعد ساعات الهدوء.'),
        jsonb_build_object('value_key','limited','title','محدود',   'text','فقط الرسائل المهمة بعد ساعات الهدوء.'),
        jsonb_build_object('value_key','ok',     'title','حسنًا',   'text','لا بأس عادةً بالرسائل في وقت متأخر.')
      ),
      'social_hosting_frequency', jsonb_build_array(
        jsonb_build_object('value_key','rare',     'title','نادرًا',  'text','أرتاح أكثر مع ضيوف بشكل متباعد.'),
        jsonb_build_object('value_key','sometimes','title','أحيانًا', 'text','أحيانًا مناسب مع تنبيه مسبق.'),
        jsonb_build_object('value_key','often',    'title','غالبًا',  'text','أنا مرتاح لوجود ضيوف بشكل متكرر.')
      ),
      'social_togetherness', jsonb_build_array(
        jsonb_build_object('value_key','mostly_solo',    'title','أغلبه وحدي', 'text','أستعيد طاقتي أكثر مع وقت خاص في المنزل.'),
        jsonb_build_object('value_key','balanced',       'title','متوازن',     'text','أفضل مزيجًا من الوقت الخاص والوقت المشترك.'),
        jsonb_build_object('value_key','mostly_together','title','أغلبه معًا', 'text','أستمتع بجو منزلي اجتماعي ومشترك.')
      ),
      'routine_planning_style', jsonb_build_array(
        jsonb_build_object('value_key','planner',     'title','مخطِّط',    'text','أحب التخطيط والتوقعات الواضحة.'),
        jsonb_build_object('value_key','mixed',       'title','مختلط',     'text','التخطيط يساعد لكنني مرن.'),
        jsonb_build_object('value_key','spontaneous', 'title','عفوي',      'text','أفضل ترك الأمور مفتوحة والتكيف.')
      ),
      'conflict_resolution_style', jsonb_build_array(
        jsonb_build_object('value_key','cool_off', 'title','تهدئة',     'text','قليل من المساحة أولًا يساعدني على الهدوء.'),
        jsonb_build_object('value_key','talk_soon','title','حديث سريع', 'text','الحديث قريبًا يساعدني على الشعور بالاطمئنان.'),
        jsonb_build_object('value_key','mediate',  'title','تواصل لطيف', 'text','تواصل لطيف في الوقت المناسب يساعد أكثر.')
      )
    )
  )
)
ON CONFLICT (template_key, locale) DO UPDATE
SET body = EXCLUDED.body;

-- ---------------------------------------------------------------------
-- 9) Function permissions (RPC-only)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.preference_responses_submit(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preference_reports_generate(text, text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preference_reports_get_for_home(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preference_reports_list_for_home(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preference_reports_acknowledge(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preference_reports_edit_section_text(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preference_templates_get_for_user(text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.preference_responses_submit(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preference_reports_generate(text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preference_reports_get_for_home(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preference_reports_list_for_home(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preference_reports_acknowledge(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preference_reports_edit_section_text(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preference_templates_get_for_user(text) TO authenticated;

-- ---------------------------------------------------------------------
-- 10) Retention + Cron
-- - Prune preference_report_revisions:
--   keep last 180 days AND always keep 20 newest per report
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
DECLARE
  v_job_id integer;
BEGIN
  BEGIN
    SELECT j.jobid
      INTO v_job_id
      FROM cron.job j
     WHERE j.jobname = 'preference_report_revisions_retention'
     LIMIT 1;

    IF v_job_id IS NOT NULL THEN
      PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
      'preference_report_revisions_retention',
      '0 3 * * *',
      $cmd$
      WITH ranked AS (
        SELECT
          id,
          report_id,
          edited_at,
          row_number() OVER (
            PARTITION BY report_id
            ORDER BY edited_at DESC
          ) AS rn
        FROM public.preference_report_revisions
      ),
      doomed AS (
        SELECT id
        FROM ranked
        WHERE rn > 20
          AND edited_at < now() - interval '180 days'
      )
      DELETE FROM public.preference_report_revisions r
      USING doomed d
      WHERE r.id = d.id;
      $cmd$
    );
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE NOTICE 'Skipping pg_cron schedule: cron.job unavailable or insufficient privileges.';
  END;
END
$$;
