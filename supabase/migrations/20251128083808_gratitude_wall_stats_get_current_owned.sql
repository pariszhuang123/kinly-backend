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
    AND p.is_active = TRUE;

  total_posts  := COALESCE(v_total_posts, 0);
  unread_count := COALESCE(v_unread_count, 0);
  last_read_at := v_last_read_at;

  RETURN NEXT;
END;
$$;

-- --------------------------------------------------------------------
-- Permissions
-- --------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.gratitude_wall_stats(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.gratitude_wall_stats(uuid)
TO authenticated;

COMMENT ON FUNCTION public.gratitude_wall_stats(uuid) IS
  'Returns total, unread count, and last_read_at for the current user''s gratitude wall in the given home.';

CREATE OR REPLACE FUNCTION public.expenses_get_current_owed(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user   uuid;
  v_result jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  -- Membership + active checks (using shared helpers)
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Build owed summary for the current user in this home
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'payerUserId',     payer_user_id,
               'payerDisplay',    payer_display,
               'payerAvatarUrl',  payer_avatar_url,
               'totalOwedCents',  total_owed_cents,
               'items',           items
             )
             ORDER BY payer_display NULLS LAST, payer_user_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      e.created_by_user_id                          AS payer_user_id,
      COALESCE(p.username, p.full_name, p.email)    AS payer_display,
      a.storage_path                                AS payer_avatar_url,  -- payer MUST have avatar
      SUM(s.amount_cents)                           AS total_owed_cents,
      jsonb_agg(
        jsonb_build_object(
          'expenseId',   e.id,
          'description', e.description,
          'amountCents', s.amount_cents,
          'notes',       e.notes
        )
        ORDER BY e.created_at DESC, e.id
      ) AS items
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.profiles p
      ON p.id = e.created_by_user_id
    JOIN public.avatars a
      ON a.id = p.avatar_id          -- inner join enforces "payer has avatar"
    WHERE e.home_id        = p_home_id
      AND e.status         = 'active'
      AND s.debtor_user_id = v_user
      AND s.status         = 'unpaid'
    GROUP BY e.created_by_user_id, payer_display, payer_avatar_url
  ) owed;

  RETURN v_result;
END;
$$;
