DROP FUNCTION IF EXISTS public.homes_create_with_invite(text);

CREATE OR REPLACE FUNCTION public.homes_create_with_invite()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home public.homes;
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();

  INSERT INTO public.homes (owner_user_id)
  VALUES (v_user)
  RETURNING * INTO v_home;

  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT ON CONSTRAINT uq_invites_active_one_per_home DO NOTHING
  RETURNING * INTO v_inv;

  IF NOT FOUND THEN
    SELECT * INTO v_inv
    FROM public.invites
    WHERE home_id = v_home.id AND revoked_at IS NULL
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'home', jsonb_build_object(
      'id',            v_home.id
                )  );
END;
$$;
