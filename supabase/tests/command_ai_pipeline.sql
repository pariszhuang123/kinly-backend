SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(12);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.ai_providers
    WHERE provider_key = 'openai'
      AND adapter_kind = 'openai_responses'
  ),
  'ai providers seeded with openai responses provider'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.ai_providers
    WHERE provider_key = 'qwen'
  ),
  'unimplemented qwen provider is not seeded into command ai config'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.ai_roles
    WHERE role_key = 'intent_classifier'
      AND stage = 'understanding'
  ),
  'intent classifier role seeded'
);

SELECT is(
  (
    public.ai_feature_steps_get('command')->0->>'role_key'
  ),
  'intent_classifier',
  'command feature step starts with intent classifier'
);

SELECT is(
  (
    public.ai_feature_steps_get('command')->1->>'role_key'
  ),
  'grocery_parser',
  'command feature steps expose grocery parser route'
);

SELECT is(
  public.ai_role_route_get('intent_classifier')->>'provider',
  'openai',
  'intent classifier route resolves provider'
);

SELECT is(
  public.ai_role_route_get('grocery_parser')->>'provider',
  'stub',
  'grocery parser route resolves stub provider'
);

SELECT lives_ok(
  $$ SELECT public._ai_log_step(
       '00000000-0000-4000-8000-000000000011',
       NULL,
       'command',
       'understanding',
       'intent_classifier',
       'openai',
       'gpt-5-nano',
       'v1',
       'completed',
       NULL,
       12,
       NULL,
       'resp_123'
     ); $$,
  'ai step log helper accepts per-step log writes'
);

SELECT is(
  (
    SELECT role_key
    FROM public.ai_step_logs
    WHERE request_id = '00000000-0000-4000-8000-000000000011'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'intent_classifier',
  'ai step log row stores role key'
);

SELECT lives_ok(
  $$ SELECT public._ai_log_step(
       '00000000-0000-4000-8000-000000000012',
       NULL,
       'command',
       'understanding',
       'intent_classifier',
       'openai',
       'gpt-5-nano',
       'v1',
       'completed',
       '00000000-0000-4000-8000-000000000013',
       15,
       NULL,
       'resp_456',
       21,
       9,
       30
     ); $$,
  'ai step log helper accepts explicit actor id and usage metadata'
);

SELECT is(
  (
    SELECT user_id::text
    FROM public.ai_step_logs
    WHERE request_id = '00000000-0000-4000-8000-000000000012'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  '00000000-0000-4000-8000-000000000013',
  'ai step log stores explicit actor user id'
);

SELECT is(
  (
    SELECT concat_ws(':', input_tokens::text, output_tokens::text, total_tokens::text)
    FROM public.ai_step_logs
    WHERE request_id = '00000000-0000-4000-8000-000000000012'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  '21:9:30',
  'ai step log stores per-flow token attribution fields'
);

SELECT * FROM finish();
ROLLBACK;
