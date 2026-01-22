CREATE OR REPLACE FUNCTION public.expenses_get_for_edit(
  p_expense_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user            uuid := auth.uid();
  v_expense         public.expenses%ROWTYPE;
  v_home_is_active  boolean;
  v_splits          jsonb := '[]'::jsonb;
  v_has_paid_splits boolean := FALSE;
  v_amount_locked   boolean := FALSE;
BEGIN
  -- Require authentication
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EXPENSE',
      'Expense id is required.',
      '22023'
    );
  END IF;

  /*
    Load the expense and ensure:
      - caller is a current member of the home
    This avoids leaking whether an expense exists in another home:
      - If not found here, the caller simply gets NOT_FOUND.
  */
  SELECT e.*
  INTO v_expense
  FROM public.expenses e
  JOIN public.homes h
    ON h.id = e.home_id
  WHERE e.id = p_expense_id
    AND EXISTS (
      SELECT 1
      FROM public.memberships m
      WHERE m.home_id    = e.home_id
        AND m.user_id    = v_user
        AND m.is_current = TRUE
    );

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  -- Load home active flag separately (after we know the expense is visible)
  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_expense.home_id;

  -- Home must be active (frozen when inactive)
  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', v_expense.home_id)
    );
  END IF;

  -- Only creator can edit
  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can edit this expense.',
      '42501',
      jsonb_build_object(
        'expenseId', p_expense_id,
        'userId',    v_user
      )
    );
  END IF;

  -- Enforce allowed edit states:
  -- 1) draft
  -- 2) active with NO paid splits
  IF v_expense.status NOT IN ('draft', 'active') THEN
    PERFORM public.api_error(
      'EDIT_NOT_ALLOWED',
      'Only draft or active expenses can be edited.',
      '42501',
      jsonb_build_object(
        'expenseId', p_expense_id,
        'status',    v_expense.status
      )
    );
  END IF;

  IF v_expense.status = 'active' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.expense_splits s
      WHERE s.expense_id = v_expense.id
        AND s.status     = 'paid'
    )
    INTO v_has_paid_splits;
  END IF;

  v_amount_locked := v_expense.status = 'active' AND v_has_paid_splits;

  -- Build splits payload (for draft or active with no paid splits)
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expense_id',     s.expense_id,
               'debtor_user_id', s.debtor_user_id,
               'amount_cents',   s.amount_cents,
               'status',         s.status,
               'marked_paid_at', s.marked_paid_at
             )
             ORDER BY s.debtor_user_id
           ),
           '[]'::jsonb
         )
  INTO v_splits
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id;

  RETURN jsonb_build_object(
    'id',                 v_expense.id,
    'home_id',            v_expense.home_id,
    'created_by_user_id', v_expense.created_by_user_id,
    'status',             v_expense.status,
    'split_type',         v_expense.split_type,
    'amount_cents',       v_expense.amount_cents,
    'description',        v_expense.description,
    'notes',              v_expense.notes,
    'created_at',         v_expense.created_at,
    'updated_at',         v_expense.updated_at,
    'amount_locked',      v_amount_locked,
    'splits',             v_splits
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_for_edit(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_get_for_edit(uuid)
TO authenticated;
