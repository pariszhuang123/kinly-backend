DROP FUNCTION IF EXISTS public.gratitude_wall_list(
  uuid,
  int,
  timestamptz,
  uuid
);

CREATE OR REPLACE FUNCTION public.gratitude_wall_list(
  p_home_id            uuid,
  p_limit              int DEFAULT 20,
  p_cursor_created_at  timestamptz DEFAULT NULL,
  p_cursor_id          uuid DEFAULT NULL
) RETURNS TABLE (
  post_id             uuid,
  author_user_id      uuid,
  author_username     citext,
  author_avatar_url   text,
  mood                public.mood_scale,
  message             text,
  created_at          timestamptz
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit int := LEAST(COALESCE(p_limit, 20), 100);
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  RETURN QUERY
  SELECT
    p.id,
    p.author_user_id,
    pr.username,
    a.storage_path AS author_avatar_url,
    p.mood,
    p.message,
    p.created_at
  FROM public.gratitude_wall_posts AS p
  JOIN public.profiles AS pr
    ON pr.id = p.author_user_id
  LEFT JOIN public.avatars AS a
    ON a.id = pr.avatar_id
  WHERE p.home_id = p_home_id
    AND (
      p_cursor_created_at IS NULL
      OR (
        p.created_at < p_cursor_created_at
        OR (
          p_cursor_id IS NOT NULL
          AND p.created_at = p_cursor_created_at
          AND p.id < p_cursor_id
        )
      )
    )
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.gratitude_wall_list(uuid, int, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.gratitude_wall_list(uuid, int, timestamptz, uuid)
  TO authenticated;
