-- Fix complaint_rewrite_enqueue row_count boolean check.

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

  update public.rewrite_requests r
     set recipient_snapshot_id = coalesce(r.recipient_snapshot_id, v_recipient_snapshot_id),
         recipient_preference_snapshot_id = coalesce(r.recipient_preference_snapshot_id, v_recipient_preference_snapshot_id),
         updated_at = now()
   where r.rewrite_request_id = p_rewrite_request_id;

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

  if v_inserted_job = 0 then
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
