-- Full replace of the command-specific AI config/runtime with the internal
-- feature/stage/role pipeline model from command_ai_pipeline_v1.

CREATE TABLE IF NOT EXISTS public.ai_providers (
  provider_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_key text NOT NULL UNIQUE,
  adapter_kind text NOT NULL,
  base_url text NULL,
  secret_name text NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_ai_providers_adapter_kind CHECK (
    adapter_kind = ANY (
      ARRAY[
        'openai_responses'::text,
        'openai_compat_responses'::text,
        'gemini'::text,
        'stub'::text
      ]
    )
  )
);

DROP TRIGGER IF EXISTS trg_ai_providers_updated_at ON public.ai_providers;
CREATE TRIGGER trg_ai_providers_updated_at
BEFORE UPDATE ON public.ai_providers
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

ALTER TABLE public.ai_providers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_providers FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.ai_providers TO service_role;

INSERT INTO public.ai_providers (provider_key, adapter_kind, base_url, secret_name)
VALUES
  ('openai', 'openai_responses', 'https://api.openai.com', 'OPENAI_API_KEY'),
  ('gemini', 'gemini', NULL, 'GEMINI_API_KEY'),
  ('stub', 'stub', NULL, NULL)
ON CONFLICT (provider_key) DO UPDATE
SET adapter_kind = EXCLUDED.adapter_kind,
    base_url = EXCLUDED.base_url,
    secret_name = EXCLUDED.secret_name,
    active = true;

CREATE TABLE IF NOT EXISTS public.ai_models (
  model_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES public.ai_providers(provider_id),
  model_key text NOT NULL,
  supports_structured_output boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_ai_models UNIQUE (provider_id, model_key)
);

DROP TRIGGER IF EXISTS trg_ai_models_updated_at ON public.ai_models;
CREATE TRIGGER trg_ai_models_updated_at
BEFORE UPDATE ON public.ai_models
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

ALTER TABLE public.ai_models ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_models FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.ai_models TO service_role;

INSERT INTO public.ai_models (provider_id, model_key, supports_structured_output)
SELECT p.provider_id, m.model_key, m.supports_structured_output
FROM (
  VALUES
    ('openai', 'gpt-5-nano', true),
    ('openai', 'gpt-5-mini', true),
    ('stub', 'stub-command', true)
) AS m(provider_key, model_key, supports_structured_output)
JOIN public.ai_providers p
  ON p.provider_key = m.provider_key
ON CONFLICT (provider_id, model_key) DO UPDATE
SET supports_structured_output = EXCLUDED.supports_structured_output,
    active = true;

CREATE TABLE IF NOT EXISTS public.ai_roles (
  role_key text PRIMARY KEY,
  stage text NOT NULL,
  input_schema_key text NOT NULL,
  output_schema_key text NOT NULL,
  description text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_ai_roles_stage CHECK (
    stage = ANY (
      ARRAY[
        'normalization'::text,
        'understanding'::text,
        'execution'::text
      ]
    )
  )
);

DROP TRIGGER IF EXISTS trg_ai_roles_updated_at ON public.ai_roles;
CREATE TRIGGER trg_ai_roles_updated_at
BEFORE UPDATE ON public.ai_roles
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

ALTER TABLE public.ai_roles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_roles FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.ai_roles TO service_role;

INSERT INTO public.ai_roles (
  role_key,
  stage,
  input_schema_key,
  output_schema_key,
  description
)
VALUES
  ('intent_classifier', 'understanding', 'normalized_text_input_v1', 'intent_classification_v1', 'Classifies command intent from canonical text input.'),
  ('grocery_parser', 'understanding', 'normalized_text_input_v1', 'grocery_parse_result_v1', 'Parses grocery items from canonical text input.'),
  ('task_parser', 'understanding', 'normalized_text_input_v1', 'task_parse_result_v1', 'Parses task creation fields from canonical text input.')
ON CONFLICT (role_key) DO UPDATE
SET stage = EXCLUDED.stage,
    input_schema_key = EXCLUDED.input_schema_key,
    output_schema_key = EXCLUDED.output_schema_key,
    description = EXCLUDED.description;

CREATE TABLE IF NOT EXISTS public.ai_feature_steps (
  feature_key text NOT NULL,
  step_key text NOT NULL,
  step_order integer NOT NULL,
  role_key text NOT NULL REFERENCES public.ai_roles(role_key),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feature_key, step_key),
  CONSTRAINT uq_ai_feature_steps_order UNIQUE (feature_key, step_order)
);

DROP TRIGGER IF EXISTS trg_ai_feature_steps_updated_at ON public.ai_feature_steps;
CREATE TRIGGER trg_ai_feature_steps_updated_at
BEFORE UPDATE ON public.ai_feature_steps
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

ALTER TABLE public.ai_feature_steps ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_feature_steps FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.ai_feature_steps TO service_role;

INSERT INTO public.ai_feature_steps (feature_key, step_key, step_order, role_key, active)
VALUES
  ('command', 'intent_classifier', 1, 'intent_classifier', true),
  ('command', 'grocery_parser', 2, 'grocery_parser', true),
  ('command', 'task_parser', 3, 'task_parser', true)
ON CONFLICT (feature_key, step_key) DO UPDATE
SET step_order = EXCLUDED.step_order,
    role_key = EXCLUDED.role_key,
    active = EXCLUDED.active;

CREATE TABLE IF NOT EXISTS public.ai_role_routes (
  role_key text PRIMARY KEY REFERENCES public.ai_roles(role_key),
  model_id uuid NOT NULL REFERENCES public.ai_models(model_id),
  prompt_version text NOT NULL,
  execution_mode text NOT NULL DEFAULT 'sync',
  deterministic_fallback_allowed boolean NOT NULL DEFAULT false,
  max_retries integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_ai_role_routes_execution_mode CHECK (
    execution_mode IN ('sync', 'async')
  ),
  CONSTRAINT ck_ai_role_routes_max_retries CHECK (max_retries >= 0)
);

DROP TRIGGER IF EXISTS trg_ai_role_routes_updated_at ON public.ai_role_routes;
CREATE TRIGGER trg_ai_role_routes_updated_at
BEFORE UPDATE ON public.ai_role_routes
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

ALTER TABLE public.ai_role_routes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_role_routes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.ai_role_routes TO service_role;

INSERT INTO public.ai_role_routes (
  role_key,
  model_id,
  prompt_version,
  execution_mode,
  deterministic_fallback_allowed,
  max_retries,
  active
)
SELECT
  seeds.role_key,
  m.model_id,
  seeds.prompt_version,
  seeds.execution_mode,
  seeds.deterministic_fallback_allowed,
  seeds.max_retries,
  true
FROM (
  VALUES
    ('intent_classifier', 'openai', 'gpt-5-nano', 'v1', 'sync', false, 0),
    ('grocery_parser', 'stub', 'stub-command', 'v1', 'sync', true, 0),
    ('task_parser', 'stub', 'stub-command', 'v1', 'sync', true, 0)
) AS seeds(role_key, provider_key, model_key, prompt_version, execution_mode, deterministic_fallback_allowed, max_retries)
JOIN public.ai_providers p
  ON p.provider_key = seeds.provider_key
JOIN public.ai_models m
  ON m.provider_id = p.provider_id
 AND m.model_key = seeds.model_key
ON CONFLICT (role_key) DO UPDATE
SET model_id = EXCLUDED.model_id,
    prompt_version = EXCLUDED.prompt_version,
    execution_mode = EXCLUDED.execution_mode,
    deterministic_fallback_allowed = EXCLUDED.deterministic_fallback_allowed,
    max_retries = EXCLUDED.max_retries,
    active = true;

CREATE TABLE IF NOT EXISTS public.ai_step_logs (
  step_log_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL,
  user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  home_id uuid REFERENCES public.homes(id) ON DELETE CASCADE,
  feature_key text NOT NULL,
  stage text NOT NULL,
  role_key text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  prompt_version text NOT NULL,
  status text NOT NULL,
  latency_ms integer,
  error_code text,
  provider_request_id text,
  input_tokens integer,
  output_tokens integer,
  total_tokens integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_ai_step_logs_stage CHECK (
    stage IN ('normalization', 'understanding', 'execution')
  ),
  CONSTRAINT ck_ai_step_logs_status CHECK (
    status IN ('started', 'completed', 'failed', 'timeout')
  ),
  CONSTRAINT ck_ai_step_logs_latency CHECK (
    latency_ms IS NULL OR latency_ms >= 0
  ),
  CONSTRAINT ck_ai_step_logs_input_tokens CHECK (
    input_tokens IS NULL OR input_tokens >= 0
  ),
  CONSTRAINT ck_ai_step_logs_output_tokens CHECK (
    output_tokens IS NULL OR output_tokens >= 0
  ),
  CONSTRAINT ck_ai_step_logs_total_tokens CHECK (
    total_tokens IS NULL OR total_tokens >= 0
  )
);

ALTER TABLE public.ai_step_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_step_logs FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.ai_step_logs TO service_role;

CREATE INDEX IF NOT EXISTS ix_ai_step_logs_request
  ON public.ai_step_logs(request_id, created_at DESC);

CREATE INDEX IF NOT EXISTS ix_ai_step_logs_feature_role
  ON public.ai_step_logs(feature_key, role_key, created_at DESC);

CREATE OR REPLACE FUNCTION public.ai_feature_steps_get(p_feature_key text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'feature_key', s.feature_key,
        'step_key', s.step_key,
        'step_order', s.step_order,
        'role_key', s.role_key,
        'stage', r.stage
      )
      ORDER BY s.step_order ASC
    ),
    '[]'::jsonb
  )
  FROM public.ai_feature_steps s
  JOIN public.ai_roles r
    ON r.role_key = s.role_key
  WHERE s.feature_key = p_feature_key
    AND s.active = true;
$$;

REVOKE ALL ON FUNCTION public.ai_feature_steps_get(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ai_feature_steps_get(text) TO service_role;

CREATE OR REPLACE FUNCTION public.ai_role_route_get(p_role_key text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'role_key', r.role_key,
    'stage', ar.stage,
    'provider', p.provider_key,
    'adapter_kind', p.adapter_kind,
    'base_url', p.base_url,
    'secret_name', p.secret_name,
    'model', m.model_key,
    'prompt_version', r.prompt_version,
    'execution_mode', r.execution_mode,
    'deterministic_fallback_allowed', r.deterministic_fallback_allowed,
    'max_retries', r.max_retries
  )
  FROM public.ai_role_routes r
  JOIN public.ai_models m
    ON m.model_id = r.model_id
  JOIN public.ai_providers p
    ON p.provider_id = m.provider_id
  JOIN public.ai_roles ar
    ON ar.role_key = r.role_key
  WHERE r.role_key = p_role_key
    AND r.active = true
    AND m.active = true
    AND p.active = true;
$$;

REVOKE ALL ON FUNCTION public.ai_role_route_get(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ai_role_route_get(text) TO service_role;

CREATE OR REPLACE FUNCTION public._ai_log_step(
  p_request_id uuid,
  p_home_id uuid,
  p_feature_key text,
  p_stage text,
  p_role_key text,
  p_provider text,
  p_model text,
  p_prompt_version text,
  p_status text,
  p_user_id uuid DEFAULT NULL,
  p_latency_ms integer DEFAULT NULL,
  p_error_code text DEFAULT NULL,
  p_provider_request_id text DEFAULT NULL,
  p_input_tokens integer DEFAULT NULL,
  p_output_tokens integer DEFAULT NULL,
  p_total_tokens integer DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_user_id, auth.uid());
  v_log_id uuid;
BEGIN
  INSERT INTO public.ai_step_logs (
    request_id,
    user_id,
    home_id,
    feature_key,
    stage,
    role_key,
    provider,
    model,
    prompt_version,
    status,
    latency_ms,
    error_code,
    provider_request_id,
    input_tokens,
    output_tokens,
    total_tokens
  )
  VALUES (
    p_request_id,
    v_user_id,
    p_home_id,
    p_feature_key,
    p_stage,
    p_role_key,
    p_provider,
    p_model,
    p_prompt_version,
    p_status,
    p_latency_ms,
    p_error_code,
    p_provider_request_id,
    p_input_tokens,
    p_output_tokens,
    p_total_tokens
  )
  RETURNING step_log_id INTO v_log_id;

  RETURN v_log_id;
END;
$$;

REVOKE ALL ON FUNCTION public._ai_log_step(uuid, uuid, text, text, text, text, text, text, text, uuid, integer, text, text, integer, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._ai_log_step(uuid, uuid, text, text, text, text, text, text, text, uuid, integer, text, text, integer, integer, integer)
  TO service_role;
-- Command runtime helpers and public RPCs intentionally begin in
-- 20260415103000_command_v1_runtime_handoffs.sql so the pre-release command
-- stack has a single authoritative migration family.

-- Retire the old command-specific routing/config surfaces.
DROP FUNCTION IF EXISTS public.command_ai_feature_route(text);
DROP FUNCTION IF EXISTS public._command_ai_log_provider_call(uuid, uuid, text, text, text, text, text, text, integer, text, text);
DROP FUNCTION IF EXISTS public._command_ai_sync_call(uuid, uuid, text, jsonb, jsonb);

DROP TABLE IF EXISTS public.command_ai_provider_calls;
DROP TABLE IF EXISTS public.command_ai_feature_routes;
DROP TABLE IF EXISTS public.command_ai_providers;

DELETE FROM public.ai_role_routes
WHERE model_id IN (
  SELECT m.model_id
  FROM public.ai_models m
  JOIN public.ai_providers p
    ON p.provider_id = m.provider_id
  WHERE p.provider_key = 'qwen'
);

DELETE FROM public.ai_models
USING public.ai_providers p
WHERE ai_models.provider_id = p.provider_id
  AND p.provider_key = 'qwen';

DELETE FROM public.ai_providers
WHERE provider_key = 'qwen';
