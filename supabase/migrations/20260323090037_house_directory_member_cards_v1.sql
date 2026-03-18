-- House Directory v1.3
-- Home directory member-card roster for current members of the caller's
-- active home. Caller is always included. Other members are included only
-- when they have any personal-directory content.

CREATE OR REPLACE FUNCTION public.get_home_directory_member_cards()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
  v_members jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT m.home_id
    INTO v_home_id
  FROM public.memberships m
  JOIN public.homes h
    ON h.id = m.home_id
  WHERE m.user_id = auth.uid()
    AND m.is_current = TRUE
    AND h.is_active = TRUE;

  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a current member of an active home.',
      '42501'
    );
  END IF;

  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'user_id', member_rows.user_id,
               'username', member_rows.username,
               'avatar_storage_path', member_rows.avatar_storage_path,
               'is_owner', member_rows.is_owner,
               'has_personal_directory_content', member_rows.has_personal_directory_content
             )
             ORDER BY
               CASE WHEN member_rows.is_owner THEN 0 ELSE 1 END,
               lower(member_rows.username),
               member_rows.user_id
           ),
           '[]'::jsonb
         )
    INTO v_members
  FROM (
    SELECT
      m.user_id,
      p.username,
      a.storage_path AS avatar_storage_path,
      (h.owner_user_id = m.user_id) AS is_owner,
      (
        EXISTS (
          SELECT 1
          FROM public.member_directory_bank_accounts b
          WHERE b.user_id = m.user_id
        )
        OR EXISTS (
          SELECT 1
          FROM public.member_directory_notes n
          WHERE n.user_id = m.user_id
            AND n.archived_at IS NULL
        )
      ) AS has_personal_directory_content
    FROM public.memberships m
    JOIN public.homes h
      ON h.id = m.home_id
    JOIN public.profiles p
      ON p.id = m.user_id
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE m.home_id = v_home_id
      AND m.is_current = TRUE
      AND (
        m.user_id = auth.uid()
        OR (
          EXISTS (
            SELECT 1
            FROM public.member_directory_bank_accounts b
            WHERE b.user_id = m.user_id
          )
          OR EXISTS (
            SELECT 1
            FROM public.member_directory_notes n
            WHERE n.user_id = m.user_id
              AND n.archived_at IS NULL
          )
        )
      )
  ) AS member_rows;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', v_home_id,
    'members', v_members
  );
END;
$$;

COMMENT ON FUNCTION public.get_home_directory_member_cards() IS
'Returns member cards for the authenticated user''s active home. The caller is always included. Other members are included only when they have personal-directory content. Payload includes username, avatar_storage_path, owner flag, and has_personal_directory_content.';

REVOKE ALL ON FUNCTION public.get_home_directory_member_cards() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_home_directory_member_cards() TO authenticated;
