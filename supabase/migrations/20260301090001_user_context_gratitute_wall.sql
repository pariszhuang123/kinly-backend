DROP FUNCTION public.user_context_v1();

CREATE OR REPLACE FUNCTION public.user_context_v1()
RETURNS TABLE (
  user_id uuid,
  has_preference_report boolean,
  has_personal_mentions boolean,
  show_avatar boolean,
  avatar_storage_path text,
  display_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  -- Broad existence check: any published personal preference report (any template/locale)
  has_preference_report := EXISTS (
    SELECT 1
    FROM public.preference_reports pr
    WHERE pr.subject_user_id = v_user
      AND pr.status = 'published'
  );

  -- Personal mentions exist (self-only existence check)
  has_personal_mentions := EXISTS (
    SELECT 1
    FROM public.gratitude_wall_personal_items i
    WHERE i.recipient_user_id = v_user
      AND i.author_user_id <> v_user
  );

  show_avatar := (has_preference_report OR has_personal_mentions);

  -- Only return avatar storage path if the avatar should be shown
  SELECT
    p.username,
    a.storage_path
  INTO display_name, avatar_storage_path
  FROM public.profiles p
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = v_user;

  IF NOT show_avatar THEN
    avatar_storage_path := NULL;
  END IF;

  user_id := v_user;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.user_context_v1()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.user_context_v1()
  TO authenticated;

COMMENT ON FUNCTION public.user_context_v1() IS
  'Self-only context for Start Page avatar menu + personal profile access. No home fields are returned. show_avatar gates avatar rendering; avatar_storage_path is NULL when show_avatar=false. display_name mirrors profiles.username.';



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
    -- ✅ EPHEMERAL WINDOW (last 7 days)
    AND p.created_at >= (now() - interval '7 days')
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
