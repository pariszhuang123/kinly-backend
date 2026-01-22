-- 1️⃣ Allow NULLs in email
ALTER TABLE public.profiles
  ALTER COLUMN email DROP NOT NULL;

COMMENT ON COLUMN public.profiles.email IS
  'Optional user email address mirrored from auth.users.email. May be NULL for privacy or deleted accounts. Remains UNIQUE when present.';

CREATE TABLE IF NOT EXISTS public.app_version (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_number         text NOT NULL,                -- e.g. "1.2.0"
  min_supported_version  text NOT NULL,                -- e.g. "1.0.0"
  is_current             boolean NOT NULL DEFAULT false,
  release_date           timestamptz NOT NULL DEFAULT now(),
  notes                  text,

  CONSTRAINT uq_app_version UNIQUE (version_number),
  CONSTRAINT chk_version_number CHECK (version_number ~ '^\d+\.\d+\.\d+$'),
  CONSTRAINT chk_min_supported CHECK (min_supported_version ~ '^\d+\.\d+\.\d+$')
);

-- Only one current version allowed
CREATE UNIQUE INDEX IF NOT EXISTS uq_app_version_is_current_true
  ON public.app_version ((true)) WHERE is_current;

COMMENT ON TABLE public.app_version IS
  'Manually maintained table of app versions. The app checks this table at startup to know if the client is outdated.';
COMMENT ON COLUMN public.app_version.min_supported_version IS
  'Minimum version allowed to run. Clients below this version will be blocked.';

ALTER TABLE public.app_version ENABLE ROW LEVEL SECURITY;

-- No direct reads/writes from clients
REVOKE ALL ON public.app_version FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.check_app_version(client_version text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''          -- keep this; you fully qualify objects
STABLE
RETURNS NULL ON NULL INPUT
AS $$
DECLARE
  v_in text := btrim(client_version);
  cv_major int;
  cv_minor int;
  cv_patch int;

  v record;
  hard_block boolean;
BEGIN
  IF v_in !~ '^\d+\.\d+\.\d+$' THEN
    RAISE EXCEPTION 'client_version must be "x.y.z" (digits only)'
      USING ERRCODE = '22023';
  END IF;

  -- safe to parse now
  cv_major := split_part(v_in, '.', 1)::int;
  cv_minor := split_part(v_in, '.', 2)::int;
  cv_patch := split_part(v_in, '.', 3)::int;

  SELECT version_number, min_supported_version, release_date, notes
    INTO v
    FROM public.app_version
   WHERE is_current IS TRUE
   LIMIT 1;

  IF v IS NULL THEN
    RETURN jsonb_build_object(
      'hardBlocked', false,
      'updateRecommended', false,
      'message', 'No server version configured'
    );
  END IF;

  hard_block :=
    (cv_major, cv_minor, cv_patch) <
    (split_part(v.min_supported_version,'.',1)::int,
     split_part(v.min_supported_version,'.',2)::int,
     split_part(v.min_supported_version,'.',3)::int);

  RETURN jsonb_build_object(
    'clientVersion',       v_in,
    'currentVersion',      v.version_number,
    'minSupportedVersion', v.min_supported_version,
    'hardBlocked',         hard_block,
    'updateRecommended',   (NOT hard_block) AND (
      (cv_major, cv_minor, cv_patch) <
      (split_part(v.version_number,'.',1)::int,
       split_part(v.version_number,'.',2)::int,
       split_part(v.version_number,'.',3)::int)
    ),
    'notes',               v.notes,
    'releasedAt',          v.release_date
  );
END;
$$;
