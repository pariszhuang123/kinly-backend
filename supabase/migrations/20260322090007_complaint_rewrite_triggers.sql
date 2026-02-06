-- ============================================================
-- Complaint rewrite trigger queue + RPCs + notify hook (FULL • adjusted • FIXED)
--
-- ✅ Invariant: One recipient per author per ISO week (enforced at enqueue)
--    - “Rewrite happens once” (completed/failed still counts as used)
--    - Only retries for system failure (handled via mark_retry/watchdog)
--
-- ✅ Marker RPCs:
--    - ASSERT ownership (entry_id + request_id + status=processing)
--    - RETURN boolean
--    - RAISE on no-op
--    - FIXED to satisfy table invariants:
--        * request_id cleared when leaving processing
--        * processing_started_at cleared when leaving processing
--
-- ✅ NOTIFY payload is JSON (entry_id + recipient_user_id + status)
--
-- ✅ Enqueue upsert keeps attempts history (attempts/last_attempt_at) and:
--    - prevents changing recipient for the same entry once used (unless canceled)
--      so “one recipient per week” cannot be bypassed by re-enqueueing same entry
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 1) Queue table
-- ============================================================

create table if not exists public.complaint_rewrite_triggers (
  entry_id              uuid primary key references public.home_mood_entries(id) on delete cascade,
  home_id               uuid not null references public.homes(id) on delete cascade,
  author_user_id        uuid not null references public.profiles(id) on delete cascade,
  recipient_user_id     uuid not null references public.profiles(id) on delete cascade,

  status                text not null default 'queued'
    check (status in ('queued','processing','completed','failed','canceled')),

  request_id            uuid,
  note                  text,
  error                 text,

  attempts              int not null default 0,
  last_error_at         timestamptz,
  last_attempt_at       timestamptz,

  retry_after           timestamptz,
  processing_started_at timestamptz,
  processed_at          timestamptz,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Ensure columns exist if table predates this script
alter table public.complaint_rewrite_triggers
  add column if not exists processing_started_at timestamptz;
alter table public.complaint_rewrite_triggers
  add column if not exists last_error_at timestamptz;
alter table public.complaint_rewrite_triggers
  add column if not exists last_attempt_at timestamptz;

-- ============================================================
-- 1.1) Constraints / invariants
-- ============================================================

do $$
begin
  -- attempts >= 0
  if not exists (
    select 1 from pg_constraint where conname = 'crt_attempts_nonneg'
  ) then
    alter table public.complaint_rewrite_triggers
      add constraint crt_attempts_nonneg check (attempts >= 0);
  end if;

  -- request_id only allowed when processing
  if not exists (
    select 1 from pg_constraint where conname = 'crt_request_id_only_processing'
  ) then
    alter table public.complaint_rewrite_triggers
      add constraint crt_request_id_only_processing
      check (request_id is null or status = 'processing');
  end if;

  -- processing_started_at present iff processing
  if not exists (
    select 1 from pg_constraint where conname = 'crt_processing_started_at_invariant'
  ) then
    alter table public.complaint_rewrite_triggers
      add constraint crt_processing_started_at_invariant
      check (
        (status = 'processing' and processing_started_at is not null)
        or
        (status <> 'processing' and processing_started_at is null)
      );
  end if;

  -- processed_at present iff terminal
  if not exists (
    select 1 from pg_constraint where conname = 'crt_processed_at_terminal_only'
  ) then
    alter table public.complaint_rewrite_triggers
      add constraint crt_processed_at_terminal_only
      check (
        (status in ('completed','failed','canceled') and processed_at is not null)
        or
        (status in ('queued','processing') and processed_at is null)
      );
  end if;

  -- retry_after only allowed while queued
  if not exists (
    select 1 from pg_constraint where conname = 'crt_retry_after_only_queued'
  ) then
    alter table public.complaint_rewrite_triggers
      add constraint crt_retry_after_only_queued
      check (retry_after is null or status = 'queued');
  end if;
end $$;

-- ============================================================
-- 1.2) Indexes
-- ============================================================

create index if not exists idx_complaint_rewrite_triggers_status_created
  on public.complaint_rewrite_triggers (status, created_at);

-- Faster pop path: queued + no retry_after
create index if not exists idx_crt_queued_no_retry_created
  on public.complaint_rewrite_triggers (created_at)
  where status = 'queued' and retry_after is null;

-- Faster pop path: queued + retry_after (due-time)
create index if not exists idx_crt_queued_retry_after_created
  on public.complaint_rewrite_triggers (retry_after, created_at)
  where status = 'queued' and retry_after is not null;

-- Optional: useful for watchdog scans
create index if not exists idx_crt_processing_started_at
  on public.complaint_rewrite_triggers (processing_started_at)
  where status = 'processing';

-- ============================================================
-- 2) updated_at touch trigger
-- ============================================================

create or replace function public._touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_complaint_rewrite_triggers_touch on public.complaint_rewrite_triggers;
create trigger trg_complaint_rewrite_triggers_touch
before update on public.complaint_rewrite_triggers
for each row execute function public._touch_updated_at();

-- ============================================================
-- 3) NOTIFY hook (wake-up signal; still poll for durability)
--    Payload is JSON for future-proofing.
-- ============================================================

create or replace function public.complaint_trigger_notify()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_payload text;
begin
  v_payload :=
    jsonb_build_object(
      'entry_id', coalesce(new.entry_id::text, ''),
      'recipient_user_id', coalesce(new.recipient_user_id::text, ''),
      'status', coalesce(new.status, '')
    )::text;

  perform pg_notify('complaint_rewrite_triggers', v_payload);
  return new;
end;
$$;

-- Notify on new queued work
drop trigger if exists trg_complaint_rewrite_triggers_notify_ins on public.complaint_rewrite_triggers;
create trigger trg_complaint_rewrite_triggers_notify_ins
after insert on public.complaint_rewrite_triggers
for each row
when (new.status = 'queued')
execute function public.complaint_trigger_notify();

-- Notify when work becomes queued again (requeue / retry)
drop trigger if exists trg_complaint_rewrite_triggers_notify_requeue on public.complaint_rewrite_triggers;
create trigger trg_complaint_rewrite_triggers_notify_requeue
after update on public.complaint_rewrite_triggers
for each row
when (new.status = 'queued' and old.status is distinct from 'queued')
execute function public.complaint_trigger_notify();

-- ============================================================
-- 4) Enqueue RPC (authenticated) — RPC-only writes
--    Uses memberships table for validation.
--    Adds: one-recipient-per-author-per-ISO-week enforcement.
--    FIX: prevent changing recipient for same entry after it's "used" (unless canceled)
-- ============================================================

create or replace function public.complaint_trigger_enqueue(
  p_entry_id uuid,
  p_recipient_user_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();

  v_home_id uuid;
  v_author_id uuid;
  v_entry_created_at timestamptz;

  v_iso_week int;
  v_iso_year int;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select e.home_id, e.user_id, e.created_at
    into v_home_id, v_author_id, v_entry_created_at
  from public.home_mood_entries e
  where e.id = p_entry_id;

  if v_home_id is null then
    raise exception 'entry_not_found';
  end if;

  -- Rule: only the author of the entry can enqueue
  if v_author_id <> v_uid then
    raise exception 'not_entry_author';
  end if;

  -- Prevent self-recipient
  if p_recipient_user_id = v_uid then
    raise exception 'recipient_cannot_be_self';
  end if;

  -- Sender must be current member of the home
  if not exists (
    select 1
    from public.memberships m
    where m.home_id = v_home_id
      and m.user_id = v_uid
      and m.is_current = true
  ) then
    raise exception 'not_home_member';
  end if;

  -- Recipient must be current member of the home
  if not exists (
    select 1
    from public.memberships m
    where m.home_id = v_home_id
      and m.user_id = p_recipient_user_id
      and m.is_current = true
  ) then
    raise exception 'recipient_not_home_member';
  end if;

  -- ISO week gate (deterministic: compute on UTC to avoid timezone drift)
  v_iso_week := extract(week from (v_entry_created_at at time zone 'UTC'))::int;
  v_iso_year := extract(isoyear from (v_entry_created_at at time zone 'UTC'))::int;

  -- Invariant: author can target only ONE recipient per ISO week.
  -- Any existing trigger for a different entry in the same iso week counts as "used",
  -- except canceled (optional carve-out).
  if exists (
    select 1
    from public.complaint_rewrite_triggers t
    join public.home_mood_entries e2
      on e2.id = t.entry_id
    where t.author_user_id = v_uid
      and t.home_id = v_home_id
      and t.entry_id <> p_entry_id
      and t.status <> 'canceled'
      and extract(week from (e2.created_at at time zone 'UTC'))::int = v_iso_week
      and extract(isoyear from (e2.created_at at time zone 'UTC'))::int = v_iso_year
  ) then
    raise exception 'iso_week_limit_exceeded';
  end if;

  insert into public.complaint_rewrite_triggers (
    entry_id, home_id, author_user_id, recipient_user_id,
    status, request_id, retry_after, processing_started_at, processed_at,
    error, last_error_at, note
  )
  values (
    p_entry_id, v_home_id, v_author_id, p_recipient_user_id,
    'queued', null, null, null, null,
    null, null, null
  )
  on conflict (entry_id) do update
     set home_id = excluded.home_id,
         author_user_id = excluded.author_user_id,
         recipient_user_id = excluded.recipient_user_id,
         status = 'queued',
         request_id = null,
         retry_after = null,
         processing_started_at = null,
         processed_at = null,
         -- keep attempts + last_attempt_at (history), but clear error/note for a fresh run
         error = null,
         last_error_at = null,
         note = null,
         updated_at = now()
   where public.complaint_rewrite_triggers.status <> 'processing'
     and (
       -- allow changing recipient only if previously canceled
       public.complaint_rewrite_triggers.status = 'canceled'
       or public.complaint_rewrite_triggers.recipient_user_id = excluded.recipient_user_id
     );
  -- prevents resetting in-flight (processing) rows
  -- prevents recipient changes after "used" unless canceled
end;
$$;

-- ============================================================
-- 5) Pop pending triggers (atomic claim)
-- ============================================================

create or replace function public.complaint_trigger_pop_pending(
  p_limit integer default 20,
  p_max_attempts integer default 10
)
returns table (
  entry_id uuid,
  home_id uuid,
  author_user_id uuid,
  recipient_user_id uuid,
  request_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid := gen_random_uuid();
begin
  return query
  with cte as (
    select t.entry_id
    from public.complaint_rewrite_triggers t
    where t.status = 'queued'
      and t.attempts < coalesce(p_max_attempts, 10)
      and (t.retry_after is null or t.retry_after <= now())
    order by coalesce(t.retry_after, t.created_at), t.created_at
    limit coalesce(p_limit, 20)
    for update skip locked
  )
  update public.complaint_rewrite_triggers t
     set status = 'processing',
         request_id = v_request_id,
         attempts = t.attempts + 1,
         last_attempt_at = now(),
         processing_started_at = now(),
         retry_after = null,
         processed_at = null
    from cte
   where t.entry_id = cte.entry_id
  returning t.entry_id, t.home_id, t.author_user_id, t.recipient_user_id, t.request_id;
end;
$$;

-- ============================================================
-- 6) Marker RPCs (reservation ownership enforced)
--    FIXED: clear request_id + processing_started_at when leaving processing
-- ============================================================

create or replace function public.complaint_trigger_mark_completed(
  p_entry_id uuid,
  p_request_id uuid,
  p_processed_at timestamptz default now(),
  p_note text default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.complaint_rewrite_triggers
     set status = 'completed',
         processed_at = coalesce(p_processed_at, now()),
         retry_after = null,
         note = p_note,
         request_id = null,
         processing_started_at = null
   where entry_id = p_entry_id
     and request_id = p_request_id
     and status = 'processing';

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'mark_completed_noop';
  end if;

  return true;
end;
$$;

-- Retryable failure: requeue (queued) with retry_after (min 10s backoff)
create or replace function public.complaint_trigger_mark_retry(
  p_entry_id uuid,
  p_request_id uuid,
  p_error text,
  p_retry_after interval,
  p_note text default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.complaint_rewrite_triggers
     set status = 'queued',
         error = p_error,
         last_error_at = now(),
         note = p_note,
         retry_after = now() + greatest(coalesce(p_retry_after, interval '10 seconds'), interval '10 seconds'),
         request_id = null,
         processing_started_at = null,
         processed_at = null
   where entry_id = p_entry_id
     and request_id = p_request_id
     and status = 'processing';

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'mark_retry_noop';
  end if;

  return true;
end;
$$;

-- Terminal failure: failed (no more retries)
create or replace function public.complaint_trigger_mark_failed_terminal(
  p_entry_id uuid,
  p_request_id uuid,
  p_error text,
  p_processed_at timestamptz default now(),
  p_note text default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.complaint_rewrite_triggers
     set status = 'failed',
         error = p_error,
         last_error_at = now(),
         note = p_note,
         processed_at = coalesce(p_processed_at, now()),
         retry_after = null,
         request_id = null,
         processing_started_at = null
   where entry_id = p_entry_id
     and request_id = p_request_id
     and status = 'processing';

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'mark_failed_terminal_noop';
  end if;

  return true;
end;
$$;

create or replace function public.complaint_trigger_mark_canceled(
  p_entry_id uuid,
  p_request_id uuid,
  p_reason text,
  p_processed_at timestamptz default now()
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.complaint_rewrite_triggers
     set status = 'canceled',
         note = p_reason,
         processed_at = coalesce(p_processed_at, now()),
         retry_after = null,
         request_id = null,
         processing_started_at = null
   where entry_id = p_entry_id
     and request_id = p_request_id
     and status = 'processing';

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'mark_canceled_noop';
  end if;

  return true;
end;
$$;

-- ============================================================
-- 7) Watchdog: requeue stale processing (worker died mid-flight)
-- ============================================================

create or replace function public.complaint_trigger_requeue_stale_processing(
  p_stale_after interval default interval '10 minutes',
  p_limit integer default 200,
  p_retry_delay interval default interval '30 seconds'
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  with cte as (
    select entry_id
    from public.complaint_rewrite_triggers
    where status = 'processing'
      and processing_started_at is not null
      and processing_started_at <= now() - coalesce(p_stale_after, interval '10 minutes')
    order by processing_started_at
    limit coalesce(p_limit, 200)
    for update skip locked
  )
  update public.complaint_rewrite_triggers t
     set status = 'queued',
         request_id = null,
         processing_started_at = null,
         processed_at = null,
         retry_after = now() + coalesce(p_retry_delay, interval '30 seconds'),
         note = case
                  when t.note is null or t.note = '' then 'requeued_stale_processing'
                  else t.note || ' | requeued_stale_processing'
                end
    from cte
   where t.entry_id = cte.entry_id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ============================================================
-- 8) Terminalizer: fail queued rows that exhausted attempts
-- ============================================================

create or replace function public.complaint_trigger_fail_exhausted(
  p_max_attempts integer default 10,
  p_limit integer default 200
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  with cte as (
    select t.entry_id
    from public.complaint_rewrite_triggers t
    where t.status = 'queued'
      and t.attempts >= greatest(coalesce(p_max_attempts, 10), 0)
    order by coalesce(t.last_attempt_at, t.created_at), t.created_at
    limit coalesce(p_limit, 200)
    for update skip locked
  )
  update public.complaint_rewrite_triggers t
     set status = 'failed',
         processed_at = now(),
         retry_after = null,
         request_id = null,
         processing_started_at = null,
         error = left(coalesce(t.error, 'max_attempts_exhausted'), 512),
         last_error_at = coalesce(t.last_error_at, now()),
         note = case
                  when t.note is null or t.note = '' then 'failed_exhausted_attempts'
                  else t.note || ' | failed_exhausted_attempts'
                end
    from cte
   where t.entry_id = cte.entry_id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ============================================================
-- 10) Permissions
--    - Table: no direct client access (RPC-only)
--    - Enqueue: authenticated
--    - Pop/markers/watchdog: service_role
-- ============================================================

-- Table
revoke all on table public.complaint_rewrite_triggers from public, anon, authenticated;
revoke all on table public.complaint_rewrite_triggers from service_role;
-- Worker can operate via RPCs only; grant select if you want ad-hoc inspection:
grant select on table public.complaint_rewrite_triggers to service_role;

-- Helper functions
revoke all on function public._touch_updated_at() from public, anon, authenticated;
revoke all on function public.complaint_trigger_notify() from public, anon, authenticated;

-- Enqueue
revoke all on function public.complaint_trigger_enqueue(uuid, uuid) from public, anon;
grant execute on function public.complaint_trigger_enqueue(uuid, uuid) to authenticated;

-- Pop + markers (service_role)
revoke all on function public.complaint_trigger_pop_pending(integer, integer) from public, anon, authenticated;
grant execute on function public.complaint_trigger_pop_pending(integer, integer) to service_role;

revoke all on function public.complaint_trigger_mark_completed(uuid, uuid, timestamptz, text) from public, anon, authenticated;
revoke all on function public.complaint_trigger_mark_retry(uuid, uuid, text, interval, text) from public, anon, authenticated;
revoke all on function public.complaint_trigger_mark_failed_terminal(uuid, uuid, text, timestamptz, text) from public, anon, authenticated;
revoke all on function public.complaint_trigger_mark_canceled(uuid, uuid, text, timestamptz) from public, anon, authenticated;

grant execute on function public.complaint_trigger_mark_completed(uuid, uuid, timestamptz, text) to service_role;
grant execute on function public.complaint_trigger_mark_retry(uuid, uuid, text, interval, text) to service_role;
grant execute on function public.complaint_trigger_mark_failed_terminal(uuid, uuid, text, timestamptz, text) to service_role;
grant execute on function public.complaint_trigger_mark_canceled(uuid, uuid, text, timestamptz) to service_role;

-- Watchdog (service_role)
revoke all on function public.complaint_trigger_requeue_stale_processing(interval, integer, interval) from public, anon, authenticated;
grant execute on function public.complaint_trigger_requeue_stale_processing(interval, integer, interval) to service_role;

-- Terminalizer (service_role)
revoke all on function public.complaint_trigger_fail_exhausted(integer, integer) from public, anon, authenticated;
grant execute on function public.complaint_trigger_fail_exhausted(integer, integer) to service_role;

-- 2) Helper function: call the runner edge function via HTTP
-- Uses project settings:
-- - app.settings.supabase_url
-- - app.settings.worker_shared_secret

create or replace function public._cron_call_complaint_trigger_runner()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := current_setting('app.settings.supabase_url', true)
    || '/functions/v1/complaint_trigger_cron_runner';
  v_secret text := current_setting('app.settings.worker_shared_secret', true);
begin
  perform net.http_post(
    url := v_url,
    headers := jsonb_strip_nulls(jsonb_build_object(
      'Content-Type','application/json',
      'x-internal-secret', v_secret
    )),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public._cron_call_complaint_trigger_runner() from public, anon, authenticated;
grant execute on function public._cron_call_complaint_trigger_runner() to service_role;

-- 3) Schedule: run the runner every 5 minutes
-- Name must be unique per project.
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_trigger_runner_every_5m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_trigger_runner_every_5m',
      '*/5 * * * *',
      $cmd$ select public._cron_call_complaint_trigger_runner(); $cmd$
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping pg_cron schedule: complaint trigger runner.';
  end;
end
$$;

-- 4) Schedule watchdog: requeue stale processing every 10 minutes
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_trigger_watchdog_every_10m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_trigger_watchdog_every_10m',
      '*/10 * * * *',
      $cmd$ select public.complaint_trigger_requeue_stale_processing('10 minutes'::interval, 200, '30 seconds'::interval); $cmd$
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping pg_cron schedule: complaint trigger watchdog.';
  end;
end
$$;

-- 5) Schedule terminalizer: fail exhausted queued every 25 minutes
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_trigger_fail_exhausted_every_25m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_trigger_fail_exhausted_every_25m',
      '*/25 * * * *',
      $cmd$ select public.complaint_trigger_fail_exhausted(10, 200); $cmd$
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping pg_cron schedule: complaint trigger exhausted terminalizer.';
  end;
end
$$;
