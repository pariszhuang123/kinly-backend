CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id), 
  email       TEXT UNIQUE NOT NULL,  -- user email address from auth.users
  full_name   TEXT,                  -- optional display name
  avatar_id   UUID NOT NULL REFERENCES public.avatars(id), -- required FK to avatars table
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deactivated_at timestamptz       -- NULL = active

);

COMMENT ON TABLE  public.profiles                IS 'App-facing persona mirroring auth.users by id (1:1).';
COMMENT ON COLUMN public.profiles.id             IS 'Primary key = auth.users.id..'; 
COMMENT ON COLUMN public.profiles.email          IS 'User email address mirrored from auth.users.email.';
COMMENT ON COLUMN public.profiles.full_name      IS 'Optional display name.';
COMMENT ON COLUMN public.profiles.avatar_id      IS 'FK to public.avatars.id (required avatar).';
COMMENT ON COLUMN public.profiles.created_at     IS 'Profile creation timestamp (UTC).';
COMMENT ON COLUMN public.profiles.deactivated_at IS
  'Timestamp when the user deactivated or left the app. NULL = currently active. Used for soft-deletion and retention tracking.';



ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Clients may only read (write via triggers or RPCs)
REVOKE INSERT, UPDATE, DELETE ON public.profiles FROM anon, authenticated;
GRANT SELECT ON public.profiles TO authenticated;

DROP POLICY IF EXISTS profiles_select_authenticated ON public.profiles;

CREATE POLICY profiles_select_authenticated
  ON public.profiles
  FOR SELECT
  USING (id = (SELECT auth.uid()));



COMMENT ON POLICY profiles_select_authenticated ON public.profiles
  IS 'Allows SELECT for authenticated users only (RLS enforced).';

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  default_avatar UUID;
BEGIN
  -- Pick a random starter avatar (or first one in table)
  SELECT id INTO default_avatar
  FROM public.avatars
  ORDER BY created_at ASC
  LIMIT 1;

  INSERT INTO public.profiles (id, email, full_name, avatar_id)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NULL),
    default_avatar
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;



COMMENT ON FUNCTION public.handle_new_user()
  IS 'Trigger function to create a default profile row for each new auth user with a default avatar.';


DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_user();

-- 1. Add the new column `name`
ALTER TABLE public.avatars
ADD COLUMN name TEXT NOT NULL DEFAULT 'Unnamed Avatar';

COMMENT ON COLUMN public.avatars.name IS 'Human-readable name describing what this avatar is about.';

-- 2. Restrict category values to "animal" or "plant" using a CHECK constraint
ALTER TABLE public.avatars
ADD CONSTRAINT avatars_category_check
CHECK (category IN ('animal', 'plant'));

COMMENT ON CONSTRAINT avatars_category_check ON public.avatars
IS 'Restricts category to only "animal" or "plant".';


CREATE OR REPLACE FUNCTION public.profiles_delete_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- TODO: Replace with actual delete logic once RPC is implemented.
  RAISE NOTICE 'profiles_delete_account stub invoked';
  RETURN;
END;
$$;

COMMENT ON FUNCTION public.profiles_delete_account()
IS 'Stub RPC placeholder for deleting the authenticated user profile/account.';
