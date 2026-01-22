-- Allow storing object paths (no bucket/URL) for chore photos and support multiple flow segments.

-- Drop old bucket-prefixed constraint
ALTER TABLE public.chores
  DROP CONSTRAINT IF EXISTS chk_chore_expectation_path;

ALTER TABLE public.chores
  ADD CONSTRAINT chk_chore_expectation_path
  CHECK (
    expectation_photo_path IS NULL
    OR (
      expectation_photo_path !~ '^[A-Za-z][A-Za-z0-9+.-]*://' -- reject http(s)/gs/etc
      AND expectation_photo_path ~ '^flow/[a-z0-9_-]+/[A-Za-z0-9_./-]+$'
    )
  );

COMMENT ON COLUMN public.chores.expectation_photo_path
  IS 'Supabase Storage object path (no bucket/host) for chore photos.';
