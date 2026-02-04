-- ============================================================
-- FULL ADJUSTED SQL (v1.1+) — complaint_rewrite batch + realtime
-- Matches your latest choices:
-- 1) rewrite_requests snapshot FK columns are NULLABLE at insert time
-- 2) RLS enabled for ALL tables (deny-by-default posture)
-- 3) DB-enforced topic correctness:
--    - topics jsonb array
--    - length 1..3
--    - elements from allowed set
-- 4) FK: rewrite_jobs.provider_batch_id -> rewrite_provider_batches(provider_batch_id)
-- 5) rewrite_jobs.status includes 'batch_submitted'
-- 6) provider_job_custom_id removed
-- 7) rewrite_outputs language check uses _locale_primary(...)
--
-- Extra hardening added:
-- - explicit NOT VALID then VALIDATE for new FKs (safer in prod)
-- - stricter JSON object guards for rewrite_requests and rewrite_jobs
-- - triggers are idempotent
-- - provider_batches legacy table dropped
-- ============================================================

/* ============================================================
   0) Prereq: uuid generator
   ============================================================ */
create extension if not exists pgcrypto;

/* ============================================================
   0A) updated_at helper
   ============================================================ */
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

/* ============================================================
   0B) Locale helper: primary language from locale tag (e.g. "en-NZ" -> "en")
   ============================================================ */
create or replace function public._locale_primary(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(lower(split_part(coalesce(p,''), '-', 1)), '');
$$;

revoke all on function public._locale_primary(text) from public;
grant execute on function public._locale_primary(text) to service_role;

/* ============================================================
   0C) Topics validator (immutable; allowed enum + length)
   ============================================================ */
create or replace function public._complaint_topics_valid(p jsonb)
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select
    jsonb_typeof(p) = 'array'
    and jsonb_array_length(p) between 1 and 3
    and (
      select coalesce(bool_and(elem in (
        'noise','cleanliness','privacy','guests','schedule','communication','other'
      )), false)
      from jsonb_array_elements_text(p) e(elem)
    );
$$;

revoke all on function public._complaint_topics_valid(jsonb) from public;
grant execute on function public._complaint_topics_valid(jsonb) to service_role;

/* ============================================================
   1) Snapshot tables (Option 1: per rewrite_request_id)
   ============================================================ */
create table if not exists public.recipient_snapshots (
  recipient_snapshot_id uuid primary key default gen_random_uuid(),
  rewrite_request_id uuid not null,
  home_id uuid not null,
  recipient_user_ids uuid[] not null,
  created_at timestamptz not null default now()
);

-- One snapshot row per rewrite_request_id (Option 1)
create unique index if not exists ux_recipient_snapshots_req
  on public.recipient_snapshots(rewrite_request_id);

create table if not exists public.recipient_preference_snapshots (
  recipient_preference_snapshot_id uuid primary key default gen_random_uuid(),
  rewrite_request_id uuid not null,
  recipient_user_id uuid not null,
  preference_payload jsonb not null,
  created_at timestamptz not null default now(),
  constraint ck_recipient_preference_payload_obj check (jsonb_typeof(preference_payload) = 'object')
);

-- One row per (request, recipient)
create unique index if not exists ux_recipient_preference_snapshots_req_recipient
  on public.recipient_preference_snapshots(rewrite_request_id, recipient_user_id);

create index if not exists ix_recipient_preference_snapshots_req
  on public.recipient_preference_snapshots(rewrite_request_id);

/* ============================================================
   2) Rewrite requests (request-level envelope)
   ============================================================ */
create table if not exists public.rewrite_requests (
  rewrite_request_id uuid primary key,
  home_id uuid not null,
  sender_user_id uuid not null,
  recipient_user_id uuid not null,

  -- IMPORTANT: nullable at insert time to avoid circular FK deadlock.
  recipient_snapshot_id uuid
    references public.recipient_snapshots(recipient_snapshot_id),

  recipient_preference_snapshot_id uuid
    references public.recipient_preference_snapshots(recipient_preference_snapshot_id),

  surface text not null check (surface in ('weekly_harmony','direct_message','other')),
  original_text text not null,

  source_locale text not null,
  target_locale text not null,
  lane text not null check (lane in ('same_language','cross_language')),

  topics jsonb not null,
  intent text not null check (intent in ('request','boundary','concern','clarification')),
  rewrite_strength text not null check (rewrite_strength in ('light_touch','full_reframe')),

  classifier_result jsonb not null,
  context_pack jsonb not null,
  rewrite_request jsonb not null,

  classifier_version text not null,
  context_pack_version text not null,
  policy_version text not null,

  status text not null check (status in ('queued','processing','completed','failed','canceled')) default 'queued',
  rewrite_completed_at timestamptz,
  sender_reveal_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Basic shape guards
  constraint ck_rewrite_requests_topics_json check (jsonb_typeof(topics) = 'array'),
  constraint ck_rewrite_requests_classifier_result_obj check (jsonb_typeof(classifier_result) = 'object'),
  constraint ck_rewrite_requests_context_pack_obj check (jsonb_typeof(context_pack) = 'object'),
  constraint ck_rewrite_requests_rewrite_request_obj check (jsonb_typeof(rewrite_request) = 'object')
);

-- Enforce topics length + enum correctness via immutable helper (no subqueries in CHECK)
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname in ('ck_rewrite_requests_topics_len','ck_rewrite_requests_topics_enum')
      and conrelid = 'public.rewrite_requests'::regclass
  ) then
    begin
      alter table public.rewrite_requests drop constraint if exists ck_rewrite_requests_topics_len;
      alter table public.rewrite_requests drop constraint if exists ck_rewrite_requests_topics_enum;
    exception when undefined_object then
      null;
    end;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'ck_rewrite_requests_topics_valid'
      and conrelid = 'public.rewrite_requests'::regclass
  ) then
    alter table public.rewrite_requests
      add constraint ck_rewrite_requests_topics_valid
      check (public._complaint_topics_valid(topics));
  end if;
end $$;

-- Cleanup any legacy index name (safe)
drop index if exists public.ux_rewrite_requests_execution_unit;

create index if not exists ix_rewrite_requests_home_status
  on public.rewrite_requests(home_id, status);

create index if not exists ix_rewrite_requests_recipient_status
  on public.rewrite_requests(recipient_user_id, status);

drop trigger if exists trg_rewrite_requests_updated_at on public.rewrite_requests;
create trigger trg_rewrite_requests_updated_at
before update on public.rewrite_requests
for each row execute function public._touch_updated_at();

/* ============================================================
   2A) Snapshots must belong to a real rewrite_request (ON DELETE CASCADE)
   Add as NOT VALID then VALIDATE for safer deployments.
   ============================================================ */
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fk_recipient_snapshots_request'
      and conrelid = 'public.recipient_snapshots'::regclass
  ) then
    alter table public.recipient_snapshots
      add constraint fk_recipient_snapshots_request
      foreign key (rewrite_request_id)
      references public.rewrite_requests(rewrite_request_id)
      on delete cascade
      not valid;

    alter table public.recipient_snapshots
      validate constraint fk_recipient_snapshots_request;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'fk_recipient_preference_snapshots_request'
      and conrelid = 'public.recipient_preference_snapshots'::regclass
  ) then
    alter table public.recipient_preference_snapshots
      add constraint fk_recipient_preference_snapshots_request
      foreign key (rewrite_request_id)
      references public.rewrite_requests(rewrite_request_id)
      on delete cascade
      not valid;

    alter table public.recipient_preference_snapshots
      validate constraint fk_recipient_preference_snapshots_request;
  end if;
end $$;

/* ============================================================
   3) Rewrite outputs (final per recipient)
   ============================================================ */
create table if not exists public.rewrite_outputs (
  rewrite_request_id uuid not null
    references public.rewrite_requests(rewrite_request_id) on delete cascade,
  recipient_user_id uuid not null,

  rewritten_text text not null,
  output_language text not null,
  target_locale text not null,

  model text not null,
  provider text not null,
  prompt_version text not null,
  policy_version text not null,
  lexicon_version text not null,

  eval_result jsonb not null,
  created_at timestamptz not null default now(),

  primary key (rewrite_request_id, recipient_user_id),

  constraint ck_rewrite_outputs_lang_match
    check (public._locale_primary(output_language) = public._locale_primary(target_locale)),

  constraint ck_rewrite_outputs_eval_obj check (jsonb_typeof(eval_result) = 'object')
);

/* ============================================================
   4) Rewrite jobs (work units)
   ============================================================ */
create table if not exists public.rewrite_jobs (
  job_id uuid primary key default gen_random_uuid(),

  rewrite_request_id uuid not null
    references public.rewrite_requests(rewrite_request_id) on delete cascade,

  recipient_user_id uuid not null,

  recipient_snapshot_id uuid not null,
  recipient_preference_snapshot_id uuid not null,

  task text not null check (task = 'complaint_rewrite'),

  surface text not null check (surface in ('weekly_harmony','direct_message','other')),
  rewrite_strength text not null check (rewrite_strength in ('light_touch','full_reframe')),
  lane text not null check (lane in ('same_language','cross_language')),

  language_pair jsonb not null,
  routing_decision jsonb not null,

  status text not null check (status in ('queued','processing','batch_submitted','completed','failed','canceled')) default 'queued',

  not_before_at timestamptz,
  claimed_at timestamptz,
  claimed_by text,

  attempt_count int not null default 0,
  max_attempts int not null default 2,

  last_error text,
  last_error_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Batch linkage (OpenAI)
  provider_batch_id text,
  submitted_at timestamptz,

  constraint ck_rewrite_jobs_language_pair_obj check (jsonb_typeof(language_pair) = 'object'),
  constraint ck_rewrite_jobs_routing_decision_obj check (jsonb_typeof(routing_decision) = 'object')
);

-- Idempotency: one job per (request, recipient)
create unique index if not exists ux_rewrite_jobs_execution_unit
  on public.rewrite_jobs(rewrite_request_id, recipient_user_id);

create index if not exists ix_rewrite_jobs_status_window
  on public.rewrite_jobs(status, not_before_at, created_at);

create index if not exists ix_rewrite_jobs_provider_batch
  on public.rewrite_jobs(provider_batch_id);

-- Makes finalize cheap
create index if not exists ix_rewrite_jobs_req_status
  on public.rewrite_jobs(rewrite_request_id, status);

-- Remove legacy custom id column if present
alter table public.rewrite_jobs
  drop column if exists provider_job_custom_id;

-- Ensure snapshots referenced by job exist (add safely)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fk_jobs_snapshot'
      and conrelid = 'public.rewrite_jobs'::regclass
  ) then
    alter table public.rewrite_jobs
      add constraint fk_jobs_snapshot
      foreign key (recipient_snapshot_id)
      references public.recipient_snapshots(recipient_snapshot_id)
      not valid;

    alter table public.rewrite_jobs
      validate constraint fk_jobs_snapshot;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'fk_jobs_pref_snapshot'
      and conrelid = 'public.rewrite_jobs'::regclass
  ) then
    alter table public.rewrite_jobs
      add constraint fk_jobs_pref_snapshot
      foreign key (recipient_preference_snapshot_id)
      references public.recipient_preference_snapshots(recipient_preference_snapshot_id)
      not valid;

    alter table public.rewrite_jobs
      validate constraint fk_jobs_pref_snapshot;
  end if;
end $$;

drop trigger if exists trg_rewrite_jobs_updated_at on public.rewrite_jobs;
create trigger trg_rewrite_jobs_updated_at
before update on public.rewrite_jobs
for each row execute function public._touch_updated_at();

/* ============================================================
   5) Routing + provider registry
   ============================================================ */
create table if not exists public.complaint_rewrite_routes (
  route_id uuid primary key default gen_random_uuid(),
  surface text not null,
  lane text not null,
  rewrite_strength text not null,
  provider text not null,
  model text not null,
  prompt_version text not null default 'v1',
  policy_version text not null default 'v1',
  execution_mode text not null default 'async',
  cache_eligible boolean not null default false,
  max_retries int not null default 2,
  priority int not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ck_complaint_route_surface check (surface in ('weekly_harmony','direct_message','other')),
  constraint ck_complaint_route_lane check (lane in ('same_language','cross_language')),
  constraint ck_complaint_route_strength check (rewrite_strength in ('light_touch','full_reframe'))
);

create index if not exists ix_complaint_routes_lookup
  on public.complaint_rewrite_routes(surface, lane, rewrite_strength, active, priority);

drop trigger if exists trg_complaint_rewrite_routes_updated_at on public.complaint_rewrite_routes;
create trigger trg_complaint_rewrite_routes_updated_at
before update on public.complaint_rewrite_routes
for each row execute function public._touch_updated_at();

create table if not exists public.complaint_ai_providers (
  provider text primary key,
  adapter_kind text not null,
  base_url text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ck_complaint_ai_adapter_kind check (
    adapter_kind in (
      'openai_responses',
      'openai_compat_responses',
      'openai_compat_chat_completions',
      'gemini',
      'stub'
    )
  )
);

drop trigger if exists trg_complaint_ai_providers_updated_at on public.complaint_ai_providers;
create trigger trg_complaint_ai_providers_updated_at
before update on public.complaint_ai_providers
for each row execute function public._touch_updated_at();

-- Example seeds (idempotent)
insert into public.complaint_ai_providers (provider, adapter_kind, base_url)
values
  ('openai', 'openai_responses', 'https://api.openai.com'),
  ('gemini', 'gemini', null),
  ('qwen', 'openai_compat_chat_completions', 'https://dashscope-intl.aliyuncs.com/compatible-mode'),
  ('stub', 'stub', null)
on conflict do nothing;

/* ============================================================
   6) rewrite_provider_batches (OpenAI-only batch tracking)
   ============================================================ */
drop table if exists public.provider_batches;

create table if not exists public.rewrite_provider_batches (
  provider_batch_id text primary key, -- openai batch id like "batch_..."
  provider text not null check (provider = 'openai'),
  endpoint text not null default '/v1/responses',
  status text not null check (status in ('submitted','running','completed','failed','canceled')) default 'submitted',
  input_file_id text,
  output_file_id text,
  error_file_id text,
  job_count int not null default 0,
  last_checked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_rewrite_provider_batches_updated_at on public.rewrite_provider_batches;
create trigger trg_rewrite_provider_batches_updated_at
before update on public.rewrite_provider_batches
for each row execute function public._touch_updated_at();

-- FK: jobs -> provider batch (requested)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fk_rewrite_jobs_provider_batch'
      and conrelid = 'public.rewrite_jobs'::regclass
  ) then
    alter table public.rewrite_jobs
      add constraint fk_rewrite_jobs_provider_batch
      foreign key (provider_batch_id)
      references public.rewrite_provider_batches(provider_batch_id)
      not valid;

    alter table public.rewrite_jobs
      validate constraint fk_rewrite_jobs_provider_batch;
  end if;
end $$;

/* ============================================================
   7) RLS deny-by-default (idempotent)
   NOTE: service_role bypasses RLS; keep RPCs service_role-only as you planned.
   ============================================================ */
do $$
begin
  -- Enable RLS
  execute 'alter table public.recipient_snapshots enable row level security';
  execute 'alter table public.recipient_preference_snapshots enable row level security';
  execute 'alter table public.rewrite_requests enable row level security';
  execute 'alter table public.rewrite_outputs enable row level security';
  execute 'alter table public.rewrite_jobs enable row level security';
  execute 'alter table public.complaint_ai_providers enable row level security';
  execute 'alter table public.complaint_rewrite_routes enable row level security';
  execute 'alter table public.rewrite_provider_batches enable row level security';

  -- Revoke from PUBLIC
  execute 'revoke all on table public.recipient_snapshots from public';
  execute 'revoke all on table public.recipient_preference_snapshots from public';
  execute 'revoke all on table public.rewrite_requests from public';
  execute 'revoke all on table public.rewrite_outputs from public';
  execute 'revoke all on table public.rewrite_jobs from public';
  execute 'revoke all on table public.complaint_ai_providers from public';
  execute 'revoke all on table public.complaint_rewrite_routes from public';
  execute 'revoke all on table public.rewrite_provider_batches from public';

  -- Revoke from anon/authenticated
  execute 'revoke all on table public.recipient_snapshots from anon, authenticated';
  execute 'revoke all on table public.recipient_preference_snapshots from anon, authenticated';
  execute 'revoke all on table public.rewrite_requests from anon, authenticated';
  execute 'revoke all on table public.rewrite_outputs from anon, authenticated';
  execute 'revoke all on table public.rewrite_jobs from anon, authenticated';
  execute 'revoke all on table public.complaint_ai_providers from anon, authenticated';
  execute 'revoke all on table public.complaint_rewrite_routes from anon, authenticated';
  execute 'revoke all on table public.rewrite_provider_batches from anon, authenticated';
exception when others then
  -- In partial migration runs, ignore missing relations.
  null;
end $$;
