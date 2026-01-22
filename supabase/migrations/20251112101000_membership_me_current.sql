-- ---------------------------------------------------------------------
-- membership_me_current(): returns current membership for caller (or null)
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.membership_me_current()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row  public.memberships;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_row
  FROM public.memberships m
  WHERE m.user_id = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'current', NULL);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'current', jsonb_build_object(
      'user_id', v_row.user_id,
      'home_id', v_row.home_id,
      'role',    v_row.role,
      'valid_from', v_row.valid_from
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.membership_me_current() TO authenticated;

