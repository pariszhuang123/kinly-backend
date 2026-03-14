-- Restore missing house norms member review helper used by house_norms_get_for_home.

CREATE OR REPLACE FUNCTION public.house_norms_should_show_member_review(
  p_home_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms%ROWTYPE;
  v_member_viewed_at timestamptz := NULL;
  v_norms_change_at timestamptz := NULL;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  IF public.is_home_owner(p_home_id, auth.uid()) THEN
    RETURN false;
  END IF;

  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id;

  IF v_row.home_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT mv.viewed_at
    INTO v_member_viewed_at
  FROM public.house_norms_member_views mv
  WHERE mv.home_id = p_home_id
    AND mv.user_id = auth.uid()
  LIMIT 1;

  v_norms_change_at := COALESCE(v_row.last_edited_at, v_row.generated_at);

  RETURN (
    v_norms_change_at IS NOT NULL
    AND now() >= (v_norms_change_at + interval '24 hours')
    AND (v_member_viewed_at IS NULL OR v_member_viewed_at < v_norms_change_at)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.house_norms_should_show_member_review(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.house_norms_should_show_member_review(uuid)
TO authenticated;
