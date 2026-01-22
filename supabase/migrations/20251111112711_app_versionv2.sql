-- Ensure owner is the privileged 'postgres' role
ALTER FUNCTION public.check_app_version(TEXT)
OWNER TO postgres;

-- Remove default public privileges
REVOKE ALL ON FUNCTION public.check_app_version(TEXT)
FROM PUBLIC;

-- Allow PostgREST client roles to call the RPC
GRANT USAGE   ON SCHEMA public TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_app_version(TEXT)
TO anon, authenticated;
