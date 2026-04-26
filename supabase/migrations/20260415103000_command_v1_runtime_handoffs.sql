-- V1 command runtime contract:
-- - exactly one actionable result per submit
-- - result.kind is the canonical UI branch
-- - pending actionable flows persist in command_handoffs
-- - resume/cancel RPCs restore or dismiss pending handoffs
-- Pre-release note:
-- - legacy pending handoffs that only used old payload projection columns are
--   intentionally discarded when this migration removes those columns

CREATE TABLE IF NOT EXISTS public.command_handoffs (
  handoff_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  intent text NOT NULL,
  module text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('inline', 'route', 'confirm')),
  status text NOT NULL CHECK (status IN ('pending', 'completed', 'cancelled', 'expired')),
  source_text text NOT NULL,
  confidence numeric(5,4) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  context jsonb NOT NULL DEFAULT '{}'::jsonb,
  resume_token text NOT NULL UNIQUE,
  expires_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.command_handoffs
  ADD COLUMN IF NOT EXISTS context jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.command_handoffs
  DROP COLUMN IF EXISTS fields,
  DROP COLUMN IF EXISTS missing_fields,
  DROP COLUMN IF EXISTS ui_payload,
  DROP COLUMN IF EXISTS route_target;

DROP TRIGGER IF EXISTS trg_command_handoffs_updated_at ON public.command_handoffs;
CREATE TRIGGER trg_command_handoffs_updated_at
BEFORE UPDATE ON public.command_handoffs
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

ALTER TABLE public.command_handoffs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.command_handoffs FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.command_handoffs TO service_role;

CREATE INDEX IF NOT EXISTS ix_command_handoffs_user_home_status
  ON public.command_handoffs (user_id, home_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS ix_command_handoffs_request
  ON public.command_handoffs (request_id, created_at DESC);

CREATE OR REPLACE FUNCTION public._command_confidence_score(p_confidence text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE COALESCE(p_confidence, 'low')
    WHEN 'high' THEN 0.95::numeric
    WHEN 'medium' THEN 0.75::numeric
    ELSE 0.25::numeric
  END;
$$;

REVOKE ALL ON FUNCTION public._command_confidence_score(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_handoff_expires_at(p_kind text)
RETURNS timestamptz
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE p_kind
    WHEN 'route' THEN now() + interval '3 days'
    WHEN 'inline' THEN now() + interval '1 day'
    WHEN 'confirm' THEN now() + interval '1 day'
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public._command_handoff_expires_at(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_result_message(
  p_kind text,
  p_intent text,
  p_module text,
  p_fields jsonb,
  p_is_multi boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_task_title text := NULLIF(COALESCE(p_fields->>'task_title', p_fields->>'title', ''), '');
  v_items_count integer := COALESCE(jsonb_array_length(COALESCE(p_fields->'items', '[]'::jsonb)), 0);
  v_amount text := NULLIF(COALESCE(p_fields->>'amount', ''), '');
BEGIN
  IF p_kind = 'unknown' THEN
    RETURN jsonb_build_object(
      'title_key', 'command.unsupported.title',
      'body_key', 'command.unsupported.body',
      'params', '{}'::jsonb
    );
  END IF;

  IF p_is_multi THEN
    RETURN jsonb_build_object(
      'title_key', 'command.multi_intent.confirm_primary.title',
      'body_key', 'command.multi_intent.confirm_primary.body',
      'params', jsonb_build_object(
        'primary_action',
        CASE p_module
          WHEN 'grocery' THEN 'Add groceries'
          WHEN 'task' THEN 'Create task'
          WHEN 'expense' THEN 'Create expense'
          WHEN 'navigation' THEN 'Open page'
          ELSE 'Continue'
        END
      )
    );
  END IF;

  RETURN CASE
    WHEN p_kind = 'execute' AND p_module = 'grocery' THEN jsonb_build_object(
      'title_key', 'command.grocery.added.title',
      'body_key', 'command.grocery.added.body',
      'params', jsonb_build_object('count', v_items_count)
    )
    WHEN p_kind = 'confirm' AND p_module = 'grocery' THEN jsonb_build_object(
      'title_key', 'command.grocery.confirm.title',
      'body_key', 'command.grocery.confirm.body',
      'params', jsonb_build_object('count', v_items_count)
    )
    WHEN p_kind = 'route' AND p_module = 'grocery' THEN jsonb_build_object(
      'title_key', 'command.grocery.open_list.title',
      'body_key', 'command.grocery.open_list.body',
      'params', jsonb_build_object('count', v_items_count)
    )
    WHEN p_kind = 'execute' AND p_module = 'task' THEN jsonb_build_object(
      'title_key', 'command.task.created.title',
      'body_key', 'command.task.created.body',
      'params', jsonb_build_object('task_title', v_task_title)
    )
    WHEN p_kind = 'inline' AND p_module = 'task' THEN jsonb_build_object(
      'title_key', 'command.task.need_assignee.title',
      'body_key', 'command.task.need_assignee.body',
      'params', jsonb_build_object('task_title', v_task_title)
    )
    WHEN p_kind = 'confirm' AND p_module = 'task' THEN jsonb_build_object(
      'title_key', 'command.task.confirm.title',
      'body_key', 'command.task.confirm.body',
      'params', jsonb_build_object('task_title', v_task_title)
    )
    WHEN p_kind = 'route' AND p_module = 'task' THEN jsonb_build_object(
      'title_key', 'command.task.open_scheduler.title',
      'body_key', 'command.task.open_scheduler.body',
      'params', jsonb_build_object('task_title', v_task_title)
    )
    WHEN p_kind = 'route' AND p_module = 'expense' THEN jsonb_build_object(
      'title_key', 'command.expense.open_editor.title',
      'body_key', 'command.expense.open_editor.body',
      'params', jsonb_build_object('amount', COALESCE(v_amount, ''))
    )
    WHEN p_kind = 'route' AND p_module = 'navigation' THEN jsonb_build_object(
      'title_key', 'command.navigation.open.title',
      'body_key', 'command.navigation.open.body',
      'params', '{}'::jsonb
    )
    ELSE jsonb_build_object(
      'title_key', 'command.generic.title',
      'body_key', 'command.generic.body',
      'params', '{}'::jsonb
    )
  END;
END;
$$;

REVOKE ALL ON FUNCTION public._command_result_message(text, text, text, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_result_build(
  p_kind text,
  p_intent text,
  p_module text,
  p_confidence numeric,
  p_fields jsonb,
  p_missing_fields jsonb,
  p_ui jsonb,
  p_execution jsonb,
  p_is_multi boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'kind', p_kind,
    'intent', CASE WHEN p_kind = 'unknown' THEN NULL ELSE p_intent END,
    'module', CASE WHEN p_kind = 'unknown' THEN NULL ELSE p_module END,
    'confidence', p_confidence,
    'message', public._command_result_message(p_kind, p_intent, p_module, COALESCE(p_fields, '{}'::jsonb), p_is_multi),
    'fields', COALESCE(p_fields, '{}'::jsonb),
    'missing_fields', COALESCE(p_missing_fields, '[]'::jsonb),
    'ui', COALESCE(p_ui, jsonb_build_object('component', NULL, 'target', NULL, 'options', '[]'::jsonb, 'prefill', '{}'::jsonb)),
    'draft', NULL,
    'execution', p_execution,
    'meta', jsonb_build_object(
      'requires_confirmation', (p_kind = 'confirm'),
      'is_multi_intent_detected', p_is_multi,
      'raw_input_retained', true
    )
  );
$$;

REVOKE ALL ON FUNCTION public._command_result_build(text, text, text, numeric, jsonb, jsonb, jsonb, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_handoff_state_result(
  p_handoff public.command_handoffs
)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN jsonb_typeof(COALESCE(p_handoff.context->'result', 'null'::jsonb)) = 'object'
      THEN p_handoff.context->'result'
    ELSE jsonb_build_object(
      'kind', p_handoff.kind,
      'intent', p_handoff.intent,
      'module', p_handoff.module,
      'confidence', p_handoff.confidence,
      'message', public._command_result_message(p_handoff.kind, p_handoff.intent, p_handoff.module, '{}'::jsonb, false),
      'fields', '{}'::jsonb,
      'missing_fields', '[]'::jsonb,
      'ui', jsonb_build_object('component', NULL, 'target', NULL, 'options', '[]'::jsonb, 'prefill', '{}'::jsonb),
      'draft', NULL,
      'execution', NULL,
      'meta', jsonb_build_object(
        'requires_confirmation', (p_handoff.kind = 'confirm'),
        'is_multi_intent_detected', false,
        'raw_input_retained', true
      )
    )
  END;
$$;

REVOKE ALL ON FUNCTION public._command_handoff_state_result(public.command_handoffs)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_attach_handoff(
  p_home_id uuid,
  p_request_id uuid,
  p_source_text text,
  p_result jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_kind text := p_result->>'kind';
  v_user_id uuid := auth.uid();
  v_handoff_id uuid;
  v_resume_token text;
  v_expires_at timestamptz;
  v_source_text text := COALESCE(p_source_text, '');
  v_context jsonb;
BEGIN
  IF v_kind NOT IN ('inline', 'route', 'confirm') THEN
    RETURN p_result;
  END IF;

  v_resume_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_expires_at := public._command_handoff_expires_at(v_kind);
  v_context := jsonb_build_object(
    'result', jsonb_set(COALESCE(p_result, '{}'::jsonb), '{draft}', 'null'::jsonb)
  );

  INSERT INTO public.command_handoffs (
    request_id,
    user_id,
    home_id,
    intent,
    module,
    kind,
    status,
    source_text,
    confidence,
    context,
    resume_token,
    expires_at
  )
  VALUES (
    p_request_id,
    v_user_id,
    p_home_id,
    COALESCE(p_result->>'intent', 'unknown'),
    COALESCE(p_result->>'module', 'navigation'),
    v_kind,
    'pending',
    v_source_text,
    COALESCE((p_result->>'confidence')::numeric, 0),
    v_context,
    v_resume_token,
    v_expires_at
  )
  RETURNING handoff_id INTO v_handoff_id;

  RETURN jsonb_set(
    p_result,
    '{draft}',
    jsonb_build_object(
      'handoff_id', v_handoff_id,
      'resume_token', v_resume_token,
      'expires_at', v_expires_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_attach_handoff(uuid, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_top_level_response(
  p_entrypoint text,
  p_request_id uuid,
  p_result jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'contract_version', '1.0',
    'request_id', p_request_id,
    'entrypoint', p_entrypoint,
    'result', p_result
  );
$$;

REVOKE ALL ON FUNCTION public._command_top_level_response(text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_legacy_to_v1_result(
  p_home_id uuid,
  p_request_id uuid,
  p_source_text text,
  p_legacy jsonb,
  p_confidence numeric,
  p_is_multi boolean DEFAULT false,
  p_force_confirm boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ui_hint jsonb := COALESCE(p_legacy->'ui_hint', '{}'::jsonb);
  v_fields jsonb := COALESCE(p_legacy->'fields', '{}'::jsonb);
  v_missing jsonb := COALESCE(p_legacy->'missing_fields', '[]'::jsonb);
  v_execution jsonb := COALESCE(p_legacy->'execution', NULL);
  v_kind text;
  v_ui jsonb;
  v_result jsonb;
BEGIN
  v_kind := CASE
    WHEN p_force_confirm THEN 'confirm'
    WHEN COALESCE(v_ui_hint->>'type', '') = 'execute' THEN 'execute'
    WHEN COALESCE(v_ui_hint->>'type', '') = 'inline' THEN 'inline'
    WHEN COALESCE(v_ui_hint->>'type', '') = 'confirm' THEN 'confirm'
    WHEN COALESCE(v_ui_hint->>'type', '') = 'route' THEN 'route'
    ELSE 'route'
  END;

  v_ui := jsonb_build_object(
    'component',
    CASE
      WHEN v_kind = 'inline' THEN COALESCE(v_ui_hint->>'component', 'member_picker')
      WHEN v_kind = 'confirm' THEN 'confirmation_card'
      WHEN v_kind = 'unknown' THEN 'capability_suggestions'
      ELSE NULL
    END,
    'target', NULLIF(v_ui_hint->>'target', ''),
    'options',
    CASE
      WHEN v_kind = 'confirm' THEN jsonb_build_array(
        jsonb_build_object('id', 'confirm', 'label', 'Confirm'),
        jsonb_build_object('id', 'cancel', 'label', 'Cancel')
      )
      ELSE COALESCE(v_ui_hint->'options', '[]'::jsonb)
    END,
    'prefill', COALESCE(v_ui_hint->'prefill', v_fields, '{}'::jsonb)
  );

  v_result := public._command_result_build(
    v_kind,
    p_legacy->>'source_intent',
    p_legacy->>'module',
    p_confidence,
    v_fields,
    v_missing,
    v_ui,
    v_execution,
    p_is_multi
  );

  RETURN public._command_attach_handoff(p_home_id, p_request_id, p_source_text, v_result);
END;
$$;

REVOKE ALL ON FUNCTION public._command_legacy_to_v1_result(uuid, uuid, text, jsonb, numeric, boolean, boolean)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_unknown_v1_result(
  p_request_id uuid,
  p_confidence numeric DEFAULT 0.25
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT public._command_result_build(
    'unknown',
    'unknown',
    'navigation',
    p_confidence,
    '{}'::jsonb,
    '[]'::jsonb,
    jsonb_build_object(
      'component', 'capability_suggestions',
      'target', '/home',
      'options', jsonb_build_array(
        jsonb_build_object('id', 'groceries', 'label_key', 'commandCapability_groceries'),
        jsonb_build_object('id', 'expenses', 'label_key', 'commandCapability_expenses'),
        jsonb_build_object('id', 'tasks', 'label_key', 'commandCapability_tasks'),
        jsonb_build_object('id', 'navigation', 'label_key', 'commandCapability_navigation')
      ),
      'prefill', '{}'::jsonb
    ),
    NULL,
    false
  );
$$;

REVOKE ALL ON FUNCTION public._command_unknown_v1_result(uuid, numeric)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_resume_row_to_result(
  p_handoff public.command_handoffs
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_result jsonb := public._command_handoff_state_result(p_handoff);
BEGIN
  v_result := jsonb_set(
    v_result,
    '{draft}',
    jsonb_build_object(
      'handoff_id', p_handoff.handoff_id,
      'resume_token', p_handoff.resume_token,
      'expires_at', p_handoff.expires_at
    )
  );

  RETURN jsonb_set(v_result, '{execution}', 'null'::jsonb, true);
END;
$$;

REVOKE ALL ON FUNCTION public._command_resume_row_to_result(public.command_handoffs)
  FROM PUBLIC, anon, authenticated;

-- Authoritative command runtime helpers begin here. The earlier pipeline
-- migration owns AI infra only; command helper/runtime behavior lives in this
-- handoff migration family.

CREATE OR REPLACE FUNCTION public._command_effective_input(
  p_input_mode text,
  p_raw_text text,
  p_transcript_text text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_raw text := NULLIF(btrim(COALESCE(p_raw_text, '')), '');
  v_transcript text := NULLIF(btrim(COALESCE(p_transcript_text, '')), '');
BEGIN
  IF p_input_mode = 'text' THEN
    RETURN v_raw;
  ELSIF p_input_mode = 'voice' THEN
    RETURN v_transcript;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._command_effective_input(text, text, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_context_value(
  p_user_id uuid,
  p_supplied text,
  p_field text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_value text := NULLIF(btrim(COALESCE(p_supplied, '')), '');
BEGIN
  IF v_value IS NOT NULL THEN
    RETURN v_value;
  END IF;

  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_field = 'timezone' THEN
    SELECT NULLIF(btrim(np.timezone), '')
      INTO v_value
      FROM public.notification_preferences np
     WHERE np.user_id = p_user_id;
  ELSIF p_field = 'locale' THEN
    SELECT NULLIF(btrim(np.locale), '')
      INTO v_value
      FROM public.notification_preferences np
     WHERE np.user_id = p_user_id;
  END IF;

  RETURN v_value;
END;
$$;

REVOKE ALL ON FUNCTION public._command_context_value(uuid, text, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_navigation_target(p_intent text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_intent
    WHEN 'open_house_norms' THEN jsonb_build_object('route_key', 'house_norms', 'target', '/house-norms', 'summary', 'Open house norms')
    WHEN 'view_due_items' THEN jsonb_build_object('route_key', 'today_view', 'target', '/today', 'summary', 'View due items')
    WHEN 'view_service' THEN jsonb_build_object('route_key', 'services_home', 'target', '/services', 'summary', 'Open services')
    ELSE jsonb_build_object('route_key', 'home', 'target', '/home', 'summary', 'I didn''t understand that. Taking you home.')
  END;
$$;

REVOKE ALL ON FUNCTION public._command_navigation_target(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_navigation_result(
  p_request_id uuid,
  p_intent text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_target jsonb := public._command_navigation_target(p_intent);
BEGIN
  RETURN jsonb_build_object(
    'contract_version', '1.1',
    'request_id', p_request_id,
    'source_intent', p_intent,
    'module', 'navigation',
    'status', 'complete',
    'missing_fields', '[]'::jsonb,
    'risk_level', 'low',
    'fields', jsonb_build_object('route_key', v_target->>'route_key'),
    'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
    'ui_hint', jsonb_build_object(
      'type', 'route',
      'component', NULL,
      'target', v_target->>'target',
      'prefill', NULL,
      'options', '[]'::jsonb
    ),
    'summary', v_target->>'summary',
    'policy', jsonb_build_object(
      'suggested_outcome', 'route',
      'requires_confirmation', false,
      'is_executable_now', false,
      'executor', 'none'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_navigation_result(uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_route_placeholder_result(
  p_request_id uuid,
  p_intent text,
  p_module text,
  p_target text,
  p_summary text
)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'contract_version', '1.1',
    'request_id', p_request_id,
    'source_intent', p_intent,
    'module', p_module,
    'status', 'ambiguous',
    'missing_fields', '[]'::jsonb,
    'risk_level', CASE WHEN p_module = 'expense' THEN 'high' ELSE 'medium' END,
    'fields', '{}'::jsonb,
    'resolution', jsonb_build_object('mode', 'route_for_resolution', 'entity_type', 'none'),
    'ui_hint', jsonb_build_object(
      'type', 'route',
      'component', NULL,
      'target', p_target,
      'prefill', NULL,
      'options', '[]'::jsonb
    ),
    'summary', p_summary,
    'policy', jsonb_build_object(
      'suggested_outcome', 'route',
      'requires_confirmation', false,
      'is_executable_now', false,
      'executor', 'none'
    )
  );
$$;

REVOKE ALL ON FUNCTION public._command_route_placeholder_result(uuid, text, text, text, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_grocery_clean_token(p_token text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_value text := lower(COALESCE(p_token, ''));
BEGIN
  v_value := regexp_replace(v_value, '^(add|buy|get|grab|pick up|put|put on|put on the)\s+', '', 'gi');
  v_value := regexp_replace(v_value, '\b(to|the|my|our|a|an|some)\b', ' ', 'gi');
  v_value := regexp_replace(v_value, '^\s*\d+([./]\d+)?\s*', '', 'g');
  v_value := regexp_replace(v_value, '\s+', ' ', 'g');
  v_value := btrim(v_value, ' ,.');
  IF v_value = '' THEN
    RETURN NULL;
  END IF;
  RETURN v_value;
END;
$$;

REVOKE ALL ON FUNCTION public._command_grocery_clean_token(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_grocery_parse_items(p_input text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_input text := lower(COALESCE(p_input, ''));
  v_working text;
  v_token text;
  v_item text;
  v_items text[] := ARRAY[]::text[];
  v_protected text[] := ARRAY[
    'fish and chips',
    'mac and cheese',
    'peanut butter and jelly'
  ];
  v_phrase text;
  v_index integer := 1;
BEGIN
  IF NULLIF(btrim(v_input), '') IS NULL THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'is_ambiguous', false);
  END IF;

  v_working := regexp_replace(v_input, '^\s*(please\s+)?(can you\s+)?', '', 'gi');

  FOREACH v_phrase IN ARRAY v_protected LOOP
    v_working := replace(v_working, v_phrase, '__protected_' || v_index::text || '__');
    v_index := v_index + 1;
  END LOOP;

  v_working := regexp_replace(v_working, '\b(and|then|plus)\b', ',', 'gi');
  v_working := regexp_replace(v_working, '[;/]+', ',', 'g');

  FOREACH v_token IN ARRAY regexp_split_to_array(v_working, '\s*,\s*') LOOP
    v_item := v_token;
    v_index := 1;
    FOREACH v_phrase IN ARRAY v_protected LOOP
      v_item := replace(v_item, '__protected_' || v_index::text || '__', v_phrase);
      v_index := v_index + 1;
    END LOOP;

    v_item := public._command_grocery_clean_token(v_item);
    IF v_item IS NOT NULL AND NOT (v_item = ANY(v_items)) THEN
      v_items := array_append(v_items, v_item);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'items',
    COALESCE(to_jsonb(v_items), '[]'::jsonb),
    'is_ambiguous',
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_grocery_parse_items(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_default_grocery_scope(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_shared_unit_id uuid;
BEGIN
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
    INTO v_membership_id
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.user_id = v_user
     AND m.is_current = true
   LIMIT 1;

  IF v_membership_id IS NULL THEN
    RETURN jsonb_build_object('scope_type', 'house', 'unit_id', NULL);
  END IF;

  SELECT hu.id
    INTO v_shared_unit_id
    FROM public.home_units hu
    JOIN public.home_unit_members hum
      ON hum.unit_id = hu.id
   WHERE hu.home_id = p_home_id
     AND hu.unit_type = 'shared'
     AND hu.archived_at IS NULL
     AND hum.membership_id = v_membership_id
     AND hum.is_active_shared = true
   LIMIT 1;

  IF v_shared_unit_id IS NOT NULL THEN
    RETURN jsonb_build_object('scope_type', 'unit', 'unit_id', v_shared_unit_id);
  END IF;

  RETURN jsonb_build_object('scope_type', 'house', 'unit_id', NULL);
END;
$$;

REVOKE ALL ON FUNCTION public._command_default_grocery_scope(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_grocery_preflight(
  p_home_id uuid,
  p_items text[],
  p_scope_type text,
  p_unit_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_item text;
  v_confirm_items jsonb := '[]'::jsonb;
  v_memory jsonb;
BEGIN
  FOREACH v_item IN ARRAY COALESCE(p_items, ARRAY[]::text[]) LOOP
    BEGIN
      v_memory := public._shopping_list__purchase_memory_payload(
        p_home_id,
        p_scope_type,
        p_unit_id,
        v_item
      );
    EXCEPTION WHEN OTHERS THEN
      v_memory := NULL;
    END;

    IF v_memory IS NOT NULL THEN
      v_confirm_items := v_confirm_items || jsonb_build_array(
        jsonb_build_object(
          'name', v_item,
          'purchase_memory', v_memory
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'requires_confirmation', jsonb_array_length(v_confirm_items) > 0,
    'confirm_items', v_confirm_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_grocery_preflight(uuid, text[], text, uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_extract_title(p_input text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_value text := lower(COALESCE(p_input, ''));
BEGIN
  v_value := regexp_replace(v_value, '^\s*(please\s+)?(can you\s+)?', '', 'gi');
  v_value := regexp_replace(v_value, '^\s*(create\s+task|add\s+task|task|todo|remind(?:\s+me)?\s+to)\s+', '', 'gi');
  v_value := regexp_replace(v_value, '\s+(for me|assign to me|for [a-z0-9 .''-]+)$', '', 'gi');
  v_value := regexp_replace(v_value, '\s+', ' ', 'g');
  v_value := btrim(v_value, ' .');
  IF v_value = '' THEN
    RETURN NULL;
  END IF;
  RETURN v_value;
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_extract_title(text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_assignee_options(p_home_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.user_id,
        'label', a.full_name
      )
      ORDER BY a.full_name
    ),
    '[]'::jsonb
  )
  FROM public.home_assignees_list(p_home_id) a;
$$;

REVOKE ALL ON FUNCTION public._command_task_assignee_options(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_detect_assignee(
  p_home_id uuid,
  p_input text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_input text := lower(COALESCE(p_input, ''));
  v_user uuid := auth.uid();
  v_candidate record;
BEGIN
  IF v_input ~ '\b(for me|assign to me)\b' THEN
    RETURN v_user;
  END IF;

  FOR v_candidate IN
    SELECT a.user_id, lower(a.full_name) AS full_name
      FROM public.home_assignees_list(p_home_id) a
  LOOP
    IF v_candidate.full_name IS NOT NULL
       AND v_candidate.full_name <> ''
       AND v_input ~ ('\m' || regexp_replace(v_candidate.full_name, '\s+', '\\s+', 'g') || '\M') THEN
      RETURN v_candidate.user_id;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_detect_assignee(uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_detect_assignee_hint(
  p_home_id uuid,
  p_assignee_hint text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hint text := lower(NULLIF(btrim(COALESCE(p_assignee_hint, '')), ''));
  v_user uuid := auth.uid();
  v_candidate record;
BEGIN
  IF v_hint IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_hint IN ('me', 'myself', 'self') THEN
    RETURN v_user;
  END IF;

  FOR v_candidate IN
    SELECT a.user_id, lower(a.full_name) AS full_name
      FROM public.home_assignees_list(p_home_id) a
  LOOP
    IF v_candidate.full_name IS NOT NULL
       AND v_candidate.full_name <> ''
       AND (
         v_hint = v_candidate.full_name
         OR v_hint ~ ('\m' || regexp_replace(v_candidate.full_name, '\s+', '\\s+', 'g') || '\M')
       ) THEN
      RETURN v_candidate.user_id;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_detect_assignee_hint(uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_start_date_from_parse(
  p_parser_result jsonb
)
RETURNS date
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_parser_result IS NULL THEN NULL
    WHEN COALESCE(p_parser_result->>'start_date', '') ~ '^\d{4}-\d{2}-\d{2}$'
      THEN (p_parser_result->>'start_date')::date
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public._command_task_start_date_from_parse(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_recurrence_interval_from_parse(
  p_parser_result jsonb
)
RETURNS public.recurrence_interval
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_every integer;
  v_unit text;
BEGIN
  IF p_parser_result IS NULL THEN
    RETURN 'none'::public.recurrence_interval;
  END IF;

  v_every := CASE
    WHEN jsonb_typeof(COALESCE(p_parser_result->'recurrence_every', 'null'::jsonb)) = 'number'
      THEN (p_parser_result->>'recurrence_every')::integer
    ELSE NULL
  END;
  v_unit := NULLIF(btrim(COALESCE(p_parser_result->>'recurrence_unit', '')), '');

  CASE
    WHEN v_every = 1 AND v_unit = 'day' THEN RETURN 'daily'::public.recurrence_interval;
    WHEN v_every = 1 AND v_unit = 'week' THEN RETURN 'weekly'::public.recurrence_interval;
    WHEN v_every = 2 AND v_unit = 'week' THEN RETURN 'every_2_weeks'::public.recurrence_interval;
    WHEN v_every = 1 AND v_unit = 'month' THEN RETURN 'monthly'::public.recurrence_interval;
    WHEN v_every = 2 AND v_unit = 'month' THEN RETURN 'every_2_months'::public.recurrence_interval;
    WHEN v_every = 1 AND v_unit = 'year' THEN RETURN 'annual'::public.recurrence_interval;
    ELSE RETURN 'none'::public.recurrence_interval;
  END CASE;
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_recurrence_interval_from_parse(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_route_result(
  p_home_id uuid,
  p_request_id uuid,
  p_source_intent text,
  p_effective_input text,
  p_parser_result jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_interpretation jsonb := public._command_task_interpretation(p_home_id, p_effective_input, p_parser_result);
  v_title text := NULLIF(btrim(COALESCE(v_interpretation->>'task_title', '')), '');
  v_notes text := NULLIF(btrim(COALESCE(v_interpretation->>'notes', '')), '');
  v_assignee uuid := NULLIF(COALESCE(v_interpretation->>'assigned_to', ''), '')::uuid;
  v_due_at date := NULLIF(COALESCE(v_interpretation->>'due_at', ''), '')::date;
  v_recurrence_every integer := CASE
    WHEN jsonb_typeof(COALESCE(p_parser_result->'recurrence_every', 'null'::jsonb)) = 'number'
      THEN (p_parser_result->>'recurrence_every')::integer
    ELSE NULL
  END;
  v_recurrence_unit text := NULLIF(btrim(COALESCE(p_parser_result->>'recurrence_unit', '')), '');
BEGIN
  RETURN jsonb_build_object(
    'contract_version', '1.1',
    'request_id', p_request_id,
    'source_intent', p_source_intent,
    'module', 'task',
    'status', 'ambiguous',
    'missing_fields', '[]'::jsonb,
    'risk_level', 'medium',
    'fields', jsonb_strip_nulls(jsonb_build_object(
      'task_title', v_title,
      'assigned_to', v_assignee,
      'due_at', v_due_at,
      'notes', v_notes,
      'recurrence_every', v_recurrence_every,
      'recurrence_unit', v_recurrence_unit
    )),
    'resolution', jsonb_build_object('mode', 'route_for_resolution', 'entity_type', 'none'),
    'ui_hint', jsonb_build_object(
      'type', 'route',
      'component', NULL,
      'target', '/today',
      'prefill', jsonb_strip_nulls(jsonb_build_object(
        'task_title', v_title,
        'assigned_to', v_assignee,
        'due_at', v_due_at,
        'notes', v_notes,
        'recurrence_every', v_recurrence_every,
        'recurrence_unit', v_recurrence_unit
      )),
      'options', '[]'::jsonb
    ),
    'summary', 'Open task flow for date-aware or recurring task setup',
    'policy', jsonb_build_object(
      'suggested_outcome', 'route',
      'requires_confirmation', false,
      'is_executable_now', false,
      'executor', 'none'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_route_result(uuid, uuid, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_interpretation(
  p_home_id uuid,
  p_effective_input text,
  p_parser_result jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_title text := COALESCE(
    NULLIF(btrim(COALESCE(p_parser_result->>'task_title', '')), ''),
    public._command_task_extract_title(p_effective_input)
  );
  v_notes text := NULLIF(btrim(COALESCE(p_parser_result->>'notes', '')), '');
  v_assignee uuid := COALESCE(
    public._command_task_detect_assignee_hint(p_home_id, p_parser_result->>'assignee_hint'),
    public._command_task_detect_assignee(p_home_id, p_effective_input)
  );
  v_due_at date := public._command_task_start_date_from_parse(p_parser_result);
  v_recurrence public.recurrence_interval := public._command_task_recurrence_interval_from_parse(p_parser_result);
BEGIN
  RETURN jsonb_build_object(
    'task_title', v_title,
    'notes', v_notes,
    'assigned_to', v_assignee,
    'due_at', v_due_at,
    'recurrence_interval', v_recurrence,
    'is_date_aware',
      (
        v_due_at IS NOT NULL
        OR v_recurrence <> 'none'::public.recurrence_interval
        OR p_effective_input ~ '\b(today|tomorrow|tonight|this evening|next week|by [a-z]+)\b'
      )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_interpretation(uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_pipeline_call(
  p_home_id uuid,
  p_request_id uuid,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url text := NULLIF(current_setting('app.settings.supabase_url', true), '');
  v_secret text := NULLIF(current_setting('app.settings.worker_shared_secret', true), '');
  v_req_id bigint;
  v_started timestamptz := clock_timestamp();
  v_deadline interval := interval '12 seconds';
  v_status_code integer;
  v_content text;
  v_error_msg text;
  v_body jsonb;
BEGIN
  PERFORM public.api_assert(
    v_supabase_url IS NOT NULL,
    'classification_failed',
    'Missing app.settings.supabase_url.',
    'P0001'
  );

  PERFORM public.api_assert(
    v_secret IS NOT NULL,
    'classification_failed',
    'Missing app.settings.worker_shared_secret.',
    'P0001'
  );

  v_req_id := net.http_post(
    url := v_supabase_url || '/functions/v1/command_ai_sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', v_secret
    ),
    body := jsonb_build_object(
      'request_id', p_request_id,
      'home_id', p_home_id,
      'feature_key', 'command',
      'payload', p_payload
    )
  );

  LOOP
    SELECT r.status_code, r.content, r.error_msg
      INTO v_status_code, v_content, v_error_msg
    FROM net._http_response r
    WHERE r.id = v_req_id
    ORDER BY r.created DESC
    LIMIT 1;

    EXIT WHEN v_status_code IS NOT NULL
           OR v_error_msg IS NOT NULL
           OR clock_timestamp() - v_started > v_deadline;

    PERFORM pg_sleep(0.10);
  END LOOP;

  IF v_error_msg IS NOT NULL THEN
    PERFORM public.api_error(
      'classification_failed',
      'Command AI pipeline request failed.',
      'P0001',
      jsonb_build_object('error', v_error_msg, 'request_id', v_req_id)
    );
  END IF;

  PERFORM public.api_assert(
    v_status_code IS NOT NULL,
    'classification_failed',
    'Command AI pipeline request timed out.',
    'P0001',
    jsonb_build_object('request_id', v_req_id)
  );

  PERFORM public.api_assert(
    v_status_code BETWEEN 200 AND 299,
    'classification_failed',
    'Command AI pipeline returned non-success status.',
    'P0001',
    jsonb_build_object('status_code', v_status_code, 'body', v_content)
  );

  BEGIN
    v_body := COALESCE(v_content, '{}')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    PERFORM public.api_error(
      'classification_failed',
      'Command AI pipeline returned invalid JSON.',
      'P0001',
      jsonb_build_object('status_code', v_status_code, 'body', v_content)
    );
  END;

  PERFORM public.api_assert(
    COALESCE((v_body->>'ok')::boolean, false),
    'classification_failed',
    'Command AI pipeline reported failure.',
    'P0001',
    COALESCE(v_body->'details', '{}'::jsonb)
  );

  RETURN v_body;
END;
$$;

REVOKE ALL ON FUNCTION public._command_pipeline_call(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_pipeline_parser_result_for_intent(
  p_pipeline jsonb,
  p_intent text
)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT item->'parsed'
  FROM jsonb_array_elements(COALESCE(p_pipeline->'intent_work_items', '[]'::jsonb)) AS item
  WHERE item->>'intent' = p_intent
    AND jsonb_typeof(item->'parsed') = 'object'
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public._command_pipeline_parser_result_for_intent(jsonb, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_grocery_items_from_parse(p_parse jsonb)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_item jsonb;
  v_name text;
  v_items text[] := ARRAY[]::text[];
BEGIN
  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(p_parse->'items', '[]'::jsonb))
  LOOP
    v_name := NULL;

    IF jsonb_typeof(v_item) = 'string' THEN
      v_name := NULLIF(btrim(v_item #>> '{}'), '');
    ELSIF jsonb_typeof(v_item) = 'object' THEN
      v_name := COALESCE(
        NULLIF(btrim(COALESCE(v_item->>'canonical_name', '')), ''),
        NULLIF(btrim(COALESCE(v_item->>'raw_text', '')), '')
      );
    END IF;

    IF v_name IS NOT NULL AND array_position(v_items, v_name) IS NULL THEN
      v_items := array_append(v_items, v_name);
    END IF;
  END LOOP;

  RETURN v_items;
END;
$$;

REVOKE ALL ON FUNCTION public._command_grocery_items_from_parse(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_grocery_result_pipeline(
  p_home_id uuid,
  p_request_id uuid,
  p_raw_input text,
  p_parser_result jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_parse jsonb := COALESCE(p_parser_result, public._command_grocery_parse_items(p_raw_input));
  v_items text[] := public._command_grocery_items_from_parse(v_parse);
  v_scope jsonb;
  v_scope_type text;
  v_unit_id uuid;
  v_preflight jsonb;
  v_item text;
  v_results jsonb := '[]'::jsonb;
BEGIN
  v_scope := public._command_default_grocery_scope(p_home_id);
  v_scope_type := v_scope->>'scope_type';
  v_unit_id := NULLIF(v_scope->>'unit_id', '')::uuid;

  IF COALESCE(array_length(v_items, 1), 0) = 0 THEN
    RETURN public._command_route_placeholder_result(
      p_request_id,
      'add_grocery_items',
      'grocery',
      '/shopping-list',
      'Open shopping list'
    );
  END IF;

  v_preflight := public._command_grocery_preflight(p_home_id, v_items, v_scope_type, v_unit_id);
  IF COALESCE((v_preflight->>'requires_confirmation')::boolean, false) THEN
    RETURN jsonb_build_object(
      'contract_version', '1.1',
      'request_id', p_request_id,
      'source_intent', 'add_grocery_items',
      'module', 'grocery',
      'status', 'ambiguous',
      'missing_fields', '[]'::jsonb,
      'risk_level', 'low',
      'fields', jsonb_build_object(
        'items', to_jsonb(v_items),
        'scope_type', v_scope_type,
        'unit_id', v_unit_id,
        'raw_input', p_raw_input
      ),
      'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
      'ui_hint', jsonb_build_object(
        'type', 'confirm',
        'component', 'grocery_confirm_recent_purchase',
        'target', NULL,
        'prefill', jsonb_build_object('confirm_items', v_preflight->'confirm_items'),
        'options', '[]'::jsonb
      ),
      'summary', 'Confirm grocery items before adding them',
      'policy', jsonb_build_object('suggested_outcome', 'confirm', 'requires_confirmation', true, 'is_executable_now', false, 'executor', 'shopping_list_add_item_v3')
    );
  END IF;

  FOREACH v_item IN ARRAY v_items LOOP
    v_results := v_results || jsonb_build_array(
      public.shopping_list_add_item_v3(
        p_home_id,
        v_item,
        NULL,
        NULL,
        NULL,
        v_scope_type,
        v_unit_id,
        false
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'contract_version', '1.1',
    'request_id', p_request_id,
    'source_intent', 'add_grocery_items',
    'module', 'grocery',
    'status', 'complete',
    'missing_fields', '[]'::jsonb,
    'risk_level', 'low',
    'fields', jsonb_build_object(
      'items', to_jsonb(v_items),
      'scope_type', v_scope_type,
      'unit_id', v_unit_id,
      'raw_input', p_raw_input
    ),
    'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
    'ui_hint', jsonb_build_object('type', 'execute', 'component', NULL, 'target', NULL, 'prefill', NULL, 'options', '[]'::jsonb),
    'summary', format('Added %s to shopping list', array_to_string(v_items, ', ')),
    'policy', jsonb_build_object('suggested_outcome', 'execute', 'requires_confirmation', false, 'is_executable_now', true, 'executor', 'shopping_list_add_item_v3'),
    'execution', jsonb_build_object('results', v_results)
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_grocery_result_pipeline(uuid, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_task_result_pipeline(
  p_home_id uuid,
  p_request_id uuid,
  p_input text,
  p_parser_result jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_interpretation jsonb := public._command_task_interpretation(p_home_id, p_input, p_parser_result);
  v_title text := NULLIF(btrim(COALESCE(v_interpretation->>'task_title', '')), '');
  v_notes text := NULLIF(btrim(COALESCE(v_interpretation->>'notes', '')), '');
  v_assignee uuid := NULLIF(COALESCE(v_interpretation->>'assigned_to', ''), '')::uuid;
  v_start_date date := NULLIF(COALESCE(v_interpretation->>'due_at', ''), '')::date;
  v_recurrence public.recurrence_interval := COALESCE(
    NULLIF(COALESCE(v_interpretation->>'recurrence_interval', ''), '')::public.recurrence_interval,
    'none'::public.recurrence_interval
  );
  v_row public.chores%ROWTYPE;
BEGIN
  IF COALESCE((v_interpretation->>'is_date_aware')::boolean, false) THEN
    RETURN public._command_task_route_result(
      p_home_id,
      p_request_id,
      CASE WHEN v_start_date IS NOT NULL THEN 'create_reminder' ELSE 'create_task' END,
      p_input,
      p_parser_result
    );
  END IF;

  IF v_title IS NULL THEN
    RETURN public._command_route_placeholder_result(
      p_request_id,
      'create_task',
      'task',
      '/today',
      'Open task flow'
    );
  END IF;

  IF v_assignee IS NULL THEN
    RETURN jsonb_build_object(
      'contract_version', '1.1',
      'request_id', p_request_id,
      'source_intent', 'create_task',
      'module', 'task',
      'status', 'missing_fields',
      'missing_fields', jsonb_build_array('assigned_to'),
      'risk_level', 'low',
      'fields', jsonb_build_object(
        'task_title', v_title,
        'assigned_to', NULL,
        'due_at', NULL,
        'notes', v_notes,
        'recurrence_interval', NULLIF(v_recurrence::text, 'none')
      ),
      'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
      'ui_hint', jsonb_build_object(
        'type', 'inline',
        'component', 'member_picker',
        'target', NULL,
        'prefill', NULL,
        'options', public._command_task_assignee_options(p_home_id)
      ),
      'summary', format('Create task: %s', v_title),
      'policy', jsonb_build_object(
        'suggested_outcome', 'inline',
        'requires_confirmation', false,
        'is_executable_now', false,
        'executor', 'chores_create'
      )
    );
  END IF;

  v_row := public.chores_create(
    p_home_id,
    v_title,
    v_assignee,
    current_date,
    v_recurrence,
    NULL,
    v_notes,
    NULL
  );

  RETURN jsonb_build_object(
    'contract_version', '1.1',
    'request_id', p_request_id,
    'source_intent', 'create_task',
    'module', 'task',
    'status', 'complete',
    'missing_fields', '[]'::jsonb,
    'risk_level', 'low',
    'fields', jsonb_build_object(
      'task_title', v_title,
      'assigned_to', v_assignee,
      'due_at', NULL,
      'notes', v_notes,
      'recurrence_interval', v_recurrence
    ),
    'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
    'ui_hint', jsonb_build_object('type', 'execute', 'component', NULL, 'target', NULL, 'prefill', NULL, 'options', '[]'::jsonb),
    'summary', format('Created task: %s', v_title),
    'policy', jsonb_build_object('suggested_outcome', 'execute', 'requires_confirmation', false, 'is_executable_now', true, 'executor', 'chores_create'),
    'execution', jsonb_build_object('chore', to_jsonb(v_row))
  );
END;
$$;

REVOKE ALL ON FUNCTION public._command_task_result_pipeline(uuid, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_module_preview_result_pipeline(
  p_home_id uuid,
  p_request_id uuid,
  p_intent text,
  p_effective_input text,
  p_parser_result jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_parse jsonb := COALESCE(p_parser_result, '{}'::jsonb);
  v_items text[];
  v_scope jsonb;
  v_scope_type text;
  v_unit_id uuid;
  v_preflight jsonb;
  v_interpretation jsonb;
  v_title text;
  v_notes text;
  v_assignee uuid;
  v_start_date date;
BEGIN
  CASE p_intent
    WHEN 'add_grocery_items' THEN
      v_items := public._command_grocery_items_from_parse(
        CASE
          WHEN p_parser_result IS NULL THEN public._command_grocery_parse_items(p_effective_input)
          ELSE v_parse
        END
      );
      v_scope := public._command_default_grocery_scope(p_home_id);
      v_scope_type := v_scope->>'scope_type';
      v_unit_id := NULLIF(v_scope->>'unit_id', '')::uuid;

      IF COALESCE(array_length(v_items, 1), 0) = 0 THEN
        RETURN public._command_route_placeholder_result(
          p_request_id,
          'add_grocery_items',
          'grocery',
          '/shopping-list',
          'Open shopping list'
        );
      END IF;

      v_preflight := public._command_grocery_preflight(p_home_id, v_items, v_scope_type, v_unit_id);
      IF COALESCE((v_preflight->>'requires_confirmation')::boolean, false) THEN
        RETURN jsonb_build_object(
          'contract_version', '1.1',
          'request_id', p_request_id,
          'source_intent', 'add_grocery_items',
          'module', 'grocery',
          'status', 'ambiguous',
          'missing_fields', '[]'::jsonb,
          'risk_level', 'low',
          'fields', jsonb_build_object(
            'items', to_jsonb(v_items),
            'scope_type', v_scope_type,
            'unit_id', v_unit_id,
            'raw_input', p_effective_input
          ),
          'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
          'ui_hint', jsonb_build_object(
            'type', 'confirm',
            'component', 'grocery_confirm_recent_purchase',
            'target', NULL,
            'prefill', jsonb_build_object('confirm_items', v_preflight->'confirm_items'),
            'options', '[]'::jsonb
          ),
          'summary', 'Confirm grocery items before adding them',
          'policy', jsonb_build_object(
            'suggested_outcome', 'confirm',
            'requires_confirmation', true,
            'is_executable_now', false,
            'executor', 'shopping_list_add_item_v3'
          )
        );
      END IF;

      RETURN jsonb_build_object(
        'contract_version', '1.1',
        'request_id', p_request_id,
        'source_intent', 'add_grocery_items',
        'module', 'grocery',
        'status', 'complete',
        'missing_fields', '[]'::jsonb,
        'risk_level', 'low',
        'fields', jsonb_build_object(
          'items', to_jsonb(v_items),
          'scope_type', v_scope_type,
          'unit_id', v_unit_id,
          'raw_input', p_effective_input
        ),
        'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
        'ui_hint', jsonb_build_object('type', 'execute', 'component', NULL, 'target', NULL, 'prefill', NULL, 'options', '[]'::jsonb),
        'summary', format('Add %s to shopping list', array_to_string(v_items, ', ')),
        'policy', jsonb_build_object(
          'suggested_outcome', 'execute',
          'requires_confirmation', false,
          'is_executable_now', true,
          'executor', 'shopping_list_add_item_v3'
        )
      );
    WHEN 'create_task' THEN
      v_interpretation := public._command_task_interpretation(p_home_id, p_effective_input, v_parse);
      v_title := NULLIF(btrim(COALESCE(v_interpretation->>'task_title', '')), '');
      v_notes := NULLIF(btrim(COALESCE(v_interpretation->>'notes', '')), '');
      v_assignee := NULLIF(COALESCE(v_interpretation->>'assigned_to', ''), '')::uuid;
      v_start_date := NULLIF(COALESCE(v_interpretation->>'due_at', ''), '')::date;

      IF COALESCE((v_interpretation->>'is_date_aware')::boolean, false) THEN
        RETURN public._command_task_route_result(
          p_home_id,
          p_request_id,
          CASE WHEN v_start_date IS NOT NULL THEN 'create_reminder' ELSE 'create_task' END,
          p_effective_input,
          v_parse
        );
      END IF;

      IF v_title IS NULL THEN
        RETURN public._command_route_placeholder_result(
          p_request_id,
          'create_task',
          'task',
          '/today',
          'Open task flow'
        );
      END IF;

      IF v_assignee IS NULL THEN
        RETURN jsonb_build_object(
          'contract_version', '1.1',
          'request_id', p_request_id,
          'source_intent', 'create_task',
          'module', 'task',
          'status', 'missing_fields',
          'missing_fields', jsonb_build_array('assigned_to'),
          'risk_level', 'low',
          'fields', jsonb_build_object(
            'task_title', v_title,
            'assigned_to', NULL,
            'due_at', v_start_date,
            'notes', v_notes,
            'recurrence_interval', NULLIF(COALESCE(v_interpretation->>'recurrence_interval', 'none'), 'none')
          ),
          'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
          'ui_hint', jsonb_build_object(
            'type', 'inline',
            'component', 'member_picker',
            'target', NULL,
            'prefill', NULL,
            'options', public._command_task_assignee_options(p_home_id)
          ),
          'summary', format('Create task: %s', v_title),
          'policy', jsonb_build_object(
            'suggested_outcome', 'inline',
            'requires_confirmation', false,
            'is_executable_now', false,
            'executor', 'chores_create'
          )
        );
      END IF;

      RETURN jsonb_build_object(
        'contract_version', '1.1',
        'request_id', p_request_id,
        'source_intent', 'create_task',
        'module', 'task',
        'status', 'complete',
        'missing_fields', '[]'::jsonb,
        'risk_level', 'low',
        'fields', jsonb_build_object(
          'task_title', v_title,
          'assigned_to', v_assignee,
          'due_at', v_start_date,
          'notes', v_notes
        ),
        'resolution', jsonb_build_object('mode', 'not_applicable', 'entity_type', 'none'),
        'ui_hint', jsonb_build_object('type', 'execute', 'component', NULL, 'target', NULL, 'prefill', NULL, 'options', '[]'::jsonb),
        'summary', format('Create task: %s', v_title),
        'policy', jsonb_build_object(
          'suggested_outcome', 'execute',
          'requires_confirmation', false,
          'is_executable_now', true,
          'executor', 'chores_create'
        )
      );
    ELSE
      RETURN public._command_module_result_pipeline(
        p_home_id,
        p_request_id,
        p_intent,
        p_effective_input,
        p_parser_result
      );
  END CASE;
END;
$$;

REVOKE ALL ON FUNCTION public._command_module_preview_result_pipeline(uuid, uuid, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._command_module_result_pipeline(
  p_home_id uuid,
  p_request_id uuid,
  p_intent text,
  p_effective_input text,
  p_parser_result jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  CASE p_intent
    WHEN 'add_grocery_items' THEN
      RETURN public._command_grocery_result_pipeline(p_home_id, p_request_id, p_effective_input, p_parser_result);
    WHEN 'create_task' THEN
      RETURN public._command_task_result_pipeline(p_home_id, p_request_id, p_effective_input, p_parser_result);
    WHEN 'open_house_norms' THEN
      RETURN public._command_navigation_result(p_request_id, p_intent);
    WHEN 'view_due_items' THEN
      RETURN public._command_navigation_result(p_request_id, p_intent);
    WHEN 'view_service' THEN
      RETURN public._command_navigation_result(p_request_id, p_intent);
    WHEN 'mark_task_done' THEN
      RETURN public._command_route_placeholder_result(p_request_id, p_intent, 'task', '/today', 'Open today view to complete a task');
    WHEN 'create_reminder' THEN
      RETURN public._command_task_route_result(
        p_home_id,
        p_request_id,
        p_intent,
        p_effective_input,
        p_parser_result
      );
    WHEN 'create_expense' THEN
      RETURN public._command_route_placeholder_result(p_request_id, p_intent, 'expense', '/expenses', 'Open expense flow');
    ELSE
      RETURN public._command_navigation_result(p_request_id, 'unknown');
  END CASE;
END;
$$;

REVOKE ALL ON FUNCTION public._command_module_result_pipeline(uuid, uuid, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.command_submit_v1(
  p_home_id uuid,
  p_input_mode text,
  p_raw_text text,
  p_transcript_text text,
  p_timezone text,
  p_locale text,
  p_client_timestamp timestamptz,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_quota_now timestamptz := now();
  v_effective_input text;
  v_timezone text;
  v_locale text;
  v_ai jsonb;
  v_pipeline jsonb;
  v_classification jsonb;
  v_parser_result jsonb;
  v_intent text;
  v_intents text[];
  v_confidence numeric;
  v_legacy jsonb;
  v_result jsonb;
BEGIN
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public.api_assert(p_request_id IS NOT NULL, 'invalid_command_input', 'request_id is required.', '22023');
  PERFORM public.api_assert(p_input_mode IN ('text', 'voice'), 'invalid_command_input', 'input_mode must be text or voice.', '22023');

  v_effective_input := public._command_effective_input(p_input_mode, p_raw_text, p_transcript_text);
  PERFORM public.api_assert(v_effective_input IS NOT NULL, 'invalid_command_input', 'Command text is required.', '22023');

  v_timezone := COALESCE(public._command_context_value(v_user_id, p_timezone, 'timezone'), 'UTC');
  v_locale := COALESCE(public._command_context_value(v_user_id, p_locale, 'locale'), 'en');

  PERFORM public._command_ai_quota_charge(p_home_id, p_request_id, v_quota_now);

  BEGIN
    v_ai := public._command_pipeline_call(
      p_home_id,
      p_request_id,
      jsonb_build_object(
        'input_mode', p_input_mode,
        'raw_text', p_raw_text,
        'transcript_text', p_transcript_text,
        'effective_input', v_effective_input,
        'timezone', v_timezone,
        'locale', v_locale,
        'client_timestamp', p_client_timestamp,
        'user_id', v_user_id
      )
    );
  EXCEPTION WHEN OTHERS THEN
    PERFORM public._command_ai_quota_release(p_request_id, v_user_id, v_quota_now);
    RAISE;
  END;

  v_pipeline := COALESCE(v_ai->'result', '{}'::jsonb);
  v_classification := COALESCE(v_pipeline->'classification', '{}'::jsonb);
  v_intent := COALESCE(NULLIF(v_classification->>'primary_intent', ''), NULLIF(v_classification->>'intent', ''), 'unknown');
  v_confidence := public._command_confidence_score(COALESCE(v_classification->>'confidence', 'low'));
  v_parser_result := public._command_pipeline_parser_result_for_intent(v_pipeline, v_intent);

  IF v_intent = 'unknown' OR v_confidence < 0.60 THEN
    PERFORM public._command_log_unrecognized_intent(
      p_home_id,
      p_request_id,
      p_input_mode,
      p_raw_text,
      p_transcript_text,
      v_locale,
      v_timezone,
      COALESCE(NULLIF(v_intent, ''), 'unknown'),
      COALESCE(NULLIF(v_classification->>'confidence', ''), 'low'),
      'command-router-v1',
      COALESCE(v_classification->>'provider', 'unknown'),
      COALESCE(v_classification->>'model', 'unknown')
    );
    v_result := public._command_unknown_v1_result(p_request_id, v_confidence);
    RETURN public._command_top_level_response('command_submit_v1', p_request_id, v_result);
  END IF;

  SELECT COALESCE(array_agg(DISTINCT value), ARRAY[]::text[])
    INTO v_intents
  FROM jsonb_array_elements_text(COALESCE(v_classification->'intents_detected', jsonb_build_array(v_intent)));

  IF COALESCE(array_length(v_intents, 1), 0) > 1 THEN
    v_legacy := public._command_module_preview_result_pipeline(
      p_home_id,
      p_request_id,
      v_intent,
      v_effective_input,
      CASE WHEN v_intent IN ('add_grocery_items', 'create_task', 'create_reminder')
        THEN v_parser_result
        ELSE NULL
      END
    );
    v_result := public._command_legacy_to_v1_result(
      p_home_id,
      p_request_id,
      v_effective_input,
      v_legacy,
      v_confidence,
      true,
      COALESCE(v_legacy->'ui_hint'->>'type', '') = 'execute'
    );
    RETURN public._command_top_level_response('command_submit_v1', p_request_id, v_result);
  END IF;

  v_legacy := public._command_module_result_pipeline(
    p_home_id,
    p_request_id,
    v_intent,
    v_effective_input,
    CASE WHEN v_intent IN ('add_grocery_items', 'create_task', 'create_reminder')
      THEN v_parser_result
      ELSE NULL
    END
  );

  v_result := public._command_legacy_to_v1_result(
    p_home_id,
    p_request_id,
    v_effective_input,
    v_legacy,
    v_confidence,
    false,
    false
  );

  RETURN public._command_top_level_response('command_submit_v1', p_request_id, v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.command_submit_v1(uuid, text, text, text, text, text, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.command_submit_v1(uuid, text, text, text, text, text, timestamptz, uuid)
  TO authenticated;

DROP FUNCTION IF EXISTS public.command_continue_v1(uuid, uuid, text, text, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.command_continue_v1(
  p_handoff_id uuid,
  p_request_id uuid,
  p_user_input jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_handoff public.command_handoffs%ROWTYPE;
  v_home_id uuid;
  v_source_intent text;
  v_source_text text;
  v_module text;
  v_state_result jsonb;
  v_fields jsonb;
  v_action text := COALESCE(NULLIF(btrim(COALESCE(p_user_input->>'action', '')), ''), 'confirm');
  v_title text;
  v_notes text;
  v_assigned_to uuid;
  v_due_at text;
  v_recurrence public.recurrence_interval := 'none'::public.recurrence_interval;
  v_items text[];
  v_scope_type text;
  v_unit_id uuid;
  v_results jsonb := '[]'::jsonb;
  v_item text;
  v_row public.chores%ROWTYPE;
  v_result jsonb;
BEGIN
  PERFORM public.api_assert(p_request_id IS NOT NULL, 'invalid_command_input', 'request_id is required.', '22023');
  PERFORM public.api_assert(p_handoff_id IS NOT NULL, 'invalid_command_input', 'handoff_id is required.', '22023');

  UPDATE public.command_handoffs
     SET status = 'expired'
   WHERE status = 'pending'
     AND expires_at IS NOT NULL
     AND expires_at <= now()
     AND user_id = auth.uid();

  SELECT *
    INTO v_handoff
    FROM public.command_handoffs
   WHERE handoff_id = p_handoff_id
     AND user_id = auth.uid()
     AND status = 'pending'
     AND (expires_at IS NULL OR expires_at > now())
   LIMIT 1;

  PERFORM public.api_assert(v_handoff.handoff_id IS NOT NULL, 'invalid_command_input', 'Pending handoff not found.', '22023');

  v_home_id := v_handoff.home_id;
  v_source_intent := v_handoff.intent;
  v_source_text := v_handoff.source_text;
  v_module := v_handoff.module;
  v_state_result := public._command_handoff_state_result(v_handoff);
  v_fields := COALESCE(v_state_result->'fields', '{}'::jsonb);

  PERFORM public._assert_home_member(v_home_id);

  IF v_action = 'cancel' THEN
    UPDATE public.command_handoffs
       SET status = 'cancelled'
     WHERE handoff_id = v_handoff.handoff_id;
    RETURN NULL;
  END IF;

  IF v_module = 'task' AND v_source_intent = 'create_task' THEN
    v_title := NULLIF(btrim(COALESCE(v_fields->>'task_title', '')), '');
    v_notes := NULLIF(btrim(COALESCE(v_fields->>'notes', '')), '');
    v_due_at := NULLIF(btrim(COALESCE(v_fields->>'due_at', '')), '');
    v_recurrence := COALESCE(
      NULLIF(COALESCE(v_fields->>'recurrence_interval', ''), '')::public.recurrence_interval,
      'none'::public.recurrence_interval
    );
    v_assigned_to := NULLIF(COALESCE(p_user_input->>'assigned_to', p_user_input->>'user_id', v_fields->>'assigned_to', ''), '')::uuid;

    PERFORM public.api_assert(v_title IS NOT NULL, 'invalid_command_input', 'task_title is required for task continuation.', '22023');
    PERFORM public.api_assert(v_assigned_to IS NOT NULL, 'invalid_command_input', 'assigned_to is required for task continuation.', '22023');
    PERFORM public.api_assert(
      EXISTS (
        SELECT 1
          FROM public.memberships m
         WHERE m.home_id = v_home_id
           AND m.user_id = v_assigned_to
           AND m.is_current = true
      ),
      'invalid_command_input',
      'Selected assignee must be a current home member.',
      '22023'
    );

    IF v_due_at IS NOT NULL THEN
      v_result := public._command_attach_handoff(
        v_home_id,
        p_request_id,
        COALESCE(v_source_text, v_title),
        public._command_result_build(
          'route',
          'create_reminder',
          'task',
          COALESCE(v_handoff.confidence, 0.75),
          jsonb_strip_nulls(jsonb_build_object(
            'task_title', v_title,
            'assigned_to', v_assigned_to,
            'due_at', v_due_at,
            'notes', v_notes,
            'recurrence_interval', NULLIF(v_recurrence::text, 'none')
          )),
          '[]'::jsonb,
          jsonb_build_object(
            'component', NULL,
            'target', '/today',
            'options', '[]'::jsonb,
            'prefill', jsonb_strip_nulls(jsonb_build_object(
              'task_title', v_title,
              'assigned_to', v_assigned_to,
              'due_at', v_due_at,
              'notes', v_notes,
              'recurrence_interval', NULLIF(v_recurrence::text, 'none')
            ))
          ),
          NULL,
          false
        )
      );
      UPDATE public.command_handoffs SET status = 'completed' WHERE handoff_id = v_handoff.handoff_id;
      RETURN public._command_top_level_response('command_continue_v1', p_request_id, v_result);
    END IF;

    v_row := public.chores_create(
      v_home_id,
      v_title,
      v_assigned_to,
      current_date,
      v_recurrence,
      NULL,
      v_notes,
      NULL
    );

    UPDATE public.command_handoffs
       SET status = 'completed'
     WHERE handoff_id = v_handoff.handoff_id;

    v_result := public._command_result_build(
      'execute',
      'create_task',
      'task',
      COALESCE(v_handoff.confidence, 0.95),
      jsonb_strip_nulls(jsonb_build_object(
        'task_title', v_title,
        'assigned_to', v_assigned_to,
        'due_at', NULL,
        'notes', v_notes,
        'recurrence_interval', NULLIF(v_recurrence::text, 'none')
      )),
      '[]'::jsonb,
      jsonb_build_object('component', NULL, 'target', NULL, 'options', '[]'::jsonb, 'prefill', '{}'::jsonb),
      jsonb_build_object(
        'entity_type', 'task',
        'entity_ids', jsonb_build_array(v_row.id),
        'results', jsonb_build_array(to_jsonb(v_row))
      ),
      false
    );

    RETURN public._command_top_level_response('command_continue_v1', p_request_id, v_result);
  END IF;

  IF v_module = 'grocery' AND v_source_intent = 'add_grocery_items' THEN
    SELECT COALESCE(array_agg(value), ARRAY[]::text[])
      INTO v_items
      FROM jsonb_array_elements_text(COALESCE(v_fields->'items', '[]'::jsonb));

    v_scope_type := COALESCE(NULLIF(v_fields->>'scope_type', ''), 'house');
    v_unit_id := NULLIF(v_fields->>'unit_id', '')::uuid;

    PERFORM public.api_assert(
      COALESCE((p_user_input->>'confirm')::boolean, v_action = 'confirm'),
      'invalid_command_input',
      'Grocery continuation requires confirm action.',
      '22023'
    );

    FOREACH v_item IN ARRAY v_items LOOP
      v_results := v_results || jsonb_build_array(
        public.shopping_list_add_item_v3(
          v_home_id,
          v_item,
          NULL,
          NULL,
          NULL,
          v_scope_type,
          v_unit_id,
          true
        )
      );
    END LOOP;

    UPDATE public.command_handoffs
       SET status = 'completed'
     WHERE handoff_id = v_handoff.handoff_id;

    v_result := public._command_result_build(
      'execute',
      'add_grocery_items',
      'grocery',
      COALESCE(v_handoff.confidence, 0.95),
      jsonb_build_object('items', to_jsonb(v_items), 'scope_type', v_scope_type, 'unit_id', v_unit_id),
      '[]'::jsonb,
      jsonb_build_object('component', NULL, 'target', NULL, 'options', '[]'::jsonb, 'prefill', '{}'::jsonb),
      jsonb_build_object(
        'entity_type', 'shopping_items',
        'entity_ids', COALESCE((SELECT jsonb_agg(value->>'id') FROM jsonb_array_elements(v_results) value), '[]'::jsonb),
        'results', v_results
      ),
      false
    );

    RETURN public._command_top_level_response('command_continue_v1', p_request_id, v_result);
  END IF;

  PERFORM public.api_error(
    'invalid_command_input',
    'Unsupported handoff continuation.',
    '22023',
    jsonb_build_object('module', v_module, 'intent', v_source_intent)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.command_continue_v1(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.command_continue_v1(uuid, uuid, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.command_resume_v1(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_handoff public.command_handoffs%ROWTYPE;
BEGIN
  PERFORM public._assert_home_member(p_home_id);

  UPDATE public.command_handoffs
     SET status = 'expired'
   WHERE status = 'pending'
     AND expires_at IS NOT NULL
     AND expires_at <= now()
     AND user_id = auth.uid()
     AND home_id = p_home_id;

  SELECT *
    INTO v_handoff
    FROM public.command_handoffs
   WHERE user_id = auth.uid()
     AND home_id = p_home_id
     AND status = 'pending'
     AND (expires_at IS NULL OR expires_at > now())
   ORDER BY updated_at DESC
   LIMIT 1;

  IF v_handoff.handoff_id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN public._command_top_level_response(
    'command_resume_v1',
    v_handoff.request_id,
    public._command_resume_row_to_result(v_handoff)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.command_resume_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.command_resume_v1(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.command_cancel_v1(p_handoff_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_handoff public.command_handoffs%ROWTYPE;
BEGIN
  SELECT *
    INTO v_handoff
    FROM public.command_handoffs
   WHERE handoff_id = p_handoff_id
     AND user_id = auth.uid()
   LIMIT 1;

  PERFORM public.api_assert(v_handoff.handoff_id IS NOT NULL, 'invalid_command_input', 'Handoff not found.', '22023');

  UPDATE public.command_handoffs
     SET status = 'cancelled'
   WHERE handoff_id = p_handoff_id
     AND status = 'pending';

  RETURN jsonb_build_object(
    'handoff_id', p_handoff_id,
    'status', 'cancelled'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.command_cancel_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.command_cancel_v1(uuid)
  TO authenticated;
