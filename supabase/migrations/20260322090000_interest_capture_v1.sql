-- ============================================================================
-- Interest capture v1 — leads table, RLS, RPC (Adjusted v5.1)
-- FIXES (Supabase-local + search_path=''):
-- - pgcrypto functions live in schema "extensions" in Supabase
-- - citext lives in schema "public" (per your config)
-- - cron objects live in schema "cron" (extension pg_cron), not jobname-qualified via search_path
--
-- Key changes:
-- 1) Ensure pgcrypto is installed into schema extensions (local Supabase does this)
-- 2) public._sha256_hex() uses extensions.digest(...) (NOT pgcrypto.digest)
-- 3) Keep public.citext usage everywhere because search_path=''
-- ============================================================================

-- Extensions (idempotent)
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext   with schema public;
create extension if not exists pg_cron; -- typically installs into "cron" schema in Supabase

-- ----------------------------------------------------------------------------
-- Helper: stable sha256 hex for text (64 hex chars)
-- IMPORTANT:
-- - Supabase installs pgcrypto functions into schema "extensions"
-- - search_path='' requires explicit qualification
-- ----------------------------------------------------------------------------
create or replace function public._sha256_hex(p_input text)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select encode(
    extensions.digest(
      convert_to(coalesce(p_input, ''), 'utf8'),
      'sha256'::text
    ),
    'hex'
  );
$$;

-- Do NOT grant this to anon/authenticated unless you truly want clients hashing server-side.
-- Keeping it private is safer; RPC can still call it.
revoke all on function public._sha256_hex(text) from public;

-- ----------------------------------------------------------------------------
-- Leads table
-- ----------------------------------------------------------------------------
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  email public.citext not null,
  country_code text not null,
  ui_locale text not null,
  source text not null default 'kinly_web_get',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint leads_country_code_check check (country_code ~ '^[A-Z]{2}$'),
  constraint leads_ui_locale_check check (position(' ' in ui_locale) = 0),
  constraint leads_source_check check (
    source in ('kinly_web_get', 'kinly_dating_web_get', 'kinly_rent_web_get')
  )
);

-- Ensure unique email (matches ON CONFLICT(email))
do $do$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'leads_email_key'
       and conrelid = 'public.leads'::regclass
  ) then
    alter table public.leads
      add constraint leads_email_key unique (email);
  end if;
end
$do$;

create index if not exists leads_created_at_idx
  on public.leads (created_at desc);

-- updated_at trigger (assumes public._touch_updated_at exists)
drop trigger if exists trg_leads_touch_updated_at on public.leads;
create trigger trg_leads_touch_updated_at
  before update on public.leads
  for each row execute function public._touch_updated_at();

-- ----------------------------------------------------------------------------
-- Rate limit table (NO raw ip/email stored; keys are sha256 hashes)
-- ----------------------------------------------------------------------------
create table if not exists public.leads_rate_limits (
  k text primary key,
  n integer not null default 0,
  updated_at timestamptz not null default now()
);

create index if not exists leads_rate_limits_updated_at_idx
  on public.leads_rate_limits (updated_at);

-- ----------------------------------------------------------------------------
-- RLS + privilege hardening (NO policies; deny by default)
-- ----------------------------------------------------------------------------
alter table public.leads enable row level security;
alter table public.leads_rate_limits enable row level security;

drop policy if exists "deny all access to leads" on public.leads;
drop policy if exists "deny all access to leads_rate_limits" on public.leads_rate_limits;

revoke all on table public.leads from anon, authenticated;
revoke all on table public.leads_rate_limits from anon, authenticated;

-- ----------------------------------------------------------------------------
-- Cleanup function + scheduled job (pg_cron)
-- ----------------------------------------------------------------------------
create or replace function public.leads_rate_limits_cleanup()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.leads_rate_limits
   where updated_at < now() - interval '8 days';
end;
$$;

-- Create schedule once (idempotent-ish via name check)
do $do$
begin
  if not exists (
    select 1
      from cron.job
     where jobname = 'leads_rate_limits_cleanup_daily'
  ) then
    perform cron.schedule(
      'leads_rate_limits_cleanup_daily',
      '17 3 * * *',
      $job$
        select public.leads_rate_limits_cleanup();
      $job$
    );
  end if;
end
$do$;

-- ----------------------------------------------------------------------------
-- RPC: leads_upsert_v1
-- ----------------------------------------------------------------------------
create or replace function public.leads_upsert_v1(
  p_email text,
  p_country_code text,
  p_ui_locale text,
  p_source text default 'kinly_web_get'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead_id uuid;
  v_deduped boolean := false;

  v_now timestamptz := now();

  v_email_key text;
  v_global_key text;

  v_email_lock_id bigint;
  v_global_lock_id bigint;

  v_email_window timestamptz;
  v_global_window timestamptz;

  v_email_n integer;
  v_global_n integer;

  c_email_limit_per_day constant integer := 5;
  c_global_limit_per_minute constant integer := 300;
begin
  -- Normalize inputs
  p_email := trim(coalesce(p_email, ''));
  p_country_code := upper(trim(coalesce(p_country_code, '')));
  p_ui_locale := trim(coalesce(p_ui_locale, ''));
  p_source := coalesce(nullif(trim(p_source), ''), 'kinly_web_get');

  perform public.api_assert(
    p_email <> '' and p_country_code <> '' and p_ui_locale <> '',
    'LEADS_MISSING_FIELDS',
    'email, country_code, and ui_locale are required.'
  );

  -- Email (permissive) + max length
  perform public.api_assert(length(p_email) <= 254,
    'LEADS_EMAIL_TOO_LONG',
    'Email must be 254 characters or fewer.'
  );

  perform public.api_assert(length(p_email) >= 3,
    'LEADS_EMAIL_TOO_SHORT',
    'Email must be at least 3 characters.'
  );

  perform public.api_assert(
    p_email !~ '\s'
    and position('@' in p_email) > 1
    and position('.' in split_part(p_email, '@', 2)) > 1,
    'LEADS_EMAIL_INVALID',
    'Email format is invalid.'
  );

  -- country_code strict format only (ZZ allowed)
  perform public.api_assert(p_country_code ~ '^[A-Z]{2}$',
    'LEADS_COUNTRY_CODE_INVALID',
    'country_code must be ISO alpha-2 (e.g., NZ).'
  );

  -- ui_locale: light BCP-47-ish, no spaces
  perform public.api_assert(
    length(p_ui_locale) between 2 and 35
    and p_ui_locale !~ '\s'
    and p_ui_locale ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$',
    'LEADS_UI_LOCALE_INVALID',
    'ui_locale must look like a locale tag (e.g., en-NZ).'
  );

  -- source allowlist
  perform public.api_assert(
    p_source in ('kinly_web_get', 'kinly_dating_web_get', 'kinly_rent_web_get'),
    'LEADS_SOURCE_INVALID',
    'source is not allowed.'
  );

  -- Abuse mitigation (NO IP)
  v_email_window := date_trunc('day', v_now);
  v_global_window := date_trunc('minute', v_now);

  -- Hash keys (NO PII stored)
  -- Canonicalize email with citext semantics: (p_email::public.citext)::text
  v_email_key := public._sha256_hex(
    'email:' || (p_email::public.citext)::text || ':' || v_email_window::text
  );

  v_global_key := public._sha256_hex(
    'global:' || v_global_window::text
  );

  -- 64-bit advisory lock ids derived from sha256 hex keys (first 16 hex chars)
  v_email_lock_id := ('x' || substr(v_email_key, 1, 16))::bit(64)::bigint;
  v_global_lock_id := ('x' || substr(v_global_key, 1, 16))::bit(64)::bigint;

  -- Global limiter
  perform pg_advisory_xact_lock(v_global_lock_id);
  insert into public.leads_rate_limits(k, n, updated_at)
  values (v_global_key, 1, v_now)
  on conflict (k) do update
     set n = public.leads_rate_limits.n + 1,
         updated_at = v_now
  returning n into v_global_n;

  perform public.api_assert(v_global_n <= c_global_limit_per_minute,
    'LEADS_RATE_LIMIT_GLOBAL',
    'Too many requests. Please try again later.'
  );

  -- Email limiter
  perform pg_advisory_xact_lock(v_email_lock_id);
  insert into public.leads_rate_limits(k, n, updated_at)
  values (v_email_key, 1, v_now)
  on conflict (k) do update
     set n = public.leads_rate_limits.n + 1,
         updated_at = v_now
  returning n into v_email_n;

  perform public.api_assert(v_email_n <= c_email_limit_per_day,
    'LEADS_RATE_LIMIT_EMAIL',
    'Too many requests for this email today.'
  );

  -- UPSERT (deduped is precise via xmax)
  insert into public.leads (email, country_code, ui_locale, source)
  values (p_email::public.citext, p_country_code, p_ui_locale, p_source)
  on conflict (email) do update
    set country_code = excluded.country_code,
        ui_locale     = excluded.ui_locale,
        source        = excluded.source
  returning id, (xmax <> 0) as deduped
    into v_lead_id, v_deduped;

  return jsonb_build_object(
    'ok', true,
    'lead_id', v_lead_id,
    'deduped', v_deduped
  );
end;
$$;

-- Lock down function privileges, allow RPC execution only
revoke all on function public.leads_upsert_v1(text, text, text, text) from public;
grant execute on function public.leads_upsert_v1(text, text, text, text) to anon, authenticated;
