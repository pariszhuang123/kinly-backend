CREATE OR REPLACE FUNCTION public.api_error(
  p_code     text,
  p_msg      text,
  p_sqlstate text  DEFAULT 'P0001',
  p_details  jsonb DEFAULT NULL,
  p_hint     text  DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_message text;
  v_detail  text;
BEGIN
  -- Build a structured JSON error message.
  v_message := pg_catalog.json_build_object(
    'code',    p_code,
    'message', p_msg,
    'details', COALESCE(p_details, '{}'::jsonb)
  )::text;

  -- DETAIL should never be NULL in RAISE ... USING
  v_detail := COALESCE(p_details::text, '');

  RAISE EXCEPTION USING
    MESSAGE = COALESCE(v_message, 'Unknown error'),
    ERRCODE = COALESCE(p_sqlstate, 'P0001'),
    DETAIL  = v_detail,
    HINT    = COALESCE(p_hint, '');
END;
$$;
