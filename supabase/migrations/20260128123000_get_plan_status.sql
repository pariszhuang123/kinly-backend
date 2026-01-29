-- Plan status entrypoint for Profile app bar
-- Provides current home plan for the caller (free/premium) without exposing entitlements table directly.

CREATE OR REPLACE FUNCTION public.get_plan_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_home_id uuid;
  v_plan    text := 'free';
BEGIN
  PERFORM public._assert_authenticated();

  -- Resolve caller's current home (one active stint enforced by uq_memberships_user_one_current)
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user_id
     AND m.is_current = TRUE
   LIMIT 1;

  -- No current home → UI should use failure fallback
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'NO_CURRENT_HOME',
      'You are not currently a member of any home.',
      '42501',
      jsonb_build_object(
        'context', 'get_plan_status',
        'reason',  'no_current_home'
      )
    );
  END IF;

  -- Guards
  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  -- Effective plan (subscription-aware)
  v_plan := COALESCE(public._home_effective_plan(v_home_id), 'free');

  RETURN jsonb_build_object(
    'plan',    v_plan,
    'home_id', v_home_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_plan_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_plan_status() TO authenticated;
