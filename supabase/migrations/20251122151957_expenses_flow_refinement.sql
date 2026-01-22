ALTER TABLE public.expense_splits ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.expense_splits FROM anon, authenticated;

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.expenses FROM anon, authenticated;


CREATE OR REPLACE FUNCTION public.expenses_get_created_by_me(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_result         jsonb;
  v_home_is_active boolean;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  -- Caller must be a current member of this home
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = p_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id, 'userId', v_user)
    );
  END IF;

  -- Home is fully frozen when inactive
  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = p_home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  /*
    Build list of live expenses created by the current user.

    Rules:
    - Include creator in the split stats so paidAmountCents / amountCents
      reflects:
        * 25/60 when only the creator has paid
        * 60/60 when everyone has paid.
    - Exclude expenses that:
        * are fully paid (all shares paid), AND
        * were created more than 14 days ago.
    - Sort by:
        1) payment status: unpaid → partial → fully paid
        2) createdAt: newest first
  */
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',        e.id,
               'homeId',           e.home_id,
               'createdByUserId',  e.created_by_user_id,
               'description',      e.description,
               'amountCents',      e.amount_cents,
               'status',           e.status,
               'splitType',        e.split_type,
               'createdAt',        e.created_at,
               'totalShares',      COALESCE(stats.total_shares, 0)::int,
               'paidShares',       COALESCE(stats.paid_shares, 0)::int,
               'paidAmountCents',  COALESCE(stats.paid_amount_cents, 0),
               'allPaid',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN FALSE
                   ELSE COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                 END,
               'fullyPaidAt',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN NULL
                   WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                     THEN stats.max_paid_at
                   ELSE NULL
                 END
             )
             ORDER BY
               -- payment status rank: 0 = unpaid, 1 = partial, 2 = fully paid
               CASE
                 WHEN COALESCE(stats.total_shares, 0) = 0 THEN 0                             -- treat as unpaid
                 WHEN COALESCE(stats.paid_shares, 0) = 0 THEN 0                             -- unpaid
                 WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                   THEN 2                                                                   -- fully paid
                 ELSE 1                                                                     -- partially paid
               END,
               e.created_at DESC,
               e.id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM public.expenses e
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) AS total_shares,
        COUNT(*) FILTER (WHERE s.status = 'paid') AS paid_shares,
        COALESCE(
          SUM(s.amount_cents) FILTER (WHERE s.status = 'paid'),
          0
        ) AS paid_amount_cents,
        MAX(s.marked_paid_at) FILTER (WHERE s.status = 'paid') AS max_paid_at
      FROM public.expense_splits s
      WHERE s.expense_id = e.id
      -- 👆 creator IS included here now
    ) stats ON TRUE
  WHERE e.home_id            = p_home_id
    AND e.created_by_user_id = v_user
    AND e.status IN ('draft', 'active')
    -- Filter out fully-paid expenses older than 14 days
    AND NOT (
      COALESCE(stats.total_shares, 0) > 0
      AND COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
      AND e.created_at < (CURRENT_TIMESTAMP - INTERVAL '14 days')
    );

  RETURN v_result;
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
  start_date                   date,
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

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.assignee_user_id,
    c.name,
    c.start_date,
    pa.full_name AS assignee_full_name,
    a.storage_path AS assignee_avatar_storage_path
  FROM public.chores c
  LEFT JOIN public.profiles pa
    ON pa.id = c.assignee_user_id
  LEFT JOIN public.avatars a
    ON a.id = pa.avatar_id
  WHERE
    c.home_id = p_home_id
    AND c.state IN ('draft', 'active')
    AND (
      -- Active: visible to any member of the home
      c.state = 'active'::public.chore_state

      -- Draft: only visible to the creator
      OR (c.state = 'draft'::public.chore_state AND c.created_by_user_id = v_user)
    )
  ORDER BY 
    c.start_date DESC,
    c.created_at DESC;
END;
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.name,
    c.start_date,
    c.state
  FROM public.chores AS c
  WHERE
    c.home_id = p_home_id
    AND c.state = p_state
    AND (
      -- 🟦 DRAFT: only creator sees it
      (p_state = 'draft'::public.chore_state AND c.created_by_user_id = v_user)

      -- 🟩 ACTIVE: only assigned user sees it
      OR
      (p_state = 'active'::public.chore_state AND c.assignee_user_id = v_user)
    )
  ORDER BY
    c.start_date ASC,
    c.created_at ASC;
END;
$$;