-- Backend authority for AI command quota and unsupported-intent discovery.
-- This adds:
-- - a per-user/day AI command quota ledger keyed by request_id
-- - an unrecognized_intents audit table for feature discovery
-- - internal helpers for quota status, quota charging, and unknown-intent logging
-- - paywall_status_get alignment to expose userQuotas.ai_command_requests

CREATE TABLE IF NOT EXISTS public.command_ai_requests (
  user_id      uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quota_date   date        NOT NULL,
  request_id   uuid        NOT NULL,
  charged_at   timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, quota_date, request_id)
);

COMMENT ON TABLE public.command_ai_requests IS
  'Per-user AI command quota ledger keyed by UTC quota day and stable request_id.';

COMMENT ON COLUMN public.command_ai_requests.quota_date IS
  'UTC calendar date for quota charging.';

ALTER TABLE public.command_ai_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.command_ai_requests FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.command_ai_requests TO service_role;

CREATE INDEX IF NOT EXISTS command_ai_requests_user_date_idx
  ON public.command_ai_requests (user_id, quota_date);

CREATE TABLE IF NOT EXISTS public.unrecognized_intents (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id            uuid        NOT NULL,
  user_id               uuid        REFERENCES public.profiles(id) ON DELETE SET NULL,
  home_id               uuid        REFERENCES public.homes(id) ON DELETE CASCADE,
  input_mode            text        NOT NULL CHECK (input_mode IN ('text', 'voice')),
  raw_text              text,
  transcript_text       text,
  locale                text,
  timezone              text,
  classifier_intent     text        NOT NULL DEFAULT 'unknown',
  classifier_confidence text        NOT NULL DEFAULT 'low',
  router_version        text,
  model_provider        text,
  model_name            text,
  created_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.unrecognized_intents IS
  'Audit/discovery log for unsupported or low-confidence command requests.';

ALTER TABLE public.unrecognized_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.unrecognized_intents FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.unrecognized_intents TO service_role;

CREATE INDEX IF NOT EXISTS unrecognized_intents_home_created_idx
  ON public.unrecognized_intents (home_id, created_at DESC);

CREATE INDEX IF NOT EXISTS unrecognized_intents_user_created_idx
  ON public.unrecognized_intents (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public._command_ai_quota_limit()
RETURNS integer
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_raw text := NULLIF(current_setting('app.settings.command_ai_quota_daily_limit', true), '');
  v_limit integer;
BEGIN
  IF v_raw IS NULL THEN
    RETURN 5;
  END IF;

  BEGIN
    v_limit := v_raw::integer;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN 5;
  END;

  IF v_limit < 0 THEN
    RETURN 5;
  END IF;

  RETURN v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public._command_ai_quota_limit() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_ai_quota_date(p_now timestamptz DEFAULT now())
RETURNS date
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT (timezone('UTC', COALESCE(p_now, now())))::date;
$$;

REVOKE ALL ON FUNCTION public._command_ai_quota_date(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_ai_quota_resets_at(p_now timestamptz DEFAULT now())
RETURNS timestamptz
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT (
    (date_trunc('day', timezone('UTC', COALESCE(p_now, now()))) + interval '1 day')
    AT TIME ZONE 'UTC'
  );
$$;

REVOKE ALL ON FUNCTION public._command_ai_quota_resets_at(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_ai_quota_status(
  p_home_id uuid,
  p_user_id uuid DEFAULT auth.uid(),
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id      uuid := COALESCE(p_user_id, auth.uid());
  v_quota_date   date := public._command_ai_quota_date(p_now);
  v_limit        integer := public._command_ai_quota_limit();
  v_used         integer := 0;
  v_bypassed     boolean := public._home_is_premium(p_home_id);
BEGIN
  PERFORM public.api_assert(v_user_id IS NOT NULL, 'UNAUTHORIZED', 'Authentication required', '28000');

  SELECT count(*)::integer
    INTO v_used
    FROM public.command_ai_requests car
   WHERE car.user_id = v_user_id
     AND car.quota_date = v_quota_date;

  RETURN jsonb_build_object(
    'used', v_used,
    'limit', v_limit,
    'resets_at', public._command_ai_quota_resets_at(p_now),
    'window', 'utc_calendar_day',
    'bypassed_by_premium_home', v_bypassed
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_ai_quota_status(uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_ai_quota_charge(
  p_home_id uuid,
  p_request_id uuid,
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_quota_date   date := public._command_ai_quota_date(p_now);
  v_limit        integer := public._command_ai_quota_limit();
  v_used         integer := 0;
  v_bypassed     boolean := public._home_is_premium(p_home_id);
  v_lock_key     bigint;
BEGIN
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public.api_assert(v_user_id IS NOT NULL, 'UNAUTHORIZED', 'Authentication required', '28000');
  PERFORM public.api_assert(p_request_id IS NOT NULL, 'INVALID_REQUEST_ID', 'request_id is required.', '22023');

  IF v_bypassed THEN
    RETURN public._command_ai_quota_status(p_home_id, v_user_id, p_now);
  END IF;

  v_lock_key := hashtextextended(v_user_id::text || ':' || v_quota_date::text, 0);
  PERFORM pg_catalog.pg_advisory_xact_lock(v_lock_key);

  IF EXISTS (
    SELECT 1
      FROM public.command_ai_requests car
     WHERE car.user_id = v_user_id
       AND car.quota_date = v_quota_date
       AND car.request_id = p_request_id
  ) THEN
    RETURN public._command_ai_quota_status(p_home_id, v_user_id, p_now);
  END IF;

  SELECT count(*)::integer
    INTO v_used
    FROM public.command_ai_requests car
   WHERE car.user_id = v_user_id
     AND car.quota_date = v_quota_date;

  IF v_used >= v_limit THEN
    PERFORM public.api_error(
      'paywall_ai_command_daily_limit',
      'Daily AI command quota reached.',
      'P0001',
      jsonb_build_object(
        'metric', 'ai_command_requests',
        'used', v_used,
        'limit', v_limit,
        'resets_at', public._command_ai_quota_resets_at(p_now)
      )
    );
  END IF;

  INSERT INTO public.command_ai_requests (user_id, quota_date, request_id, charged_at)
  VALUES (v_user_id, v_quota_date, p_request_id, COALESCE(p_now, now()))
  ON CONFLICT (user_id, quota_date, request_id) DO NOTHING;

  RETURN public._command_ai_quota_status(p_home_id, v_user_id, p_now);
END;
$$;

REVOKE ALL ON FUNCTION public._command_ai_quota_charge(uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_ai_quota_release(
  p_request_id uuid,
  p_user_id uuid DEFAULT auth.uid(),
  p_now timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_user_id, auth.uid());
  v_quota_date date := public._command_ai_quota_date(p_now);
  v_lock_key bigint;
BEGIN
  PERFORM public.api_assert(v_user_id IS NOT NULL, 'UNAUTHORIZED', 'Authentication required', '28000');
  PERFORM public.api_assert(p_request_id IS NOT NULL, 'INVALID_REQUEST_ID', 'request_id is required.', '22023');

  v_lock_key := hashtextextended(v_user_id::text || ':' || v_quota_date::text, 0);
  PERFORM pg_catalog.pg_advisory_xact_lock(v_lock_key);

  DELETE FROM public.command_ai_requests car
   WHERE car.user_id = v_user_id
     AND car.quota_date = v_quota_date
     AND car.request_id = p_request_id;
END;
$$;

REVOKE ALL ON FUNCTION public._command_ai_quota_release(uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_log_unrecognized_intent(
  p_home_id uuid,
  p_request_id uuid,
  p_input_mode text,
  p_raw_text text DEFAULT NULL,
  p_transcript_text text DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_timezone text DEFAULT NULL,
  p_classifier_intent text DEFAULT 'unknown',
  p_classifier_confidence text DEFAULT 'low',
  p_router_version text DEFAULT NULL,
  p_model_provider text DEFAULT NULL,
  p_model_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_id uuid;
BEGIN
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public.api_assert(p_request_id IS NOT NULL, 'INVALID_REQUEST_ID', 'request_id is required.', '22023');
  PERFORM public.api_assert(p_input_mode IN ('text', 'voice'), 'INVALID_INPUT_MODE', 'input_mode must be text or voice.', '22023');

  INSERT INTO public.unrecognized_intents (
    request_id,
    user_id,
    home_id,
    input_mode,
    raw_text,
    transcript_text,
    locale,
    timezone,
    classifier_intent,
    classifier_confidence,
    router_version,
    model_provider,
    model_name
  )
  VALUES (
    p_request_id,
    v_user_id,
    p_home_id,
    p_input_mode,
    p_raw_text,
    p_transcript_text,
    p_locale,
    p_timezone,
    COALESCE(NULLIF(btrim(p_classifier_intent), ''), 'unknown'),
    COALESCE(NULLIF(btrim(p_classifier_confidence), ''), 'low'),
    p_router_version,
    p_model_provider,
    p_model_name
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public._command_log_unrecognized_intent(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.paywall_status_get(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan        text;
  v_expires_at  timestamptz;
  v_now         timestamptz := now();
  v_user_quota  jsonb;
BEGIN
  PERFORM public._assert_home_member(p_home_id);

  SELECT COALESCE(he.plan, 'free'), he.expires_at
    INTO v_plan, v_expires_at
    FROM public.home_entitlements he
   WHERE he.home_id = p_home_id;

  v_plan := COALESCE(v_plan, 'free');
  v_user_quota := public._command_ai_quota_status(p_home_id, auth.uid(), v_now);

  RETURN jsonb_strip_nulls(
    jsonb_build_object(
      'plan', v_plan,
      'expires_at', v_expires_at,
      'is_premium', (v_plan <> 'free' AND (v_expires_at IS NULL OR v_expires_at > v_now)),
      'usage', COALESCE((
        SELECT jsonb_build_object(
          'active_chores',   c.active_chores,
          'chore_photos',    c.chore_photos,
          'active_members',  c.active_members,
          'active_expenses', c.active_expenses,
          'expense_photos',  c.expense_photos,
          'updated_at',      c.updated_at
        )
        FROM public.home_usage_counters c
        WHERE c.home_id = p_home_id
      ), jsonb_build_object(
        'active_chores', 0,
        'chore_photos', 0,
        'active_members', 0,
        'active_expenses', 0,
        'expense_photos', 0,
        'updated_at', v_now
      )),
      'limits', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'metric',    x.metric::text,
            'max_value', x.max_value
          )
          ORDER BY x.metric::text
        )
        FROM (
          SELECT l.metric, l.max_value
          FROM public.home_plan_limits l
          WHERE l.plan = v_plan
        ) x
      ), '[]'::jsonb),
      'userQuotas', jsonb_build_object(
        'ai_command_requests', v_user_quota
      )
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.paywall_status_get(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.paywall_status_get(uuid)
  TO authenticated, service_role;
