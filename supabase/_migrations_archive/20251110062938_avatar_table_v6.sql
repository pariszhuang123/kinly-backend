-- pg_cron: Postgres-native scheduler
-- Supabase recommends placing it under pg_catalog
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.avatars (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  storage_path text        NOT NULL,
  category     text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.avatars              IS 'Avatars: image metadata for user profile pictures.';
COMMENT ON COLUMN public.avatars.storage_path IS 'Storage bucket/path or object key.';
COMMENT ON COLUMN public.avatars.category     IS 'Logical grouping, e.g., "animal" (starter pack), "plant", etc.';
COMMENT ON COLUMN public.avatars.created_at   IS 'Creation timestamp (UTC).';

ALTER TABLE public.avatars ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE public.avatars TO authenticated;

CREATE POLICY avatars_select_authenticated
  ON public.avatars
  FOR SELECT
  USING ((select auth.uid()) IS NOT NULL);
