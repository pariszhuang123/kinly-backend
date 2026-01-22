CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;

-- 1️⃣ Add the username column
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS username CITEXT NOT NULL,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

COMMENT ON COLUMN public.profiles.username IS
  'Case-insensitive unique handle for user identification and @mentions. '
  'Must be 3–30 chars long, start/end with a letter or number, and may contain dots or underscores in between. '
  'Used for tagging (e.g., @username) and public display names.';
COMMENT ON COLUMN public.profiles.updated_at     IS 'Profile updated timestamp (UTC).';


-- 2️⃣ Add a unique index for case-insensitive uniqueness
CREATE UNIQUE INDEX IF NOT EXISTS uq_profiles_username
  ON public.profiles (username);

COMMENT ON INDEX uq_profiles_username IS
  'Ensures each username is globally unique (case-insensitive).';

-- 3️⃣ Add a format validation constraint (if not already present)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_profiles_username_format'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT chk_profiles_username_format
      CHECK (
        username ~ '^[a-z0-9](?:[a-z0-9._]{1,28})[a-z0-9]$'
      );
  END IF;
END$$;

COMMENT ON CONSTRAINT chk_profiles_username_format ON public.profiles IS
  'Enforces username format: 3–30 chars, lowercase letters, digits, dots, or underscores. '
  'Must start and end with a letter or number.';

-- Table + comments
CREATE TABLE IF NOT EXISTS public.reserved_usernames (
  name CITEXT PRIMARY KEY
);

COMMENT ON TABLE  public.reserved_usernames IS
  'Case-insensitive blocklist of usernames that users are not allowed to claim (e.g., admin, support).';

COMMENT ON COLUMN public.reserved_usernames.name IS
  'Reserved handle (CITEXT). Comparisons and PK uniqueness are case-insensitive.';

-- Seed a few; ignore if already present
INSERT INTO public.reserved_usernames (name)
VALUES ('admin'), ('system'), ('support'), ('kinly')
ON CONFLICT DO NOTHING;

-- Lock it down with RLS
ALTER TABLE public.reserved_usernames ENABLE ROW LEVEL SECURITY;

-- Ensure no implicit grants exist for app roles
REVOKE ALL ON TABLE public.reserved_usernames FROM anon, authenticated;


CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = '' 
AS $$
DECLARE
  default_avatar uuid;
  v_username     public.citext;  -- 👈 qualify the type
BEGIN
  SELECT id INTO default_avatar
  FROM public.avatars
  ORDER BY created_at ASC
  LIMIT 1;

  IF default_avatar IS NULL THEN
    RAISE EXCEPTION 'handle_new_user: no default avatar found';
  END IF;

  v_username := public._gen_unique_username(NEW.email, NEW.id);

  INSERT INTO public.profiles (id, email, full_name, avatar_id, username)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NULL),
    default_avatar,
    v_username
  )
  ON CONFLICT (id) DO UPDATE
    SET
      email     = COALESCE(public.profiles.email, EXCLUDED.email),
      full_name = COALESCE(public.profiles.full_name, EXCLUDED.full_name),
      avatar_id = COALESCE(public.profiles.avatar_id, EXCLUDED.avatar_id),
      username  = COALESCE(public.profiles.username, EXCLUDED.username);

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._gen_unique_username(p_email text, p_id uuid)
RETURNS public.citext
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  base       public.citext;
  candidate  public.citext;
  n          int := 0;
  max_tries  int := 100000;
  prefix_len int;
BEGIN
  -- derive from email local-part (DOT-LESS); fallback to id
  base := lower(
            coalesce(
              nullif(replace(split_part(p_email, '@', 1), '.', ''), ''),
              'user_' || substr(p_id::text, 1, 8)
            )
          );

  -- keep only [a-z0-9._], trim edges
  base := regexp_replace(base, '[^a-z0-9._]', '', 'g');
  base := regexp_replace(base, '^[._]+|[._]+$', '', 'g');

  -- (optional) collapse repeated separators: '..' or '__' -> '_'
  base := regexp_replace(base, '[._]{2,}', '_', 'g');

  -- ensure min length 3 (fallback to uuid prefix)
  IF length(base) < 3 THEN
    base := 'user' || substr(p_id::text, 1, 8);
  END IF;

  -- cap to 30 (we’ll shorten further if we add suffix)
  base := left(base, 30);

  -- serialize attempts per-base (reduces races)
  PERFORM pg_try_advisory_xact_lock(hashtextextended(base::text, 0));

  -- try base, then base_1, base_2, ... (keep total <= 30)
  LOOP
    IF n = 0 THEN
      candidate := base;
    ELSE
      -- room for '_' + n
      prefix_len := greatest(1, 30 - 1 - length(n::text));
      candidate  := left(base, prefix_len) || '_' || n::text;
    END IF;

    -- must match the CHECK regex: start/end alnum
    IF candidate ~ '^[a-z0-9](?:[a-z0-9._]{1,28})[a-z0-9]$' THEN
      -- skip if reserved
      IF NOT EXISTS (
           SELECT 1 FROM public.reserved_usernames r
           WHERE r.name = candidate
         )
      THEN
        -- unique test (case-insensitive due to citext + unique index)
        PERFORM 1 FROM public.profiles WHERE username = candidate;
        IF NOT FOUND THEN
          RETURN candidate;
        END IF;
      END IF;
    END IF;

    n := n + 1;
    IF n > max_tries THEN
      RAISE EXCEPTION 'Could not generate unique username after % attempts (base=%)', max_tries, base;
    END IF;
  END LOOP;
END
$$;
