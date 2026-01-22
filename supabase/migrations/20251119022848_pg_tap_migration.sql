-- 1. Create a dedicated schema for pgTAP objects
create schema if not exists pgtap;

-- 2. If pgtap already exists (maybe in public), move it; otherwise create it in pgtap
do $$
begin
  if exists (
    select 1
    from pg_extension
    where extname = 'pgtap'
  ) then
    -- Extension already installed somewhere (likely public) → just move it.
    alter extension pgtap set schema pgtap;
  else
    -- Fresh DB / no pgtap yet → install directly into pgtap schema.
    create extension if not exists pgtap with schema pgtap;
  end if;
end;
$$;
