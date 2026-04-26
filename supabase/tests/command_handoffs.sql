SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(22);

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000008999', 'avatars/default.png', 'animal', 'Command Handoff Avatar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000008801', '00000000-0000-0000-0000-000000000000', 'command-handoff@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.homes (id, owner_user_id)
VALUES
  ('00000000-0000-4000-8000-000000008901', '00000000-0000-4000-8000-000000008801')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.memberships (user_id, home_id, role, valid_from)
VALUES
  ('00000000-0000-4000-8000-000000008801', '00000000-0000-4000-8000-000000008901', 'owner', now())
ON CONFLICT DO NOTHING;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000008801', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

INSERT INTO public.command_handoffs (
  handoff_id,
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
  '00000000-0000-4000-8000-000000008911',
  '00000000-0000-4000-8000-000000008912',
  '00000000-0000-4000-8000-000000008801',
  '00000000-0000-4000-8000-000000008901',
  'create_task',
  'task',
  'inline',
  'pending',
  'wash clothes',
  0.75,
  jsonb_build_object(
    'result', jsonb_build_object(
      'kind', 'inline',
      'intent', 'create_task',
      'module', 'task',
      'confidence', 0.75,
      'message', jsonb_build_object(
        'title_key', 'command.task.need_assignee.title',
        'body_key', 'command.task.need_assignee.body',
        'params', jsonb_build_object('task_title', 'Wash clothes')
      ),
      'fields', jsonb_build_object('task_title', 'Wash clothes', 'assigned_to', NULL, 'due_at', NULL),
      'missing_fields', jsonb_build_array('assigned_to'),
      'ui', jsonb_build_object(
        'component', 'member_picker',
        'target', NULL,
        'options', jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-8000-000000008801', 'label', 'Command Handoff User')),
        'prefill', jsonb_build_object('task_title', 'Wash clothes')
      ),
      'draft', NULL,
      'execution', NULL,
      'meta', jsonb_build_object(
        'requires_confirmation', false,
        'is_multi_intent_detected', false,
        'raw_input_retained', true
      )
    )
  ),
  'resume-inline-1',
  now() + interval '1 day'
);

SELECT is(
  public.command_resume_v1('00000000-0000-4000-8000-000000008901')->'result'->>'kind',
  'inline',
  'resume returns pending inline handoff'
);

SELECT is(
  public.command_resume_v1('00000000-0000-4000-8000-000000008901')->'result'->'draft'->>'handoff_id',
  '00000000-0000-4000-8000-000000008911',
  'resume returns draft handoff identifier'
);

SELECT is(
  public.command_cancel_v1('00000000-0000-4000-8000-000000008911')->>'status',
  'cancelled',
  'cancel rpc returns cancelled status'
);

SELECT is(
  (
    SELECT status
    FROM public.command_handoffs
    WHERE handoff_id = '00000000-0000-4000-8000-000000008911'
  ),
  'cancelled',
  'cancel rpc persists cancelled status'
);

INSERT INTO public.command_handoffs (
  handoff_id,
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
  '00000000-0000-4000-8000-000000008921',
  '00000000-0000-4000-8000-000000008922',
  '00000000-0000-4000-8000-000000008801',
  '00000000-0000-4000-8000-000000008901',
  'create_task',
  'task',
  'inline',
  'pending',
  'expired request',
  0.75,
  jsonb_build_object(
    'result', jsonb_build_object(
      'kind', 'inline',
      'intent', 'create_task',
      'module', 'task',
      'confidence', 0.75,
      'message', jsonb_build_object(
        'title_key', 'command.task.need_assignee.title',
        'body_key', 'command.task.need_assignee.body',
        'params', jsonb_build_object('task_title', 'Expired request')
      ),
      'fields', jsonb_build_object('task_title', 'Expired request'),
      'missing_fields', jsonb_build_array('assigned_to'),
      'ui', jsonb_build_object('component', 'member_picker', 'target', NULL, 'options', '[]'::jsonb, 'prefill', jsonb_build_object('task_title', 'Expired request')),
      'draft', NULL,
      'execution', NULL,
      'meta', jsonb_build_object(
        'requires_confirmation', false,
        'is_multi_intent_detected', false,
        'raw_input_retained', true
      )
    )
  ),
  'resume-inline-expired',
  now() - interval '1 hour'
);

SELECT ok(
  public.command_resume_v1('00000000-0000-4000-8000-000000008901') IS NULL,
  'resume ignores expired handoffs'
);

SELECT is(
  (
    SELECT status
    FROM public.command_handoffs
    WHERE handoff_id = '00000000-0000-4000-8000-000000008921'
  ),
  'expired',
  'resume marks stale handoffs as expired'
);

INSERT INTO public.command_handoffs (
  handoff_id,
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
  '00000000-0000-4000-8000-000000008931',
  '00000000-0000-4000-8000-000000008932',
  '00000000-0000-4000-8000-000000008801',
  '00000000-0000-4000-8000-000000008901',
  'add_grocery_items',
  'grocery',
  'confirm',
  'pending',
  'add milk and eggs',
  0.75,
  jsonb_build_object(
    'result', jsonb_build_object(
      'kind', 'confirm',
      'intent', 'add_grocery_items',
      'module', 'grocery',
      'confidence', 0.75,
      'message', jsonb_build_object(
        'title_key', 'command.grocery.confirm.title',
        'body_key', 'command.grocery.confirm.body',
        'params', jsonb_build_object('count', 2)
      ),
      'fields', jsonb_build_object(
        'items', jsonb_build_array('milk', 'eggs'),
        'scope_type', 'house',
        'unit_id', NULL
      ),
      'missing_fields', '[]'::jsonb,
      'ui', jsonb_build_object(
        'component', 'confirmation_card',
        'target', NULL,
        'options', jsonb_build_array(
          jsonb_build_object('id', 'confirm', 'label', 'Confirm'),
          jsonb_build_object('id', 'cancel', 'label', 'Cancel')
        ),
        'prefill', jsonb_build_object('items', jsonb_build_array('milk', 'eggs'))
      ),
      'draft', NULL,
      'execution', NULL,
      'meta', jsonb_build_object(
        'requires_confirmation', true,
        'is_multi_intent_detected', false,
        'raw_input_retained', true
      )
    )
  ),
  'resume-confirm-grocery',
  now() + interval '1 day'
);

SELECT is(
  public.command_continue_v1(
    '00000000-0000-4000-8000-000000008931',
    '00000000-0000-4000-8000-000000008933',
    jsonb_build_object('action', 'confirm', 'confirm', true)
  )->'result'->>'kind',
  'execute',
  'continue executes grocery confirm handoff'
);

SELECT is(
  (
    SELECT status
    FROM public.command_handoffs
    WHERE handoff_id = '00000000-0000-4000-8000-000000008931'
  ),
  'completed',
  'continue marks grocery handoff completed'
);

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
BEGIN
  IF p_request_id = '00000000-0000-4000-8000-000000008941'::uuid THEN
    RETURN jsonb_build_object(
      'ok', true,
      'result', jsonb_build_object(
        'classification', jsonb_build_object(
          'primary_intent', 'add_grocery_items',
          'confidence', 'medium',
          'provider', 'openai',
          'model', 'gpt-5-nano',
          'intents_detected', jsonb_build_array('add_grocery_items', 'create_reminder')
        ),
        'intent_work_items', jsonb_build_array(
          jsonb_build_object(
            'intent', 'add_grocery_items',
            'parsed', jsonb_build_object(
              'items', jsonb_build_array(
                jsonb_build_object(
                  'raw_text', 'milk',
                  'canonical_name', 'milk',
                  'quantity_text', NULL,
                  'notes', NULL
                ),
                jsonb_build_object(
                  'raw_text', 'eggs',
                  'canonical_name', 'eggs',
                  'quantity_text', NULL,
                  'notes', NULL
                )
              )
            )
          )
        )
      )
    );
  ELSIF p_request_id = '00000000-0000-4000-8000-000000008951'::uuid THEN
    RETURN jsonb_build_object(
      'ok', true,
      'result', jsonb_build_object(
        'classification', jsonb_build_object(
          'primary_intent', 'create_task',
          'confidence', 'high',
          'provider', 'openai',
          'model', 'gpt-5-nano',
          'intents_detected', jsonb_build_array('create_task')
        ),
        'intent_work_items', jsonb_build_array(
          jsonb_build_object(
            'intent', 'create_task',
            'parsed', jsonb_build_object(
              'task_title', 'Parser owned title',
              'notes', 'Parser owned notes',
              'recurrence_every', NULL,
              'recurrence_unit', NULL,
              'assignee_hint', 'me',
              'start_date', NULL,
              'confidence', 'high'
            )
          )
        )
      )
    );
  ELSIF p_request_id = '00000000-0000-4000-8000-000000008961'::uuid THEN
    RETURN jsonb_build_object(
      'ok', true,
      'result', jsonb_build_object(
        'classification', jsonb_build_object(
          'primary_intent', 'create_reminder',
          'confidence', 'high',
          'provider', 'openai',
          'model', 'gpt-5-nano',
          'intents_detected', jsonb_build_array('create_reminder')
        ),
        'intent_work_items', jsonb_build_array(
          jsonb_build_object(
            'intent', 'create_reminder',
            'parsed', jsonb_build_object(
              'task_title', 'Take bins out',
              'notes', 'Street pickup reminder',
              'recurrence_every', 1,
              'recurrence_unit', 'week',
              'assignee_hint', 'me',
              'start_date', '2026-04-17',
              'confidence', 'high'
            )
          )
        )
      )
    );
  END IF;

  RAISE EXCEPTION 'unexpected pipeline request %', p_request_id
    USING ERRCODE = 'P0001';
END;
$$;

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000008901',
    'text',
    'add milk and remind me to wash clothes',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    '00000000-0000-4000-8000-000000008941'
  )->'result'->>'kind',
  'confirm',
  'multi-intent submit downgrades to confirm without immediate execution'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.shopping_list_items
    WHERE home_id = '00000000-0000-4000-8000-000000008901'
      AND lower(name) IN ('milk', 'eggs')
  ),
  2,
  'only confirmed grocery handoff created shopping list items'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.command_handoffs
    WHERE request_id = '00000000-0000-4000-8000-000000008941'
      AND kind = 'confirm'
      AND status = 'pending'
  ),
  1,
  'multi-intent submit persists pending confirm handoff'
);

SELECT is(
  (
    SELECT context->'result'->>'kind'
    FROM public.command_handoffs
    WHERE request_id = '00000000-0000-4000-8000-000000008941'
      AND kind = 'confirm'
      AND status = 'pending'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'confirm',
  'auto-created handoff stores authoritative result payload in context'
);

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000008901',
    'text',
    'wash clothes soon',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    '00000000-0000-4000-8000-000000008951'
  )->'result'->>'kind',
  'execute',
  'single parsed task submit executes immediately'
);

SELECT is(
  (
    SELECT name
    FROM public.chores
    WHERE home_id = '00000000-0000-4000-8000-000000008901'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'Parser owned title',
  'task creation uses parser supplied title as authoritative boundary'
);

SELECT is(
  (
    SELECT notes
    FROM public.chores
    WHERE home_id = '00000000-0000-4000-8000-000000008901'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'Parser owned notes',
  'task creation uses parser supplied notes'
);

INSERT INTO public.command_handoffs (
  handoff_id,
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
  '00000000-0000-4000-8000-000000008971',
  '00000000-0000-4000-8000-000000008972',
  '00000000-0000-4000-8000-000000008801',
  '00000000-0000-4000-8000-000000008901',
  'create_task',
  'task',
  'inline',
  'pending',
  'take bins out',
  0.75,
  jsonb_build_object(
    'result', jsonb_build_object(
      'kind', 'inline',
      'intent', 'create_task',
      'module', 'task',
      'confidence', 0.75,
      'message', jsonb_build_object(
        'title_key', 'command.task.need_assignee.title',
        'body_key', 'command.task.need_assignee.body',
        'params', jsonb_build_object('task_title', 'Take bins out')
      ),
      'fields', jsonb_build_object(
        'task_title', 'Take bins out',
        'assigned_to', NULL,
        'due_at', NULL,
        'notes', 'Street pickup reminder',
        'recurrence_interval', 'weekly'
      ),
      'missing_fields', jsonb_build_array('assigned_to'),
      'ui', jsonb_build_object(
        'component', 'member_picker',
        'target', NULL,
        'options', jsonb_build_array(jsonb_build_object('id', '00000000-0000-4000-8000-000000008801', 'label', 'Command Handoff User')),
        'prefill', jsonb_build_object('task_title', 'Take bins out')
      ),
      'draft', NULL,
      'execution', NULL,
      'meta', jsonb_build_object(
        'requires_confirmation', false,
        'is_multi_intent_detected', false,
        'raw_input_retained', true
      )
    )
  ),
  'resume-inline-task-notes',
  now() + interval '1 day'
);

SELECT is(
  public.command_continue_v1(
    '00000000-0000-4000-8000-000000008971',
    '00000000-0000-4000-8000-000000008973',
    jsonb_build_object('assigned_to', '00000000-0000-4000-8000-000000008801')
  )->'result'->>'kind',
  'execute',
  'continue executes task handoff using authoritative context payload'
);

SELECT is(
  (
    SELECT notes
    FROM public.chores
    WHERE home_id = '00000000-0000-4000-8000-000000008901'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'Street pickup reminder',
  'continue preserves task notes from handoff context'
);

SELECT is(
  (
    SELECT recurrence::text
    FROM public.chores
    WHERE home_id = '00000000-0000-4000-8000-000000008901'
    ORDER BY created_at DESC
    LIMIT 1
  ),
  'weekly',
  'continue preserves task recurrence from handoff context'
);

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000008901',
    'text',
    'remind me every week starting Friday to take bins out',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    '00000000-0000-4000-8000-000000008961'
  )->'result'->>'kind',
  'route',
  'date-aware recurring reminder routes into task flow instead of auto-executing'
);

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000008901',
    'text',
    'remind me every week starting Friday to take bins out',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    '00000000-0000-4000-8000-000000008961'
  )->'result'->'fields'->>'due_at',
  '2026-04-17',
  'route payload preserves parsed reminder date'
);

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000008901',
    'text',
    'remind me every week starting Friday to take bins out',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    '00000000-0000-4000-8000-000000008961'
  )->'result'->'fields'->>'recurrence_every',
  '1',
  'route payload preserves parsed recurrence_every'
);

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000008901',
    'text',
    'remind me every week starting Friday to take bins out',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    '00000000-0000-4000-8000-000000008961'
  )->'result'->'fields'->>'recurrence_unit',
  'week',
  'route payload preserves parsed recurrence_unit'
);

SELECT * FROM finish();
ROLLBACK;
