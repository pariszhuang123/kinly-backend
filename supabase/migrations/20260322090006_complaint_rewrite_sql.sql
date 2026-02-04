-- ============================================================
-- COMPLAINT REWRITE: FULL ADJUSTED SQL (end-to-end) — BATCH ONLY
-- Final aligned version (matches your submitter expectations + schema):
--
-- ✅ Batch-only pipeline (no realtime worker claim RPC)
-- ✅ Submitter RPCs:
--    - claim_rewrite_jobs_for_batch_submit_v1
--    - mark_rewrite_jobs_batch_submitted_v1
-- ✅ Collector claim RPCs:
--    - claim_rewrite_jobs_for_batch_collect_v1 (fallback)
--    - claim_rewrite_jobs_by_ids_for_collect_v1 (recommended)
-- ✅ Batch registry RPCs:
--    - rewrite_batch_register_v1
--    - rewrite_batch_update_v1
--    - rewrite_batch_list_pending_v1
-- ✅ Output completion RPC:
--    - complete_complaint_rewrite_job
-- ✅ Requeue helpers:
--    - complaint_rewrite_job_fail_or_requeue
--    - fail_complaint_rewrite_job
-- ✅ Fixes:
--    - Requeue-by-provider-batch uses public.rewrite_jobs + not_before_at
--    - No provider_job_custom_id references
--    - Request completes ONLY when ALL jobs terminal
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 0) updated_at helper (trigger)
-- ============================================================

create or replace function public._touch_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end $$;

revoke all on function public._touch_updated_at() from public;
grant execute on function public._touch_updated_at() to service_role;

-- ============================================================
-- A) Locale helper
-- ============================================================

create or replace function public._locale_primary(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(lower(split_part(coalesce(p,''), '-', 1)), '');
$$;

-- ============================================================
-- B) DELETE realtime worker claim RPC (NOT used in batch-only)
-- ============================================================

drop function if exists public.claim_complaint_rewrite_jobs(int);

-- ============================================================
-- C) Fail / requeue helpers (service_role only)
-- ============================================================

create or replace function public.fail_complaint_rewrite_job(
  p_job_id uuid,
  p_error text
) returns void
language sql
security definer
set search_path = ''
as $$
  update public.rewrite_jobs
     set status = 'failed',
         last_error = left(coalesce(p_error,'unknown'), 512),
         last_error_at = now(),
         updated_at = now()
   where job_id = p_job_id;
$$;

revoke all on function public.fail_complaint_rewrite_job(uuid, text) from public;
grant execute on function public.fail_complaint_rewrite_job(uuid, text) to service_role;

create or replace function public.complaint_rewrite_job_fail_or_requeue(
  p_job_id uuid,
  p_error text,
  p_backoff_seconds int default 600
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt int;
  v_max int;
  v_backoff int := greatest(30, least(coalesce(p_backoff_seconds, 600), 6*3600)); -- 30s..6h
begin
  select attempt_count, max_attempts
    into v_attempt, v_max
  from public.rewrite_jobs
  where job_id = p_job_id;

  if v_attempt is null then
    return;
  end if;

  if v_attempt >= v_max then
    update public.rewrite_jobs
      set status='failed',
          last_error=left(coalesce(p_error,'unknown'),512),
          last_error_at=now(),
          updated_at=now()
    where job_id=p_job_id;
  else
    update public.rewrite_jobs
      set status='queued',
          not_before_at=now() + make_interval(secs => v_backoff),
          last_error=left(coalesce(p_error,'unknown'),512),
          last_error_at=now(),
          updated_at=now()
    where job_id=p_job_id;
  end if;
end;
$$;

revoke all on function public.complaint_rewrite_job_fail_or_requeue(uuid, text, int) from public;
grant execute on function public.complaint_rewrite_job_fail_or_requeue(uuid, text, int) to service_role;

-- ============================================================
-- D) Completion (service_role only)
-- - strict job match (job must be processing)
-- - locale primary match
-- - upsert output row
-- - job -> completed
-- - request completes only when ALL jobs terminal
-- ============================================================

-- NOTE: expects public.api_assert(...) to exist in your DB.
-- If you don't have it, replace those performs with explicit IF/RAISE.

create or replace function public.complete_complaint_rewrite_job(
  p_job_id uuid,
  p_rewrite_request_id uuid,
  p_recipient_user_id uuid,
  p_rewritten_text text,
  p_output_language text,
  p_target_locale text,
  p_model text,
  p_provider text,
  p_prompt_version text,
  p_policy_version text,
  p_lexicon_version text,
  p_eval_result jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_non_terminal_count int;
  v_any_failed boolean;
begin
  perform public.api_assert(
    exists (
      select 1
      from public.rewrite_jobs j
      where j.job_id = p_job_id
        and j.rewrite_request_id = p_rewrite_request_id
        and j.recipient_user_id = p_recipient_user_id
        and j.status = 'processing'
      limit 1
    ),
    'JOB_MISMATCH',
    'Job does not match request/recipient or is not processing.',
    '22023'
  );

  perform public.api_assert(
    public._locale_primary(p_output_language) is not null
    and public._locale_primary(p_output_language) = public._locale_primary(p_target_locale),
    'LANG_MISMATCH',
    'output_language does not match target locale language.',
    '22023'
  );

  insert into public.rewrite_outputs(
    rewrite_request_id, recipient_user_id, rewritten_text, output_language, target_locale,
    model, provider, prompt_version, policy_version, lexicon_version, eval_result
  ) values (
    p_rewrite_request_id, p_recipient_user_id, p_rewritten_text, p_output_language, p_target_locale,
    p_model, p_provider, p_prompt_version, p_policy_version, p_lexicon_version, p_eval_result
  )
  on conflict (rewrite_request_id, recipient_user_id)
  do update set
    rewritten_text = excluded.rewritten_text,
    output_language = excluded.output_language,
    target_locale = excluded.target_locale,
    model = excluded.model,
    provider = excluded.provider,
    prompt_version = excluded.prompt_version,
    policy_version = excluded.policy_version,
    lexicon_version = excluded.lexicon_version,
    eval_result = excluded.eval_result,
    created_at = now();

  update public.rewrite_jobs
     set status = 'completed',
         updated_at = now(),
         last_error = null,
         last_error_at = null
   where job_id = p_job_id;

  -- Only complete request if ALL jobs are terminal.
  select count(*) into v_non_terminal_count
  from public.rewrite_jobs j
  where j.rewrite_request_id = p_rewrite_request_id
    and j.status in ('queued','processing','batch_submitted');

  if v_non_terminal_count = 0 then
    select exists(
      select 1
      from public.rewrite_jobs j
      where j.rewrite_request_id = p_rewrite_request_id
        and j.status in ('failed','canceled')
      limit 1
    ) into v_any_failed;

    update public.rewrite_requests
       set status = case when v_any_failed then 'failed' else 'completed' end,
           rewrite_completed_at = coalesce(rewrite_completed_at, now()),
           updated_at = now()
     where rewrite_request_id = p_rewrite_request_id;
  end if;
end;
$$;

revoke all on function public.complete_complaint_rewrite_job(
  uuid, uuid, uuid, text, text, text, text, text, text, text, text, jsonb
) from public;

grant execute on function public.complete_complaint_rewrite_job(
  uuid, uuid, uuid, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- ============================================================
-- E) Fetch request for provider (service_role only)
-- ============================================================

create or replace function public.complaint_rewrite_request_fetch_v1(
  p_rewrite_request_id uuid
) returns table (
  rewrite_request jsonb,
  target_locale text,
  policy_version text
)
language sql
security definer
set search_path = ''
as $$
  select
    r.rewrite_request,
    r.target_locale,
    r.policy_version
  from public.rewrite_requests r
  where r.rewrite_request_id = p_rewrite_request_id
  limit 1;
$$;

revoke all on function public.complaint_rewrite_request_fetch_v1(uuid) from public;
grant execute on function public.complaint_rewrite_request_fetch_v1(uuid) to service_role;

-- ============================================================
-- F) Routing RPC (service_role only)
-- ============================================================

create or replace function public.complaint_rewrite_route(
  p_surface text,
  p_lane text,
  p_rewrite_strength text
) returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'route_id', r.route_id,
    'provider', r.provider,
    'adapter_kind', p.adapter_kind,
    'base_url', p.base_url,
    'model', r.model,
    'prompt_version', r.prompt_version,
    'policy_version', r.policy_version,
    'execution_mode', r.execution_mode,
    'supports_translation', true,
    'cache_eligible', r.cache_eligible,
    'max_retries', r.max_retries
  )
  from public.complaint_rewrite_routes r
  join public.complaint_ai_providers p
    on p.provider = r.provider
  where r.surface = p_surface
    and r.lane = p_lane
    and r.rewrite_strength = p_rewrite_strength
    and r.active = true
    and p.active = true
  order by r.priority asc, r.created_at asc
  limit 1;
$$;

revoke all on function public.complaint_rewrite_route(text, text, text) from public;
grant execute on function public.complaint_rewrite_route(text, text, text) to service_role;

-- ============================================================
-- G) Preference payload functions (LOCK DOWN: service_role only)
-- ============================================================

create or replace function public.complaint_preference_payload_from_responses(
  p_recipient_user_id uuid
) returns jsonb
language sql
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_object_agg(pr.preference_id, defs.value_keys[pr.option_index + 1]),
    '{}'::jsonb
  )
  from public.preference_responses pr
  join public.preference_taxonomy_defs defs
    on defs.preference_id = pr.preference_id
  where pr.user_id = p_recipient_user_id;
$$;

revoke all on function public.complaint_preference_payload_from_responses(uuid) from public;
revoke all on function public.complaint_preference_payload_from_responses(uuid) from anon, authenticated;
grant execute on function public.complaint_preference_payload_from_responses(uuid) to service_role;

create or replace function public._preference_report_to_value_map(p_report jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((
    select jsonb_object_agg(k, (v->>'value_key'))
    from jsonb_each(coalesce(p_report->'resolved', '{}'::jsonb)) as e(k, v)
    where (v ? 'value_key')
      and (v->>'value_key') is not null
      and (v->>'value_key') <> ''
  ), '{}'::jsonb);
$$;

create or replace function public.complaint_preference_payload(
  p_recipient_user_id uuid,
  p_recipient_preference_snapshot_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := null;
  v_value_map jsonb := '{}'::jsonb;
begin
  if p_recipient_preference_snapshot_id is not null then
    select rps.preference_payload
      into v_payload
    from public.recipient_preference_snapshots rps
    where rps.recipient_preference_snapshot_id = p_recipient_preference_snapshot_id
    limit 1;
  end if;

  if v_payload is null then
    select r.published_content
      into v_payload
    from public.preference_reports r
    where r.subject_user_id = p_recipient_user_id
      and r.template_key = 'personal_preferences_v1'
      and r.status = 'published'
    order by r.published_at desc nulls last
    limit 1;
  end if;

  if v_payload is not null and (v_payload ? 'resolved') then
    v_value_map := public._preference_report_to_value_map(v_payload);
  else
    v_value_map := coalesce(v_payload, '{}'::jsonb);
  end if;

  if v_value_map is null or v_value_map = '{}'::jsonb then
    v_value_map := public.complaint_preference_payload_from_responses(p_recipient_user_id);
  end if;

  return coalesce(v_value_map, '{}'::jsonb);
end;
$$;

revoke all on function public.complaint_preference_payload(uuid, uuid) from public;
revoke all on function public.complaint_preference_payload(uuid, uuid) from anon, authenticated;
grant execute on function public.complaint_preference_payload(uuid, uuid) to service_role;

-- ============================================================
-- H) Instruction mapper
-- ============================================================

create or replace function public.map_instruction(p_id text, p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_id
    when 'communication_directness' then case p_value
      when 'gentle' then 'Prefer softer phrasing and good timing; avoid blunt wording.'
      when 'balanced' then 'Be clear but not harsh; avoid sharp tone.'
      when 'direct' then 'Be straightforward without commands; keep concise.'
      else 'Keep clear and respectful tone.'
    end
    when 'conflict_resolution_style' then case p_value
      when 'cool_off' then 'Offer space first; avoid demanding immediate response.'
      when 'talk_soon' then 'Invite a short chat when convenient; avoid urgency.'
      when 'mediate' then 'Suggest a gentle check-in later; no third-party mediation implied.'
      when 'check_in' then 'Suggest a gentle check-in later; no third-party mediation implied.'
      else 'Suggest a calm follow-up.'
    end
    when 'environment_noise_tolerance' then case p_value
      when 'low' then 'Frame as a quiet-time request using impact language; avoid blame.'
      when 'medium' then 'Ask for mindful hours; keep tone neutral.'
      when 'high' then 'Keep request minimal; avoid overstating impact.'
      else 'Ask for considerate noise levels.'
    end
    when 'schedule_quiet_hours_preference' then case p_value
      when 'early_evening' then 'Avoid late-night asks; suggest daytime without exact times.'
      when 'late_evening_or_night' then 'Allow later timing; avoid exact times unless provided.'
      when 'none' then 'No added timing constraints.'
      else 'Keep timing reasonable.'
    end
    when 'privacy_room_entry' then case p_value
      when 'always_ask' then 'Ask permission before entering; phrase as a request, not a rule.'
      else 'Ask before entering shared/private spaces.'
    end
    when 'privacy_notifications' then case p_value
      when 'none' then 'Avoid after-hours notifications; suggest tomorrow without inventing times.'
      else 'Be mindful of notification timing.'
    end
    when 'communication_channel' then case p_value
      when 'text' then 'Written request is fine; keep concise and calm.'
      when 'call' then 'Offer a quick call when convenient; avoid urgency.'
      when 'in_person' then 'Offer a brief in-person check-in; avoid pressure.'
      else 'Use a considerate communication channel.'
    end
    when 'cleanliness_shared_space_tolerance' then case p_value
      when 'low' then 'Use reset/tidy-up framing; avoid "messy" accusations.'
      when 'high' then 'Keep request minimal; avoid policing tone.'
      else 'Ask for shared-space reset.'
    end
    when 'social_togetherness' then case p_value
      when 'mostly_solo' then 'Avoid pushing group talk; keep 1:1 framing.'
      when 'balanced' then 'Neutral social framing.'
      when 'mostly_together' then 'Allow gentle invitation; avoid pressure.'
      else 'Keep social tone balanced.'
    end
    when 'social_hosting_frequency' then case p_value
      when 'rare' then 'Emphasize heads-up and consent for visitors.'
      when 'sometimes' then 'Use gentle heads-up language for visitors.'
      when 'often' then 'Avoid judgment; keep request specific and time-bounded.'
      else 'Ask for visitor heads-up.'
    end
    when 'routine_planning_style' then case p_value
      when 'planner' then 'Provide heads-up and propose planning; avoid last-minute tone.'
      when 'mixed' then 'No change to timing tone.'
      when 'spontaneous' then 'Keep request lightweight; avoid heavy planning language.'
      else 'Keep timing language light.'
    end
    else 'Keep tone warm and clear.'
  end;
$$;

-- ============================================================
-- I) Context builder (service_role only)
-- ============================================================

create or replace function public.complaint_context_build(
  p_recipient_user_id uuid,
  p_recipient_preference_snapshot_id uuid,
  p_topics text[],
  p_target_language text,
  p_power_mode text default 'peer'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := null;
  v_value_map jsonb := '{}'::jsonb;
  v_topics text[] := coalesce(p_topics, array['other']);
  v_pref_ids text[] := '{}';
  v_included text[] := '{}';
  v_signals jsonb := '[]'::jsonb;
begin
  v_value_map := public.complaint_preference_payload(p_recipient_user_id, p_recipient_preference_snapshot_id);

  if p_recipient_preference_snapshot_id is not null then
    select rps.preference_payload
      into v_payload
    from public.recipient_preference_snapshots rps
    where rps.recipient_preference_snapshot_id = p_recipient_preference_snapshot_id
    limit 1;
  end if;

  v_value_map := coalesce(v_value_map, '{}'::jsonb);

  v_pref_ids := array(
    select distinct x
    from unnest(array_cat(
      case when 'noise' = any(v_topics) then array['environment_noise_tolerance','schedule_quiet_hours_preference','conflict_resolution_style','communication_directness'] else '{}'::text[] end,
      case when 'privacy' = any(v_topics) then array['privacy_room_entry','privacy_notifications','communication_channel','conflict_resolution_style'] else '{}'::text[] end
    )) as t(x)
    where x <> ''
  );

  if v_pref_ids is null then v_pref_ids := '{}'; end if;

  v_included := (
    select array_agg(key)
    from jsonb_each_text(v_value_map)
    where key = any(v_pref_ids)
  );

  if v_included is null then v_included := '{}'; end if;

  v_signals := (
    select jsonb_agg(jsonb_build_object(
      'preference_id', key,
      'value_key', value,
      'instruction', public.map_instruction(key, value)
    ))
    from jsonb_each_text(v_value_map)
    where key = any(v_included)
  );

  v_signals := coalesce(v_signals, '[]'::jsonb);

  return jsonb_build_object(
    'context_version', 'v1',
    'recipient_user_id', p_recipient_user_id,
    'target_language', p_target_language,
    'power', jsonb_build_object(
      'sender_role','housemate',
      'recipient_role','housemate',
      'power_mode', p_power_mode
    ),
    'topic_scope', jsonb_build_object(
      'topics', v_topics,
      'included_preference_ids', v_included
    ),
    'instructions', jsonb_build_object(
      'tone','warm_clear',
      'directness','soft',
      'avoid', jsonb_build_array('authority_language','rules_language','enforcement_language','preference_disclosure')
    ),
    'recipient_signals', v_signals,
    'preference_payload', coalesce(v_payload, '{}'::jsonb),
    'preference_value_map', v_value_map
  );
end;
$$;

revoke all on function public.complaint_context_build(uuid, uuid, text[], text, text) from public;
revoke all on function public.complaint_context_build(uuid, uuid, text[], text, text) from anon, authenticated;
grant execute on function public.complaint_context_build(uuid, uuid, text[], text, text) to service_role;

-- ============================================================
-- J) Request exists (service_role only)
-- ============================================================

create or replace function public.complaint_rewrite_request_exists(
  p_rewrite_request_id uuid
) returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists (
    select 1
    from public.rewrite_requests r
    where r.rewrite_request_id = p_rewrite_request_id
  );
$$;

revoke all on function public.complaint_rewrite_request_exists(uuid) from public;
grant execute on function public.complaint_rewrite_request_exists(uuid) to service_role;

-- ============================================================
-- K) Build snapshots (idempotent)
-- ============================================================

create or replace function public.complaint_build_recipient_snapshots(
  p_rewrite_request_id uuid,
  p_home_id uuid,
  p_recipient_user_id uuid,
  p_preference_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recipient_snapshot_id uuid;
  v_pref_snapshot_id uuid;
begin
  perform public.api_assert(p_rewrite_request_id is not null, 'INVALID_REQ', 'rewrite_request_id required', '22023');
  perform public.api_assert(p_home_id is not null, 'INVALID_HOME', 'home_id required', '22023');
  perform public.api_assert(p_recipient_user_id is not null, 'INVALID_RECIP', 'recipient_user_id required', '22023');
  perform public.api_assert(jsonb_typeof(p_preference_payload) = 'object', 'INVALID_PREF_PAYLOAD', 'preference_payload must be an object', '22023');

  -- 1) recipient snapshot: 1 per rewrite_request_id
  begin
    insert into public.recipient_snapshots(
      recipient_snapshot_id,
      rewrite_request_id,
      home_id,
      recipient_user_ids
    )
    values (
      gen_random_uuid(),
      p_rewrite_request_id,
      p_home_id,
      array[p_recipient_user_id]
    )
    returning recipient_snapshot_id into v_recipient_snapshot_id;
  exception when unique_violation then
    select rs.recipient_snapshot_id
      into v_recipient_snapshot_id
      from public.recipient_snapshots rs
     where rs.rewrite_request_id = p_rewrite_request_id
     limit 1;
  end;

  perform public.api_assert(v_recipient_snapshot_id is not null, 'SNAPSHOT_MISSING', 'recipient snapshot missing', '22023');

  -- 2) preference snapshot: 1 per (rewrite_request_id, recipient_user_id)
  begin
    insert into public.recipient_preference_snapshots(
      recipient_preference_snapshot_id,
      rewrite_request_id,
      recipient_user_id,
      preference_payload
    )
    values (
      gen_random_uuid(),
      p_rewrite_request_id,
      p_recipient_user_id,
      p_preference_payload
    )
    returning recipient_preference_snapshot_id into v_pref_snapshot_id;
  exception when unique_violation then
    select ps.recipient_preference_snapshot_id
      into v_pref_snapshot_id
      from public.recipient_preference_snapshots ps
     where ps.rewrite_request_id = p_rewrite_request_id
       and ps.recipient_user_id = p_recipient_user_id
     limit 1;
  end;

  perform public.api_assert(v_pref_snapshot_id is not null, 'PREF_SNAPSHOT_MISSING', 'recipient preference snapshot missing', '22023');

  return jsonb_build_object(
    'recipient_snapshot_id', v_recipient_snapshot_id,
    'recipient_preference_snapshot_id', v_pref_snapshot_id
  );
end;
$$;

revoke all on function public.complaint_build_recipient_snapshots(uuid,uuid,uuid,jsonb) from public;
grant execute on function public.complaint_build_recipient_snapshots(uuid,uuid,uuid,jsonb) to service_role;

-- ============================================================
-- L) Enqueue RPC (service_role only)
-- ============================================================

drop function if exists public.complaint_rewrite_enqueue(
  uuid, uuid, uuid, uuid,
  text, text, jsonb, jsonb, jsonb,
  text, text, text, jsonb, text, text, text, text, text, jsonb, jsonb, jsonb, int
);

create or replace function public.complaint_rewrite_enqueue(
  p_rewrite_request_id uuid,
  p_home_id uuid,
  p_sender_user_id uuid,
  p_recipient_user_id uuid,

  p_surface text,
  p_original_text text,

  p_rewrite_request jsonb,
  p_classifier_result jsonb,
  p_context_pack jsonb,

  p_source_locale text,
  p_target_locale text,
  p_lane text,

  p_topics jsonb,
  p_intent text,
  p_rewrite_strength text,

  p_classifier_version text,
  p_context_pack_version text,
  p_policy_version text,

  p_routing_decision jsonb,
  p_language_pair jsonb,

  p_preference_payload jsonb,

  p_max_attempts int default 2
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_id uuid := gen_random_uuid();
  v_inserted_request int := 0;
  v_inserted_job int := 0;
  v_snap jsonb;
  v_recipient_snapshot_id uuid;
  v_recipient_preference_snapshot_id uuid;
begin
  perform public.api_assert(p_surface in ('weekly_harmony','direct_message','other'), 'INVALID_SURFACE', 'Invalid surface.', '22023');
  perform public.api_assert(p_lane in ('same_language','cross_language'), 'INVALID_LANE', 'Invalid lane.', '22023');
  perform public.api_assert(p_rewrite_strength in ('light_touch','full_reframe'), 'INVALID_REWRITE_STRENGTH', 'Invalid rewrite_strength.', '22023');
  perform public.api_assert(nullif(btrim(p_original_text),'') is not null, 'INVALID_TEXT', 'original_text required.', '22023');
  perform public.api_assert(length(p_original_text) <= 500, 'TEXT_TOO_LONG', 'original_text max 500 chars.', '22023');
  perform public.api_assert(jsonb_typeof(p_preference_payload) = 'object', 'INVALID_PREF_PAYLOAD', 'preference_payload must be an object', '22023');

  -- 1) Insert rewrite_request stub FIRST
  insert into public.rewrite_requests(
    rewrite_request_id, home_id, sender_user_id, recipient_user_id,
    surface, original_text, source_locale, target_locale, lane,
    topics, intent, rewrite_strength,
    classifier_result, context_pack, rewrite_request,
    classifier_version, context_pack_version, policy_version,
    status
  ) values (
    p_rewrite_request_id, p_home_id, p_sender_user_id, p_recipient_user_id,
    p_surface, left(p_original_text, 500), p_source_locale, p_target_locale, p_lane,
    p_topics, p_intent, p_rewrite_strength,
    p_classifier_result, p_context_pack, p_rewrite_request,
    p_classifier_version, p_context_pack_version, p_policy_version,
    'queued'
  )
  on conflict (rewrite_request_id) do nothing;

  get diagnostics v_inserted_request = row_count;

  -- 2) Build snapshots (idempotent)
  v_snap := public.complaint_build_recipient_snapshots(
    p_rewrite_request_id,
    p_home_id,
    p_recipient_user_id,
    p_preference_payload
  );

  v_recipient_snapshot_id := (v_snap->>'recipient_snapshot_id')::uuid;
  v_recipient_preference_snapshot_id := (v_snap->>'recipient_preference_snapshot_id')::uuid;

  perform public.api_assert(v_recipient_snapshot_id is not null, 'SNAPSHOT_MISSING', 'recipient snapshot missing', '22023');
  perform public.api_assert(v_recipient_preference_snapshot_id is not null, 'PREF_SNAPSHOT_MISSING', 'recipient preference snapshot missing', '22023');

  -- 3) Update request with snapshot FKs (nullable-at-insert pattern)
  update public.rewrite_requests r
     set recipient_snapshot_id = coalesce(r.recipient_snapshot_id, v_recipient_snapshot_id),
         recipient_preference_snapshot_id = coalesce(r.recipient_preference_snapshot_id, v_recipient_preference_snapshot_id),
         updated_at = now()
   where r.rewrite_request_id = p_rewrite_request_id;

  -- 4) Insert job (idempotent)
  insert into public.rewrite_jobs(
    job_id,
    rewrite_request_id,
    recipient_user_id,
    recipient_snapshot_id,
    recipient_preference_snapshot_id,
    task,
    surface,
    rewrite_strength,
    language_pair,
    lane,
    routing_decision,
    status,
    max_attempts
  ) values (
    v_job_id,
    p_rewrite_request_id,
    p_recipient_user_id,
    v_recipient_snapshot_id,
    v_recipient_preference_snapshot_id,
    'complaint_rewrite',
    p_surface,
    p_rewrite_strength,
    p_language_pair,
    p_lane,
    p_routing_decision,
    'queued',
    coalesce(p_max_attempts, 2)
  )
  on conflict (rewrite_request_id, recipient_user_id) do nothing;

  get diagnostics v_inserted_job = row_count;

  if not v_inserted_job then
    select j.job_id into v_job_id
      from public.rewrite_jobs j
     where j.rewrite_request_id = p_rewrite_request_id
       and j.recipient_user_id = p_recipient_user_id
     limit 1;
  end if;

  return jsonb_build_object(
    'rewrite_request_id', p_rewrite_request_id,
    'job_id', v_job_id,
    'recipient_snapshot_id', v_recipient_snapshot_id,
    'recipient_preference_snapshot_id', v_recipient_preference_snapshot_id,
    'inserted_request', v_inserted_request = 1,
    'inserted_job', v_inserted_job = 1
  );
end;
$$;

revoke all on function public.complaint_rewrite_enqueue(
  uuid, uuid, uuid, uuid,
  text, text, jsonb, jsonb, jsonb,
  text, text, text, jsonb, text, text, text, text, text, jsonb, jsonb, jsonb, int
) from public;

grant execute on function public.complaint_rewrite_enqueue(
  uuid, uuid, uuid, uuid,
  text, text, jsonb, jsonb, jsonb,
  text, text, text, jsonb, text, text, text, text, text, jsonb, jsonb, jsonb, int
) to service_role;

-- ============================================================
-- M) complaint_fetch_entry_locales (service_role only)
-- ============================================================

create or replace function public.complaint_fetch_entry_locales(
  p_entry_id uuid,
  p_recipient_user_id uuid
) returns table(
  original_text text,
  recipient_locale text,
  home_id uuid,
  author_user_id uuid,
  recipient_user_id uuid
)
language sql
security definer
set search_path = ''
as $$
  select
    coalesce(hme.comment, '') as original_text,
    coalesce(lower(split_part(np.locale, '-', 1)), 'en') as recipient_locale,
    hme.home_id as home_id,
    hme.user_id as author_user_id,
    p_recipient_user_id as recipient_user_id
  from public.home_mood_entries hme
  left join public.notification_preferences np
    on np.user_id = p_recipient_user_id
  where hme.id = p_entry_id;
$$;

revoke all on function public.complaint_fetch_entry_locales(uuid, uuid) from public;
revoke all on function public.complaint_fetch_entry_locales(uuid, uuid) from anon, authenticated;
grant execute on function public.complaint_fetch_entry_locales(uuid, uuid) to service_role;

-- ============================================================
-- N) Batch submitter/collector RPCs (aligned names with your TS)
-- ============================================================

-- (1) Claim jobs for batch submitter: queued -> processing
drop function if exists public.claim_rewrite_jobs_for_batch_submit_v1(int);
drop function if exists public.claim_rewrite_jobs_for_batch_submit(int);

create or replace function public.claim_rewrite_jobs_for_batch_submit_v1(
  p_limit int default 50
) returns table (
  job_id uuid,
  rewrite_request_id uuid,
  recipient_user_id uuid,
  routing_decision jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  worker_id text := coalesce(
    nullif(current_setting('request.headers.x-worker-id', true), ''),
    'rewrite_batch_submitter'
  );
begin
  return query
  with cte as (
    select j.job_id
    from public.rewrite_jobs j
    where j.status = 'queued'
      and (j.not_before_at is null or j.not_before_at <= now())
      and j.provider_batch_id is null
      and j.submitted_at is null
    order by j.created_at asc
    for update skip locked
    limit p_limit
  ),
  claimed as (
    update public.rewrite_jobs j
       set status = 'processing',
           claimed_at = now(),
           claimed_by = worker_id,
           attempt_count = j.attempt_count + 1,
           updated_at = now()
    from cte
    where j.job_id = cte.job_id
    returning j.job_id, j.rewrite_request_id, j.recipient_user_id, j.routing_decision
  )
  select * from claimed;
end;
$$;

revoke all on function public.claim_rewrite_jobs_for_batch_submit_v1(int) from public;
grant execute on function public.claim_rewrite_jobs_for_batch_submit_v1(int) to service_role;

-- (2) Mark jobs batch submitted: processing -> batch_submitted
drop function if exists public.mark_rewrite_jobs_batch_submitted_v1(uuid[], text);
drop function if exists public.mark_rewrite_jobs_batch_submitted(uuid[], text);

create or replace function public.mark_rewrite_jobs_batch_submitted_v1(
  p_job_ids uuid[],
  p_provider_batch_id text
) returns void
language sql
security definer
set search_path = ''
as $$
  update public.rewrite_jobs
     set status = 'batch_submitted',
         provider_batch_id = p_provider_batch_id,
         submitted_at = now(),
         updated_at = now()
   where job_id = any(p_job_ids)
     and status = 'processing';
$$;

revoke all on function public.mark_rewrite_jobs_batch_submitted_v1(uuid[], text) from public;
grant execute on function public.mark_rewrite_jobs_batch_submitted_v1(uuid[], text) to service_role;

-- (3) Requeue after submit failure: processing -> queued (optional helper)
drop function if exists public.requeue_jobs_after_submit_failure(uuid[], text, int);

create or replace function public.requeue_jobs_after_submit_failure(
  p_job_ids uuid[],
  p_error text,
  p_backoff_seconds int default 600
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_backoff int := greatest(30, least(coalesce(p_backoff_seconds, 600), 6*3600));
begin
  update public.rewrite_jobs
     set status = 'queued',
         not_before_at = now() + make_interval(secs => v_backoff),
         last_error = left(coalesce(p_error,'submit_failed'), 512),
         last_error_at = now(),
         updated_at = now()
   where job_id = any(p_job_ids)
     and status = 'processing';
end;
$$;

revoke all on function public.requeue_jobs_after_submit_failure(uuid[], text, int) from public;
grant execute on function public.requeue_jobs_after_submit_failure(uuid[], text, int) to service_role;

-- ============================================================
-- (OPTION A) Batch collector claim RPCs (aligned names)
-- ============================================================

-- (A fallback) Claim jobs for batch collect: batch_submitted -> processing
drop function if exists public.claim_rewrite_jobs_for_batch_collect_v1(int);
drop function if exists public.claim_rewrite_jobs_for_batch_collect(int);

create or replace function public.claim_rewrite_jobs_for_batch_collect_v1(
  p_limit int default 200
) returns table (
  job_id uuid,
  rewrite_request_id uuid,
  recipient_user_id uuid,
  provider_batch_id text,
  routing_decision jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  worker_id text := coalesce(
    nullif(current_setting('request.headers.x-worker-id', true), ''),
    'rewrite_batch_collector'
  );
begin
  return query
  with cte as (
    select j.job_id
    from public.rewrite_jobs j
    where j.status = 'batch_submitted'
    order by j.submitted_at asc nulls last, j.created_at asc
    for update skip locked
    limit p_limit
  ),
  claimed as (
    update public.rewrite_jobs j
       set status = 'processing',
           claimed_at = now(),
           claimed_by = worker_id,
           updated_at = now()
    from cte
    where j.job_id = cte.job_id
    returning j.job_id, j.rewrite_request_id, j.recipient_user_id, j.provider_batch_id, j.routing_decision
  ),
  mark_req as (
    update public.rewrite_requests r
       set status = 'processing',
           updated_at = now()
     where r.rewrite_request_id in (select rewrite_request_id from claimed)
       and r.status = 'queued'
  )
  select * from claimed;
end;
$$;

revoke all on function public.claim_rewrite_jobs_for_batch_collect_v1(int) from public;
grant execute on function public.claim_rewrite_jobs_for_batch_collect_v1(int) to service_role;

-- (A.1 recommended) Claim EXACT job_ids for batch collect: batch_submitted -> processing
drop function if exists public.claim_rewrite_jobs_by_ids_for_collect_v1(uuid[]);
drop function if exists public.claim_rewrite_jobs_by_ids_for_collect(uuid[]);

create or replace function public.claim_rewrite_jobs_by_ids_for_collect_v1(
  p_job_ids uuid[]
) returns table (
  job_id uuid,
  rewrite_request_id uuid,
  recipient_user_id uuid,
  provider_batch_id text,
  routing_decision jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  worker_id text := coalesce(
    nullif(current_setting('request.headers.x-worker-id', true), ''),
    'rewrite_batch_collector'
  );
begin
  return query
  with claimed as (
    update public.rewrite_jobs j
       set status='processing',
           claimed_at=now(),
           claimed_by=worker_id,
           updated_at=now()
     where j.job_id = any(p_job_ids)
       and j.status = 'batch_submitted'
     returning j.job_id, j.rewrite_request_id, j.recipient_user_id, j.provider_batch_id, j.routing_decision
  ),
  mark_req as (
    update public.rewrite_requests r
       set status='processing',
           updated_at=now()
     where r.rewrite_request_id in (select rewrite_request_id from claimed)
       and r.status='queued'
  )
  select * from claimed;
end;
$$;

revoke all on function public.claim_rewrite_jobs_by_ids_for_collect_v1(uuid[]) from public;
grant execute on function public.claim_rewrite_jobs_by_ids_for_collect_v1(uuid[]) to service_role;

-- ============================================================
-- (4) Batch registry/update/list (rewrite_provider_batches only)
-- ============================================================

create or replace function public.rewrite_batch_register_v1(
  p_provider_batch_id text,
  p_input_file_id text,
  p_job_count int,
  p_endpoint text default '/v1/responses'
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.rewrite_provider_batches(
    provider_batch_id, provider, endpoint, status, input_file_id, job_count
  ) values (
    p_provider_batch_id, 'openai', p_endpoint, 'submitted', p_input_file_id, coalesce(p_job_count,0)
  )
  on conflict (provider_batch_id)
  do update set
    input_file_id = excluded.input_file_id,
    job_count = excluded.job_count,
    status = case
      when public.rewrite_provider_batches.status in ('completed','failed','canceled') then public.rewrite_provider_batches.status
      else excluded.status
    end,
    updated_at = now();
$$;

revoke all on function public.rewrite_batch_register_v1(text, text, int, text) from public;
grant execute on function public.rewrite_batch_register_v1(text, text, int, text) to service_role;

create or replace function public.rewrite_batch_update_v1(
  p_provider_batch_id text,
  p_status text,
  p_output_file_id text default null,
  p_error_file_id text default null
) returns void
language sql
security definer
set search_path = ''
as $$
  update public.rewrite_provider_batches
     set status = p_status,
         output_file_id = coalesce(p_output_file_id, output_file_id),
         error_file_id = coalesce(p_error_file_id, error_file_id),
         last_checked_at = now(),
         updated_at = now()
   where provider_batch_id = p_provider_batch_id;
$$;

revoke all on function public.rewrite_batch_update_v1(text, text, text, text) from public;
grant execute on function public.rewrite_batch_update_v1(text, text, text, text) to service_role;

create or replace function public.rewrite_batch_list_pending_v1(
  p_limit int default 20
) returns table (
  provider_batch_id text,
  status text,
  input_file_id text,
  output_file_id text,
  error_file_id text,
  endpoint text
)
language sql
security definer
set search_path = ''
as $$
  select provider_batch_id, status, input_file_id, output_file_id, error_file_id, endpoint
  from public.rewrite_provider_batches
  where status in ('submitted','running')
  order by coalesce(last_checked_at, created_at) asc
  limit p_limit;
$$;

revoke all on function public.rewrite_batch_list_pending_v1(int) from public;
grant execute on function public.rewrite_batch_list_pending_v1(int) to service_role;

-- ============================================================
-- O) Job fetch helper (used by workers)
-- ============================================================

create or replace function public.rewrite_job_fetch_v1(
  p_job_id uuid
) returns table (
  job_id uuid,
  rewrite_request_id uuid,
  recipient_user_id uuid,
  status text,
  provider_batch_id text,
  routing_decision jsonb
)
language sql
security definer
set search_path = ''
as $$
  select j.job_id, j.rewrite_request_id, j.recipient_user_id, j.status, j.provider_batch_id, j.routing_decision
  from public.rewrite_jobs j
  where j.job_id = p_job_id
  limit 1;
$$;

revoke all on function public.rewrite_job_fetch_v1(uuid) from public;
grant execute on function public.rewrite_job_fetch_v1(uuid) to service_role;

-- ============================================================
-- O.1) Requeue jobs by provider batch (FIXED: uses rewrite_jobs + not_before_at)
-- ============================================================

create or replace function public.rewrite_jobs_requeue_by_provider_batch_v1(
  p_provider_batch_id text,
  p_reason text default 'provider_batch_missing_output_file',
  p_backoff_seconds int default 1800,     -- 30 minutes
  p_limit int default 500                 -- safety cap
) returns table (
  job_id uuid,
  prev_status text,
  new_status text,
  not_before_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_not_before timestamptz := v_now + make_interval(secs => greatest(coalesce(p_backoff_seconds, 0), 0));
begin
  if p_provider_batch_id is null or btrim(p_provider_batch_id) = '' then
    raise exception 'p_provider_batch_id required';
  end if;

  return query
  with target as (
    select j.job_id, j.status as prev_status
    from public.rewrite_jobs j
    where j.provider_batch_id = p_provider_batch_id
      and j.status = 'batch_submitted'
    order by j.job_id
    limit greatest(p_limit, 0)
    for update
  ),
  upd as (
    update public.rewrite_jobs j
    set
      status = 'queued',
      not_before_at = v_not_before,
      last_error = left(coalesce(p_reason, 'requeued') || ': batch=' || p_provider_batch_id, 512),
      last_error_at = v_now,
      updated_at = v_now,
      provider_batch_id = null,
      submitted_at = null
    from target t
    where j.job_id = t.job_id
    returning j.job_id, t.prev_status, j.status as new_status, j.not_before_at
  )
  select * from upd;
end;
$$;

revoke all on function public.rewrite_jobs_requeue_by_provider_batch_v1(text, text, int, int) from public;
grant execute on function public.rewrite_jobs_requeue_by_provider_batch_v1(text, text, int, int) to service_role;

-- ============================================================
-- P) CRON: submitter + collector
-- ============================================================

select cron.schedule(
  'complaint_rewrite_batch_submitter_15m',
  '*/15 * * * *',
  $$
  select net.http_post(
    url =>
      current_setting('app.settings.supabase_url', true)
      || '/functions/v1/rewrite_batch_submitter',
    headers =>
      jsonb_build_object(
        'x-internal-secret',
        current_setting('app.settings.worker_shared_secret', true),
        'x-worker-id',
        'cron_batch_submitter'
      ),
    body => '{}'::jsonb
  );
  $$
);

select cron.schedule(
  'complaint_rewrite_batch_collector_30m',
  '*/30 * * * *',
  $$
  select net.http_post(
    url =>
      current_setting('app.settings.supabase_url', true)
      || '/functions/v1/rewrite_batch_collector',
    headers =>
      jsonb_build_object(
        'x-internal-secret',
        current_setting('app.settings.worker_shared_secret', true),
        'x-worker-id',
        'cron_batch_collector'
      ),
    body => '{}'::jsonb
  );
  $$
);
