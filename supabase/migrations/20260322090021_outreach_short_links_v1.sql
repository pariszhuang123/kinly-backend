-- =====================================================================
-- Outreach short links v1.0.1 (service-role managed)
-- - Canonical short-code mapping for outreach campaigns.
-- - Idempotent via destination_fingerprint.
-- - Secure short code generation via gen_random_bytes().
-- - Seeds permanent 'unknown' outreach source to satisfy FK.
-- - Adds expiry index + effective-active view.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Extensions
-- ---------------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema public;

-- ---------------------------------------------------------------------
-- 0.1) Seed permanent 'unknown' source row (FK safety)
-- ---------------------------------------------------------------------
insert into public.outreach_sources (source_id, label, active)
values ('unknown', 'Unknown Source', true)
on conflict (source_id) do nothing;

-- ---------------------------------------------------------------------
-- 1) Table
-- ---------------------------------------------------------------------
create table if not exists public.outreach_short_links (
  id                      uuid primary key default gen_random_uuid(),
  short_code              public.citext not null,
  target_path             text not null,
  target_query            jsonb not null default '{}'::jsonb,
  utm_campaign            text not null,
  utm_source              text not null,
  utm_medium              text not null,
  source_id_resolved      text not null default 'unknown',
  app_key                 text not null default 'kinly-web',
  page_key                text not null,
  destination_fingerprint text not null,
  active                  boolean not null default true,
  expires_at              timestamptz,
  created_by              uuid,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint chk_outreach_short_links_short_code
    check (lower(short_code::text) ~ '^[a-z0-9_-]{4,24}$'),
  constraint chk_outreach_short_links_target_path
    check (target_path like '/kinly/%'),
  constraint chk_outreach_short_links_target_query_object
    check (jsonb_typeof(target_query) = 'object'),
  constraint chk_outreach_short_links_utm_campaign
    check (nullif(trim(utm_campaign), '') is not null),
  constraint chk_outreach_short_links_utm_source
    check (nullif(trim(utm_source), '') is not null),
  constraint chk_outreach_short_links_utm_medium
    check (nullif(trim(utm_medium), '') is not null),
  constraint chk_outreach_short_links_app_key
    check (nullif(trim(app_key), '') is not null),
  constraint chk_outreach_short_links_page_key
    check (nullif(trim(page_key), '') is not null),
  constraint fk_outreach_short_links_source_resolved
    foreign key (source_id_resolved) references public.outreach_sources(source_id)
);

create unique index if not exists uq_outreach_short_links_short_code
  on public.outreach_short_links (short_code);

create unique index if not exists uq_outreach_short_links_destination_fingerprint
  on public.outreach_short_links (destination_fingerprint);

create index if not exists idx_outreach_short_links_active_created_at
  on public.outreach_short_links (active, created_at desc);

create index if not exists idx_outreach_short_links_utm_triplet
  on public.outreach_short_links (utm_campaign, utm_source, utm_medium);

create index if not exists idx_outreach_short_links_expires_at
  on public.outreach_short_links (expires_at)
  where expires_at is not null;

comment on table public.outreach_short_links is 'Service-managed short links for outreach URLs.';
comment on column public.outreach_short_links.short_code is 'Case-insensitive short code (normalized to lowercase on write).';
comment on column public.outreach_short_links.target_path is 'Host-agnostic target path (must be /kinly/...).';
comment on column public.outreach_short_links.target_query is 'Canonical query object merged into redirect destination.';
comment on column public.outreach_short_links.destination_fingerprint is 'sha256 of canonical destination tuple.';
comment on column public.outreach_short_links.expires_at is 'Optional expiry; immutable for an existing destination_fingerprint.';

-- ---------------------------------------------------------------------
-- 2) Fingerprint helper
-- ---------------------------------------------------------------------
create or replace function public._outreach_short_links_fingerprint(
  p_target_path text,
  p_target_query jsonb,
  p_utm_campaign text,
  p_utm_source text,
  p_utm_medium text,
  p_app_key text,
  p_page_key text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select encode(
    extensions.digest(
      convert_to(
        concat_ws(
          '|',
          trim(coalesce(p_target_path, '')),
          coalesce(p_target_query, '{}'::jsonb)::text,
          trim(coalesce(p_utm_campaign, '')),
          lower(trim(coalesce(p_utm_source, ''))),
          lower(trim(coalesce(p_utm_medium, ''))),
          trim(coalesce(p_app_key, '')),
          trim(coalesce(p_page_key, ''))
        ),
        'utf8'
      ),
      'sha256'::text
    ),
    'hex'
  );
$$;

revoke all on function public._outreach_short_links_fingerprint(
  text, jsonb, text, text, text, text, text
) from public;

-- ---------------------------------------------------------------------
-- 3) Secure short-code generator (gen_random_bytes)
-- ---------------------------------------------------------------------
create or replace function public._outreach_short_links_generate_code(
  p_len integer default 6
)
returns public.citext
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  -- Excludes ambiguous characters: 0, 1, i, l, o
  v_alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  v_alpha_len constant integer := length(v_alphabet);

  v_bytes bytea;
  v_code text := '';
  v_i integer;
  v_byte integer;
begin
  if p_len < 4 or p_len > 24 then
    raise exception 'invalid code length'
      using errcode = '22023';
  end if;

  -- cryptographically strong randomness
  v_bytes := extensions.gen_random_bytes(p_len);

  for v_i in 0 .. p_len - 1 loop
    v_byte := get_byte(v_bytes, v_i);
    v_code := v_code || substr(v_alphabet, (v_byte % v_alpha_len) + 1, 1);
  end loop;

  return v_code::public.citext;
end;
$$;

revoke all on function public._outreach_short_links_generate_code(integer) from public;

-- ---------------------------------------------------------------------
-- 4) Source resolver
-- ---------------------------------------------------------------------
create or replace function public._outreach_short_links_resolve_source(
  p_utm_source text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_utm_source text := lower(trim(coalesce(p_utm_source, '')));
  v_resolved text;
begin
  select s.source_id
    into v_resolved
    from public.outreach_sources s
   where s.source_id = v_utm_source
     and s.active = true
   limit 1;

  if v_resolved is null then
    select s.source_id
      into v_resolved
      from public.outreach_source_aliases a
      join public.outreach_sources s on s.source_id = a.source_id
     where a.alias = v_utm_source
       and a.active = true
       and s.active = true
     limit 1;
  end if;

  return coalesce(v_resolved, 'unknown');
end;
$$;

revoke all on function public._outreach_short_links_resolve_source(text) from public;

-- ---------------------------------------------------------------------
-- 5) Normalization trigger
-- ---------------------------------------------------------------------
create or replace function public._outreach_short_links_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.short_code := lower(trim(new.short_code::text))::public.citext;
  new.target_path := trim(new.target_path);
  new.target_query := coalesce(new.target_query, '{}'::jsonb);
  new.utm_campaign := trim(new.utm_campaign);
  new.utm_source := lower(trim(new.utm_source));
  new.utm_medium := lower(trim(new.utm_medium));
  new.app_key := trim(new.app_key);
  new.page_key := trim(new.page_key);

  new.source_id_resolved := coalesce(
    nullif(trim(new.source_id_resolved), ''),
    public._outreach_short_links_resolve_source(new.utm_source)
  );

  new.destination_fingerprint := public._outreach_short_links_fingerprint(
    new.target_path,
    new.target_query,
    new.utm_campaign,
    new.utm_source,
    new.utm_medium,
    new.app_key,
    new.page_key
  );

  new.updated_at := now();

  if new.created_by is null then
    new.created_by := auth.uid();
  end if;

  return new;
end;
$$;

revoke all on function public._outreach_short_links_before_write() from public;

drop trigger if exists trg_outreach_short_links_before_write on public.outreach_short_links;

create trigger trg_outreach_short_links_before_write
before insert or update on public.outreach_short_links
for each row
execute function public._outreach_short_links_before_write();

-- ---------------------------------------------------------------------
-- 6) Get-or-create RPC (service role)
-- ---------------------------------------------------------------------
create or replace function public.outreach_short_links_get_or_create(
  p_short_code text default null,
  p_target_path text default null,
  p_target_query jsonb default '{}'::jsonb,
  p_utm_campaign text default null,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_app_key text default 'kinly-web',
  p_page_key text default null,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_short_code text := nullif(lower(trim(coalesce(p_short_code, ''))), '');
  v_target_path text := trim(coalesce(p_target_path, ''));
  v_target_query jsonb := coalesce(p_target_query, '{}'::jsonb);
  v_utm_campaign text := trim(coalesce(p_utm_campaign, ''));
  v_utm_source text := lower(trim(coalesce(p_utm_source, '')));
  v_utm_medium text := lower(trim(coalesce(p_utm_medium, '')));
  v_app_key text := trim(coalesce(p_app_key, ''));
  v_page_key text := trim(coalesce(p_page_key, ''));
  v_source_id_resolved text;
  v_fingerprint text;
  v_row public.outreach_short_links%rowtype;
  v_attempt integer := 0;
  c_max_attempts constant integer := 8;
begin
  perform public.api_assert(
    v_target_path like '/kinly/%',
    'INVALID_TARGET_PATH',
    'target_path must start with /kinly/',
    '22023'
  );

  perform public.api_assert(
    jsonb_typeof(v_target_query) = 'object',
    'INVALID_TARGET_QUERY',
    'target_query must be a JSON object',
    '22023'
  );

  perform public.api_assert(
    v_utm_campaign <> '' and v_utm_source <> '' and v_utm_medium <> '',
    'INVALID_UTM',
    'utm_campaign, utm_source, and utm_medium are required',
    '22023'
  );

  perform public.api_assert(
    v_app_key <> '' and v_page_key <> '',
    'INVALID_INPUT',
    'app_key and page_key are required',
    '22023'
  );

  if v_short_code is not null then
    perform public.api_assert(
      v_short_code ~ '^[a-z0-9_-]{4,24}$',
      'INVALID_SHORT_CODE',
      'short_code must match ^[a-z0-9_-]{4,24}$',
      '22023'
    );
  end if;

  v_source_id_resolved := public._outreach_short_links_resolve_source(v_utm_source);
  v_fingerprint := public._outreach_short_links_fingerprint(
    v_target_path,
    v_target_query,
    v_utm_campaign,
    v_utm_source,
    v_utm_medium,
    v_app_key,
    v_page_key
  );

  select *
    into v_row
    from public.outreach_short_links
   where destination_fingerprint = v_fingerprint
   limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'created', false,
      'id', v_row.id,
      'short_code', v_row.short_code::text,
      'short_url', 'https://go.makinglifeeasie.com/' || v_row.short_code::text,
      'destination_fingerprint', v_row.destination_fingerprint
    );
  end if;

  if v_short_code is not null then
    begin
      insert into public.outreach_short_links (
        short_code,
        target_path,
        target_query,
        utm_campaign,
        utm_source,
        utm_medium,
        source_id_resolved,
        app_key,
        page_key,
        destination_fingerprint,
        expires_at
      ) values (
        v_short_code::public.citext,
        v_target_path,
        v_target_query,
        v_utm_campaign,
        v_utm_source,
        v_utm_medium,
        v_source_id_resolved,
        v_app_key,
        v_page_key,
        v_fingerprint,
        p_expires_at
      )
      returning * into v_row;

      return jsonb_build_object(
        'ok', true,
        'created', true,
        'id', v_row.id,
        'short_code', v_row.short_code::text,
        'short_url', 'https://go.makinglifeeasie.com/' || v_row.short_code::text,
        'destination_fingerprint', v_row.destination_fingerprint
      );
    exception
      when unique_violation then
        select *
          into v_row
          from public.outreach_short_links
         where destination_fingerprint = v_fingerprint
         limit 1;

        if found then
          return jsonb_build_object(
            'ok', true,
            'created', false,
            'id', v_row.id,
            'short_code', v_row.short_code::text,
            'short_url', 'https://go.makinglifeeasie.com/' || v_row.short_code::text,
            'destination_fingerprint', v_row.destination_fingerprint
          );
        end if;

        perform public.api_error(
          'SHORT_CODE_ALREADY_EXISTS',
          'Requested short_code is already bound to a different destination',
          '23505'
        );
    end;
  end if;

  while v_attempt < c_max_attempts loop
    v_attempt := v_attempt + 1;
    v_short_code := public._outreach_short_links_generate_code(6)::text;

    begin
      insert into public.outreach_short_links (
        short_code,
        target_path,
        target_query,
        utm_campaign,
        utm_source,
        utm_medium,
        source_id_resolved,
        app_key,
        page_key,
        destination_fingerprint,
        expires_at
      ) values (
        v_short_code::public.citext,
        v_target_path,
        v_target_query,
        v_utm_campaign,
        v_utm_source,
        v_utm_medium,
        v_source_id_resolved,
        v_app_key,
        v_page_key,
        v_fingerprint,
        p_expires_at
      )
      returning * into v_row;

      return jsonb_build_object(
        'ok', true,
        'created', true,
        'id', v_row.id,
        'short_code', v_row.short_code::text,
        'short_url', 'https://go.makinglifeeasie.com/' || v_row.short_code::text,
        'destination_fingerprint', v_row.destination_fingerprint
      );
    exception
      when unique_violation then
        select *
          into v_row
          from public.outreach_short_links
         where destination_fingerprint = v_fingerprint
         limit 1;

        if found then
          return jsonb_build_object(
            'ok', true,
            'created', false,
            'id', v_row.id,
            'short_code', v_row.short_code::text,
            'short_url', 'https://go.makinglifeeasie.com/' || v_row.short_code::text,
            'destination_fingerprint', v_row.destination_fingerprint
          );
        end if;
    end;
  end loop;

  perform public.api_error(
    'SHORT_CODE_COLLISION_EXHAUSTED',
    'Could not allocate a unique short code after bounded retries',
    '23505'
  );

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 7) Disable RPC (service role)
-- ---------------------------------------------------------------------
create or replace function public.outreach_short_links_disable(
  p_short_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_short_code text := lower(trim(coalesce(p_short_code, '')));
  v_row public.outreach_short_links%rowtype;
begin
  perform public.api_assert(
    v_short_code ~ '^[a-z0-9_-]{4,24}$',
    'INVALID_SHORT_CODE',
    'short_code must match ^[a-z0-9_-]{4,24}$',
    '22023'
  );

  update public.outreach_short_links
     set active = false,
         updated_at = now()
   where short_code = v_short_code::public.citext
     and active = true
  returning * into v_row;

  if found then
    return jsonb_build_object(
      'ok', true,
      'disabled', true,
      'id', v_row.id,
      'short_code', v_row.short_code::text
    );
  end if;

  select *
    into v_row
    from public.outreach_short_links
   where short_code = v_short_code::public.citext
   limit 1;

  if not found then
    perform public.api_error(
      'SHORT_CODE_NOT_FOUND',
      'short_code was not found',
      'P0002'
    );

    return null;
  end if;

  return jsonb_build_object(
    'ok', true,
    'disabled', false,
    'id', v_row.id,
    'short_code', v_row.short_code::text
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Effective-active view (for redirect layer / ops convenience)
-- ---------------------------------------------------------------------
create or replace view public.outreach_short_links_effective as
select *,
       (active and (expires_at is null or expires_at > now())) as effective_active
from public.outreach_short_links;

-- ---------------------------------------------------------------------
-- 9) RLS + Grants (service-role only)
-- ---------------------------------------------------------------------
alter table public.outreach_short_links enable row level security;

revoke all on table public.outreach_short_links from public;
revoke all on table public.outreach_short_links from anon;
revoke all on table public.outreach_short_links from authenticated;

grant select, insert, update, delete on table public.outreach_short_links to service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'outreach_short_links'
      and policyname = 'service_role_all_outreach_short_links'
  ) then
    execute $p$
      create policy "service_role_all_outreach_short_links"
      on public.outreach_short_links
      for all
      to service_role
      using (true)
      with check (true)
    $p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10) Function execute permissions
-- ---------------------------------------------------------------------
revoke all on function public.outreach_short_links_get_or_create(
  text, text, jsonb, text, text, text, text, text, timestamptz
) from public;

revoke all on function public.outreach_short_links_disable(text) from public;

grant execute on function public.outreach_short_links_get_or_create(
  text, text, jsonb, text, text, text, text, text, timestamptz
) to service_role;

grant execute on function public.outreach_short_links_disable(text) to service_role;

CREATE OR REPLACE FUNCTION public.paywall_status_get(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan text;
  v_now  timestamptz := now();
BEGIN
  PERFORM public._assert_home_member(p_home_id);

  SELECT COALESCE(he.plan, 'free')
    INTO v_plan
    FROM public.home_entitlements he
   WHERE he.home_id = p_home_id;

  RETURN jsonb_build_object(
    'plan', v_plan,
    'is_premium', (v_plan <> 'free'),
    'has_ai',     (v_plan = 'premium_ai'),
    'usage', COALESCE((
      SELECT jsonb_build_object(
        'active_chores',   c.active_chores,
        'chore_photos',    c.chore_photos,
        'active_members',  c.active_members,
        'active_expenses', c.active_expenses,
        'expense_photos',  c.expense_photos,   -- added
        'updated_at',      c.updated_at
      )
      FROM public.home_usage_counters c
      WHERE c.home_id = p_home_id
    ), jsonb_build_object(
      'active_chores', 0,
      'chore_photos', 0,
      'active_members', 0,
      'active_expenses', 0,
      'expense_photos', 0,                      -- added
      'updated_at', v_now
    )),
    'limits', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'metric',    x.metric::text,
          'max_value', x.max_value
        )
        ORDER BY x.metric::text
      )
      FROM (
        SELECT l.metric, l.max_value
        FROM public.home_plan_limits l
        WHERE l.plan = v_plan
      ) x
    ), '[]'::jsonb)
  );
END;
$$;

DROP TABLE IF EXISTS public.shared_preferences;
