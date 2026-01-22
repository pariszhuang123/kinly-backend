-- Assert that a home exists and is active.
CREATE OR REPLACE FUNCTION public._assert_home_active(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_active boolean;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  SELECT h.is_active
  INTO v_is_active
  FROM public.homes h
  WHERE h.id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOME_NOT_FOUND',
      'Home does not exist.',
      'P0002',
      jsonb_build_object('homeId', p_home_id)
    );
  ELSIF v_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;
END;
$$;

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
      e.created_by_user_id           AS payer_user_id,
      COALESCE(p.full_name, p.email) AS payer_display,
      a.storage_path                 AS payer_avatar_url,  -- payer MUST have avatar
      SUM(s.amount_cents)            AS total_owed_cents,
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
    COALESCE(c.next_occurrence, c.start_date) AS current_due_date,
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

CREATE OR REPLACE FUNCTION public.chores_list_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id                           uuid,
  home_id                      uuid,
  assignee_user_id             uuid,
  name                         text,
  start_date                   date,  -- current due date
  assignee_full_name           text,
  assignee_avatar_storage_path text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    id,
    home_id,
    assignee_user_id,
    name,
    current_due_date AS start_date,
    assignee_full_name,
    assignee_avatar_storage_path
  FROM public._chores_base_for_home(p_home_id)
  WHERE
    state IN ('draft', 'active')
    AND (
      -- active: any member (already enforced by _assert_home_member)
      state = 'active'::public.chore_state
      -- draft: only creator can see
      OR (state = 'draft'::public.chore_state
          AND created_by_user_id = auth.uid())
    )
  ORDER BY
    current_due_date DESC,
    created_at      DESC;
$$;


CREATE OR REPLACE FUNCTION public.today_flow_list(
  p_home_id uuid,
  p_state   public.chore_state
)
RETURNS TABLE (
  id         uuid,
  home_id    uuid,
  name       text,
  start_date date,
  state      public.chore_state
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    id,
    home_id,
    name,
    current_due_date AS start_date,
    state
  FROM public._chores_base_for_home(p_home_id)
  WHERE
    state = p_state
    AND current_due_date <= current_date  -- due today or overdue
    AND (
      -- 🟩 ACTIVE: only creator sees it
      (p_state = 'draft'::public.chore_state
       AND created_by_user_id = auth.uid())

      -- 🟦 DRAFT: only assignee sees it
      OR
      (p_state = 'active'::public.chore_state
       AND assignee_user_id = auth.uid())
    )
  ORDER BY
    current_due_date ASC,
    created_at      ASC;
$$;
