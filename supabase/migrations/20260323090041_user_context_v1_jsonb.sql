DROP FUNCTION public.user_context_v1();

CREATE OR REPLACE FUNCTION public.user_context_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid;
  v_show_avatar boolean;
  v_has_preference_report boolean;
  v_has_personal_mentions boolean;
  v_has_personal_directory_content boolean;
  v_avatar_storage_path text;
  v_display_name text;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  v_has_preference_report := EXISTS (
    SELECT 1
    FROM public.preference_reports pr
    WHERE pr.subject_user_id = v_user
      AND pr.status = 'published'
  );

  v_has_personal_mentions := EXISTS (
    SELECT 1
    FROM public.gratitude_wall_personal_items i
    WHERE i.recipient_user_id = v_user
      AND i.author_user_id <> v_user
  );

  v_has_personal_directory_content := (
    EXISTS (
      SELECT 1
      FROM public.member_directory_bank_accounts b
      WHERE b.user_id = v_user
    )
    OR EXISTS (
      SELECT 1
      FROM public.member_directory_notes n
      WHERE n.user_id = v_user
        AND n.archived_at IS NULL
    )
  );

  v_show_avatar := (
    v_has_preference_report
    OR v_has_personal_mentions
    OR v_has_personal_directory_content
  );

  SELECT
    p.username,
    a.storage_path
  INTO v_display_name, v_avatar_storage_path
  FROM public.profiles p
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = v_user;

  IF NOT v_show_avatar THEN
    v_avatar_storage_path := NULL;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', v_user,
    'has_preference_report', v_has_preference_report,
    'has_personal_mentions', v_has_personal_mentions,
    'has_personal_directory_content', v_has_personal_directory_content,
    'show_avatar', v_show_avatar,
    'avatar_storage_path', v_avatar_storage_path,
    'display_name', v_display_name
  );
END;
$$;

COMMENT ON FUNCTION public.user_context_v1() IS
  'Self-only Start-surface context as jsonb. Returns caller-scoped artifact flags, derived show_avatar, avatar_storage_path, and display_name; no home fields are exposed.';

REVOKE ALL ON FUNCTION public.user_context_v1() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.user_context_v1() TO authenticated;
