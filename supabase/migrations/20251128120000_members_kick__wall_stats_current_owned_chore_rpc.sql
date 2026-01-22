-- ---------------------------------------------------------------------
-- members.kick(home_id, target_user_id) -> removes a member (owner-only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.members_kick(
  p_home_id uuid,
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_target_role        text;
  v_rows_updated       integer;
  v_members_remaining  integer;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);

  --------------------------------------------------------------------
  -- 1) Verify caller is the current owner of the active home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id    = v_user
        AND m.home_id    = p_home_id
        AND m.role       = 'owner'
        AND m.is_current = TRUE
        AND h.is_active  = TRUE
    ),
    'FORBIDDEN',
    'Only the current owner can remove members.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  --------------------------------------------------------------------
  -- 2) Validate target is a current (non-owner) member
  --------------------------------------------------------------------
  SELECT m.role
    INTO v_target_role
    FROM public.memberships m
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
   LIMIT 1;

  PERFORM public.api_assert(
    v_target_role IS NOT NULL,
    'TARGET_NOT_MEMBER',
    'The selected user is not an active member of this home.',
    'P0002',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  PERFORM public.api_assert(
    v_target_role <> 'owner',
    'CANNOT_KICK_OWNER',
    'Owners cannot be removed.',
    '42501',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 3) Serialize with other membership mutations and close the stint
  --------------------------------------------------------------------
  -- Lock the home row to serialize join/leave/kick operations
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  UPDATE public.memberships m
     SET valid_to   = now(),
         is_valid   = FALSE,
         is_current = FALSE,
         updated_at = now()
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
  RETURNING 1 INTO v_rows_updated;

  PERFORM public.api_assert(
    v_rows_updated = 1,
    'STATE_CHANGED_RETRY',
    'Membership state changed; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 4) Return success payload
  --------------------------------------------------------------------
  SELECT COUNT(*) INTO v_members_remaining
    FROM public.memberships m
   WHERE m.home_id    = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'member_removed',
    'message', 'Member removed successfully.',
    'data', jsonb_build_object(
      'home_id',           p_home_id,
      'user_id',           p_target_user_id,
      'members_remaining', v_members_remaining
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.members_kick(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.members_kick(uuid, uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public._chores_base_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id                           uuid,
  home_id                      uuid,
  assignee_user_id             uuid,
  created_by_user_id           uuid,
  name                         text,
  state                        public.chore_state,
  current_due_date             date,
  created_at                   timestamptz,
  assignee_full_name           text,
  assignee_avatar_storage_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.assignee_user_id,
    c.created_by_user_id,
    c.name,
    c.state,
    CASE
      WHEN c.completed_at IS NULL THEN c.start_date
      ELSE c.next_occurrence
    END AS current_due_date,
    c.created_at,
    pa.full_name AS assignee_full_name,
    a.storage_path AS assignee_avatar_storage_path
  FROM public.chores c
  LEFT JOIN public.profiles pa
    ON pa.id = c.assignee_user_id
  LEFT JOIN public.avatars a
    ON a.id = pa.avatar_id
  WHERE
    c.home_id = p_home_id;
END;
$$;


-- ====================================================================
-- gratitude_wall_stats
-- --------------------------------------------------------------------
-- Returns:
--   - total_posts:  total active posts in the home's gratitude wall
--   - unread_count: posts created after the current user's last_read_at
--   - last_read_at: last time the current user read the wall (can be NULL)
-- ====================================================================
CREATE OR REPLACE FUNCTION public.gratitude_wall_stats(
  p_home_id uuid
) RETURNS TABLE (
  total_posts  int,
  unread_count int,
  last_read_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_last_read_at  timestamptz;
  v_total_posts   int;
  v_unread_count  int;
BEGIN
  -- Guard: must be authenticated & an active member of the home
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Get the most recent last_read_at for this user + home
  SELECT MAX(r.last_read_at)
  INTO v_last_read_at
  FROM public.gratitude_wall_reads AS r
  WHERE r.home_id = p_home_id
    AND r.user_id = auth.uid();

  -- Count total + unread posts in a single scan
  SELECT
    COUNT(*)::int AS total_posts,
    (COUNT(*) FILTER (
       WHERE v_last_read_at IS NULL
          OR p.created_at > v_last_read_at
     ))::int AS unread_count
  INTO
    v_total_posts,
    v_unread_count
  FROM public.gratitude_wall_posts AS p
  WHERE p.home_id   = p_home_id
    -- Keep stats simple: count all posts for the home. If soft-delete is added later,
    -- reintroduce an is_active predicate alongside the column.
    ;

  total_posts  := COALESCE(v_total_posts, 0);
  unread_count := COALESCE(v_unread_count, 0);
  last_read_at := v_last_read_at;

  RETURN NEXT;
END;
$$;
