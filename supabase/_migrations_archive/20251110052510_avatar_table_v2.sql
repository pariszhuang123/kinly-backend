BEGIN;

--------------------------------------------------------------------------------
-- 1) Avatars table
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.avatars (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  storage_path text        NOT NULL,
  category     text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.avatars                  IS 'Avatars: image metadata for user profile pictures.';
COMMENT ON COLUMN public.avatars.storage_path     IS 'Storage bucket/path or object key.';
COMMENT ON COLUMN public.avatars.category         IS 'Logical grouping: e.g., animal (starter pack), plants, etc.';
COMMENT ON COLUMN public.avatars.created_at       IS 'Created at (UTC).';

ALTER TABLE public.avatars ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON TABLE public.avatars TO authenticated;

-- Minimal read policy: any authenticated user can view avatars
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='avatars' AND policyname='avatars_select_authenticated'
  ) THEN
    CREATE POLICY avatars_select_authenticated
      ON public.avatars
      FOR SELECT
      USING (auth.uid() IS NOT NULL);
  END IF;
END
$$;

