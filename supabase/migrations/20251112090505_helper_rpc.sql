CREATE OR REPLACE FUNCTION public._current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = ''          -- force fully-qualified lookups
AS $$
  SELECT auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.api_error(
  p_code text, p_msg text, p_sqlstate text DEFAULT 'P0001',
  p_details jsonb DEFAULT NULL, p_hint text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''          -- important for safety
AS $$
BEGIN
  RAISE EXCEPTION USING
    MESSAGE = pg_catalog.json_build_object('code', p_code, 'message', p_msg, 'details', p_details)::text,
    ERRCODE = p_sqlstate,
    DETAIL  = p_details::text,
    HINT    = p_hint;
END;
$$;

CREATE OR REPLACE FUNCTION public.api_assert(
  p_condition boolean, p_code text, p_msg text,
  p_sqlstate text DEFAULT 'P0001', p_details jsonb DEFAULT NULL, p_hint text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NOT coalesce(p_condition, false) THEN
    PERFORM public.api_error(p_code, p_msg, p_sqlstate, p_details, p_hint);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public._assert_authenticated()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM public.api_error('UNAUTHORIZED', 'Authentication required', '28000');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public._gen_invite_code()
RETURNS public.citext
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  out_code text := '';
  i int; idx int;
BEGIN
  FOR i IN 1..6 LOOP
    idx := 1 + floor(random() * length(alphabet))::int;
    out_code := out_code || substr(alphabet, idx, 1);
  END LOOP;
  RETURN out_code::public.citext; -- schema-qualify the type too
END;
$$;
