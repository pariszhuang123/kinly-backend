
create extension if not exists pgcrypto;

-- Drop a conflicting non-table "avatars" if present (index/view/sequence/etc.)
do $$
declare rk char; sch text;
begin
  select c.relkind, n.nspname into rk, sch
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relname = 'avatars'
  limit 1;

  if rk is not null and rk <> 'r' then
    execute format(
      'drop %s if exists %I.%I cascade',
      case rk
        when 'i' then 'index'
        when 'S' then 'sequence'
        when 'v' then 'view'
        when 'm' then 'materialized view'
        when 'f' then 'foreign table'
        when 'p' then 'table'
        else 'table'
      end,
      sch, 'avatars'
    );
  end if;
end $$;

-- If a table exists from earlier attempts, drop it so we rebuild cleanly
drop table if exists public.avatars cascade;

-- Recreate the table
create table public.avatars (
  id           uuid primary key default gen_random_uuid(),
  storage_path text        not null,
  category     text        not null,
  created_at   timestamptz not null default now()
);

-- Comments for Supabase Studio clarity
comment on table  public.avatars                is 'Avatars: image metadata for user profile pictures.';
comment on column public.avatars.id             is 'Primary key (UUID).';
comment on column public.avatars.storage_path   is 'Storage bucket/path or object key.';
comment on column public.avatars.category       is 'Logical grouping, e.g., animal (starter pack), plant, etc.';
comment on column public.avatars.created_at     is 'Creation timestamp (UTC).';

-- RLS + read access
alter table public.avatars enable row level security;
grant select on table public.avatars to authenticated;

do $$
begin
  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='avatars' and policyname='avatars_select_authenticated'
  ) then
    drop policy avatars_select_authenticated on public.avatars;
  end if;

  create policy avatars_select_authenticated
    on public.avatars for select
    using (auth.uid() is not null);
end $$;
