-- enable_pgcrypto_and_pgcron.sql
-- Purpose: Enable pgcrypto (UUIDs, crypto) and pg_cron (scheduler)

BEGIN;

-- pgcrypto: gives gen_random_uuid(), digest(), crypt(), etc.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- pg_cron: Postgres-native scheduler
-- Supabase recommends placing it under pg_catalog
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- No extra GRANTs:
-- We keep scheduling power with admin-only roles (postgres/service_role).
-- DO NOT grant cron privileges to authenticated/anon.

COMMIT;
