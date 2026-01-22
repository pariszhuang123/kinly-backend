-- =====================================================================
--  RPC: gratitude_wall_status
--  Returns last_read_at and whether newer posts exist for the home
-- =====================================================================

CREATE OR REPLACE FUNCTION public.gratitude_wall_status(
  p_home_id uuid
) RETURNS TABLE (
  has_unread   boolean,
  last_read_at timestamptz
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id          uuid := auth.uid();
  v_latest_created_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT r.last_read_at
  INTO last_read_at
  FROM public.gratitude_wall_reads r
  WHERE r.home_id = p_home_id
    AND r.user_id = v_user_id
  LIMIT 1;

  SELECT p.created_at
  INTO v_latest_created_at
  FROM public.gratitude_wall_posts p
  WHERE p.home_id = p_home_id
    AND p.author_user_id <> v_user_id  
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT 1;

  has_unread :=
    CASE
      WHEN v_latest_created_at IS NULL THEN FALSE
      WHEN last_read_at IS NULL THEN TRUE
      ELSE v_latest_created_at > last_read_at
    END;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.gratitude_wall_status(uuid) IS
  'Returns whether the current user has unread gratitude wall posts for the given home, and the last_read_at timestamp.';

REVOKE ALL ON FUNCTION public.gratitude_wall_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gratitude_wall_status(uuid) TO authenticated;
