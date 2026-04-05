-- withYou v1: source-scoped leads deduping + durable pack download tracking

-- ----------------------------------------------------------------------------
-- Leads: allow withYou web source and dedupe by (email, source)
-- ----------------------------------------------------------------------------
alter table public.leads
  drop constraint if exists leads_email_key;

alter table public.leads
  drop constraint if exists leads_source_check;

alter table public.leads
  add constraint leads_source_check check (
    source in (
      'kinly_web_get',
      'kinly_dating_web_get',
      'kinly_rent_web_get',
      'withyou_web_get'
    )
  );

do $do$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'leads_email_source_key'
       and conrelid = 'public.leads'::regclass
  ) then
    alter table public.leads
      add constraint leads_email_source_key unique (email, source);
  end if;
end
$do$;

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
  p_email := trim(coalesce(p_email, ''));
  p_country_code := upper(trim(coalesce(p_country_code, '')));
  p_ui_locale := trim(coalesce(p_ui_locale, ''));
  p_source := coalesce(nullif(trim(p_source), ''), 'kinly_web_get');

  perform public.api_assert(
    p_email <> '' and p_country_code <> '' and p_ui_locale <> '',
    'LEADS_MISSING_FIELDS',
    'email, country_code, and ui_locale are required.'
  );

  perform public.api_assert(
    length(p_email) <= 254,
    'LEADS_EMAIL_TOO_LONG',
    'Email must be 254 characters or fewer.'
  );

  perform public.api_assert(
    length(p_email) >= 3,
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

  perform public.api_assert(
    p_country_code ~ '^[A-Z]{2}$',
    'LEADS_COUNTRY_CODE_INVALID',
    'country_code must be ISO alpha-2 (e.g., NZ).'
  );

  perform public.api_assert(
    length(p_ui_locale) between 2 and 35
    and p_ui_locale !~ '\s'
    and p_ui_locale ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$',
    'LEADS_UI_LOCALE_INVALID',
    'ui_locale must look like a locale tag (e.g., en-NZ).'
  );

  perform public.api_assert(
    p_source in (
      'kinly_web_get',
      'kinly_dating_web_get',
      'kinly_rent_web_get',
      'withyou_web_get'
    ),
    'LEADS_SOURCE_INVALID',
    'source is not allowed.'
  );

  v_email_window := date_trunc('day', v_now);
  v_global_window := date_trunc('minute', v_now);

  v_email_key := public._sha256_hex(
    'email:' || (p_email::public.citext)::text || ':' || v_email_window::text
  );

  v_global_key := public._sha256_hex(
    'global:' || v_global_window::text
  );

  v_email_lock_id := ('x' || substr(v_email_key, 1, 16))::bit(64)::bigint;
  v_global_lock_id := ('x' || substr(v_global_key, 1, 16))::bit(64)::bigint;

  perform pg_advisory_xact_lock(v_global_lock_id);
  insert into public.leads_rate_limits(k, n, updated_at)
  values (v_global_key, 1, v_now)
  on conflict (k) do update
     set n = public.leads_rate_limits.n + 1,
         updated_at = v_now
  returning n into v_global_n;

  perform public.api_assert(
    v_global_n <= c_global_limit_per_minute,
    'LEADS_RATE_LIMIT_GLOBAL',
    'Too many requests. Please try again later.'
  );

  perform pg_advisory_xact_lock(v_email_lock_id);
  insert into public.leads_rate_limits(k, n, updated_at)
  values (v_email_key, 1, v_now)
  on conflict (k) do update
     set n = public.leads_rate_limits.n + 1,
         updated_at = v_now
  returning n into v_email_n;

  perform public.api_assert(
    v_email_n <= c_email_limit_per_day,
    'LEADS_RATE_LIMIT_EMAIL',
    'Too many requests for this email today.'
  );

  insert into public.leads (email, country_code, ui_locale, source)
  values (p_email::public.citext, p_country_code, p_ui_locale, p_source)
  on conflict (email, source) do update
    set country_code = excluded.country_code,
        ui_locale = excluded.ui_locale,
        source = excluded.source
  returning id, (xmax <> 0) as deduped
    into v_lead_id, v_deduped;

  return jsonb_build_object(
    'ok', true,
    'lead_id', v_lead_id,
    'deduped', v_deduped
  );
end;
$$;

revoke all on function public.leads_upsert_v1(text, text, text, text) from public;
grant execute on function public.leads_upsert_v1(text, text, text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- withYou app pack download tracking
-- ----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- withYou app pack download tracking
-- -----------------------------------------------------------------------------

create table if not exists public.withyou_pack_downloads (
  id uuid primary key default gen_random_uuid(),
  language text not null,
  pack_version text,
  platform text,
  app_version text,
  requested_at timestamptz not null default now(),
  request_path text,
  user_agent text,
  country_code text,

  constraint withyou_pack_downloads_language_check check (
    language ~ '^[a-z]{2,3}$'
  ),
  constraint withyou_pack_downloads_platform_check check (
    platform is null or platform in ('ios', 'android')
  ),
  constraint withyou_pack_downloads_country_code_check check (
    country_code is null or country_code ~ '^[A-Z]{2}$'
  ),
  constraint withyou_pack_downloads_pack_version_len_check check (
    pack_version is null or char_length(pack_version) <= 50
  ),
  constraint withyou_pack_downloads_app_version_len_check check (
    app_version is null or char_length(app_version) <= 50
  ),
  constraint withyou_pack_downloads_request_path_check check (
    request_path is null or (
      char_length(request_path) <= 500
      and request_path like '/%'
    )
  ),
  constraint withyou_pack_downloads_user_agent_len_check check (
    user_agent is null or char_length(user_agent) <= 1000
  )
);

create index if not exists withyou_pack_downloads_requested_at_idx
  on public.withyou_pack_downloads (requested_at desc);

create index if not exists withyou_pack_downloads_language_requested_at_idx
  on public.withyou_pack_downloads (language, requested_at desc);

create index if not exists withyou_pack_downloads_platform_requested_at_idx
  on public.withyou_pack_downloads (platform, requested_at desc);

create index if not exists withyou_pack_downloads_app_version_requested_at_idx
  on public.withyou_pack_downloads (app_version, requested_at desc);

alter table public.withyou_pack_downloads enable row level security;

revoke all on table public.withyou_pack_downloads from public, anon, authenticated;

comment on table public.withyou_pack_downloads is
  'Append-only telemetry for withYou app pack download requests. Writes must go through public.withyou_log_pack_download_v1.';

create or replace function public.withyou_log_pack_download_v1(
  p_language text,
  p_pack_version text default null,
  p_platform text default null,
  p_app_version text default null,
  p_request_path text default null,
  p_user_agent text default null,
  p_country_code text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_language text := lower(trim(coalesce(p_language, '')));
  v_pack_version text := nullif(trim(coalesce(p_pack_version, '')), '');
  v_platform text := nullif(lower(trim(coalesce(p_platform, ''))), '');
  v_app_version text := nullif(trim(coalesce(p_app_version, '')), '');
  v_request_path text := nullif(trim(coalesce(p_request_path, '')), '');
  v_user_agent text := nullif(trim(coalesce(p_user_agent, '')), '');
  v_country_code text := nullif(upper(trim(coalesce(p_country_code, ''))), '');
begin
  perform public.api_assert(
    v_language <> '' and v_language ~ '^[a-z]{2,3}$',
    'WITHYOU_LANGUAGE_INVALID',
    'language must be a 2-3 letter ISO 639 code.'
  );

  perform public.api_assert(
    v_platform is null or v_platform in ('ios', 'android'),
    'WITHYOU_PLATFORM_INVALID',
    'platform must be ios or android when provided.'
  );

  perform public.api_assert(
    v_country_code is null or v_country_code ~ '^[A-Z]{2}$',
    'WITHYOU_COUNTRY_CODE_INVALID',
    'country_code must be a 2-letter ISO country code when provided.'
  );

  perform public.api_assert(
    v_pack_version is null or char_length(v_pack_version) <= 50,
    'WITHYOU_PACK_VERSION_TOO_LONG',
    'pack_version must be 50 characters or fewer.'
  );

  perform public.api_assert(
    v_app_version is null or char_length(v_app_version) <= 50,
    'WITHYOU_APP_VERSION_TOO_LONG',
    'app_version must be 50 characters or fewer.'
  );

  perform public.api_assert(
    v_request_path is null or (
      char_length(v_request_path) <= 500
      and v_request_path like '/%'
    ),
    'WITHYOU_REQUEST_PATH_INVALID',
    'request_path must start with / and be 500 characters or fewer.'
  );

  perform public.api_assert(
    v_user_agent is null or char_length(v_user_agent) <= 1000,
    'WITHYOU_USER_AGENT_TOO_LONG',
    'user_agent must be 1000 characters or fewer.'
  );

  insert into public.withyou_pack_downloads (
    language,
    pack_version,
    platform,
    app_version,
    request_path,
    user_agent,
    country_code
  )
  values (
    v_language,
    v_pack_version,
    v_platform,
    v_app_version,
    v_request_path,
    v_user_agent,
    v_country_code
  );

  return jsonb_build_object(
    'ok', true
  );
end;
$$;

revoke all on function public.withyou_log_pack_download_v1(text, text, text, text, text, text, text)
  from public;

grant execute on function public.withyou_log_pack_download_v1(text, text, text, text, text, text, text)
  to anon, authenticated;