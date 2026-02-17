-- complaint_trigger_runner_diagnostics.sql
-- Purpose: Diagnose why complaint_rewrite_triggers rows remain queued.

-- 1) Cron schedule + latest executions
select j.jobid, j.jobname, j.schedule, j.active
from cron.job j
where j.jobname = 'complaint_trigger_runner_every_5m';

select d.jobid, d.status, d.return_message, d.start_time, d.end_time
from cron.job_run_details d
where d.jobid in (
  select j.jobid
  from cron.job j
  where j.jobname = 'complaint_trigger_runner_every_5m'
)
order by d.start_time desc
limit 20;

-- 2) Queue eligibility snapshot (matches complaint_trigger_pop_pending defaults)
select
  count(*) filter (where t.status = 'queued') as queued_total,
  count(*) filter (
    where t.status = 'queued'
      and t.attempts < 10
      and (t.retry_after is null or t.retry_after <= now())
  ) as queued_eligible_now,
  count(*) filter (
    where t.status = 'queued'
      and t.retry_after > now()
  ) as queued_waiting_backoff,
  count(*) filter (
    where t.status = 'queued'
      and t.attempts >= 10
  ) as queued_exhausted
from public.complaint_rewrite_triggers t;

-- 3) Secret presence for cron headers / URLs
select s.name
from vault.decrypted_secrets s
where s.name in ('SUPABASE_URL', 'RUNNER_SHARED_SECRET', 'WORKER_SHARED_SECRET')
order by s.name;

-- 4) Recent queue rows for forensic detail
select
  t.entry_id,
  t.status,
  t.attempts,
  t.request_id,
  t.retry_after,
  t.last_attempt_at,
  t.last_error_at,
  left(coalesce(t.error, ''), 220) as error_sample,
  left(coalesce(t.note, ''), 220) as note_sample,
  t.created_at,
  t.updated_at
from public.complaint_rewrite_triggers t
order by t.updated_at desc
limit 30;

-- 5) Quick interpretation aid
select
  case
    when exists (
      select 1
      from cron.job_run_details d
      where d.jobid in (
        select j.jobid from cron.job j where j.jobname='complaint_trigger_runner_every_5m'
      )
      and d.start_time > now() - interval '30 minutes'
      and d.status = 'failed'
    ) then 'cron_invocation_failed_or_runner_rejected'
    when exists (
      select 1
      from public.complaint_rewrite_triggers t
      where t.status = 'queued'
        and t.attempts < 10
        and (t.retry_after is null or t.retry_after <= now())
    ) then 'eligible_rows_exist_but_not_claimed_check_runner_env_or_rpc_auth'
    else 'no_immediate_claimable_rows_or_issue_not_recent'
  end as diagnosis_hint;

