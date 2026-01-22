ALTER TABLE public.revenuecat_event_processing ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.revenuecat_event_processing FROM PUBLIC;

ALTER TABLE public.revenuecat_webhook_events
  ALTER COLUMN idempotency_key SET NOT NULL;

DROP INDEX IF EXISTS revenuecat_webhook_events_env_idem_unique;

CREATE UNIQUE INDEX revenuecat_webhook_events_env_idem_unique
  ON public.revenuecat_webhook_events (environment, idempotency_key);

-- =====================================================================
-- Expenses: "Who paid me" (Today + drilldown) v1.1
-- - Adds recipient_viewed_at on expense_splits
-- - Safer invariant: recipient_viewed_at implies marked_paid_at is set
-- - Simplified locking: lock ONLY the expense row (single serialization point)
-- - Option A: expense_status stays lifecycle (draft/active/cancelled); paid/unpaid derived from splits
-- - Removes reliance on e.status='active' in recipient-facing queries
-- - JSONB responses for all RPCs
-- =====================================================================

-- ---------------------------------------------------------------------
-- Schema: recipient_viewed_at for expense_splits
-- ---------------------------------------------------------------------
ALTER TABLE public.expense_splits
  ADD COLUMN IF NOT EXISTS recipient_viewed_at timestamptz;

COMMENT ON COLUMN public.expense_splits.recipient_viewed_at IS
  'When the expense creator viewed this paid split (NULL = unseen).';

-- Safer invariant: if recipient_viewed_at is set, split must have marked_paid_at
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_expense_splits_recipient_viewed_state'
      AND conrelid = 'public.expense_splits'::regclass
  ) THEN
    ALTER TABLE public.expense_splits
      ADD CONSTRAINT chk_expense_splits_recipient_viewed_state
      CHECK (
        recipient_viewed_at IS NULL
        OR marked_paid_at IS NOT NULL
      );
  END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- RPC: expenses_mark_share_paid — JSON return, simplified locking
-- Lock ONLY the expense row. Paid/unpaid derived from splits.
-- ---------------------------------------------------------------------

-- Drop old typed-return function (signature matches name+args).
DROP FUNCTION IF EXISTS public.expenses_mark_share_paid(uuid);

CREATE FUNCTION public.expenses_mark_share_paid(
  p_expense_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user        uuid;
  v_expense     public.expenses%ROWTYPE;
  v_split       public.expense_splits%ROWTYPE;
  v_home_active boolean;
  v_has_unpaid  boolean;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EXPENSE',
      'Expense id is required.',
      '22023'
    );
  END IF;

  -- 🔒 Single serialization point for this expense
  SELECT *
  INTO v_expense
  FROM public.expenses e
  WHERE e.id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  -- Membership check (caller must be current member of the expense home)
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_expense.home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_expense.home_id)
    );
  END IF;

  -- Home active check (no need to lock homes row)
  SELECT h.is_active
  INTO v_home_active
  FROM public.homes h
  WHERE h.id = v_expense.home_id;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  -- 🔁 Idempotent guarded update: only transitions if not already paid
  UPDATE public.expense_splits
  SET status              = 'paid',
      marked_paid_at      = now(),
      recipient_viewed_at = NULL
  WHERE expense_id     = v_expense.id
    AND debtor_user_id = v_user
    AND status        <> 'paid'
  RETURNING * INTO v_split;

  -- If UPDATE affected 0 rows, it's either already paid OR no split exists.
  IF NOT FOUND THEN
    SELECT *
    INTO v_split
    FROM public.expense_splits s
    WHERE s.expense_id     = v_expense.id
      AND s.debtor_user_id = v_user;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'NOT_FOUND',
        'You do not have a share on this expense.',
        'P0002',
        jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
      );
    END IF;

    RETURN jsonb_build_object(
      'deduped', TRUE,
      'split', jsonb_build_object(
        'expenseId',         v_split.expense_id,
        'debtorUserId',      v_split.debtor_user_id,
        'status',            v_split.status,
        'amountCents',       v_split.amount_cents,
        'markedPaidAt',      v_split.marked_paid_at,
        'recipientViewedAt', v_split.recipient_viewed_at
      )
    );
  END IF;

  -- Determine if any unpaid splits remain (under expense row lock)
  SELECT EXISTS (
    SELECT 1
    FROM public.expense_splits s
    WHERE s.expense_id = v_expense.id
      AND s.status = 'unpaid'
  )
  INTO v_has_unpaid;

  -- If none remain, decrement home usage once (safe due to expense row lock)
  IF NOT v_has_unpaid THEN
    PERFORM public._home_usage_apply_delta(
      v_expense.home_id,
      jsonb_build_object('active_expenses', -1)
    );
  END IF;

  RETURN jsonb_build_object(
    'deduped', FALSE,
    'split', jsonb_build_object(
      'expenseId',         v_split.expense_id,
      'debtorUserId',      v_split.debtor_user_id,
      'status',            v_split.status,
      'amountCents',       v_split.amount_cents,
      'markedPaidAt',      v_split.marked_paid_at,
      'recipientViewedAt', v_split.recipient_viewed_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_mark_share_paid(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_mark_share_paid(uuid)
TO authenticated;


-- ---------------------------------------------------------------------
-- RPC: expenses_get_current_paid_to_me_debtors
-- - No e.status='active' filter (Option A)
-- - Filters marked_paid_at IS NOT NULL
-- - Assumes username exists
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_get_current_paid_to_me_debtors(
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

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'debtorUserId',   debtor_user_id,
               'debtorUsername', debtor_username,
               'totalPaidCents', total_paid_cents,
               'unseenCount',    unseen_count,
               'latestPaidAt',   latest_paid_at
             )
             ORDER BY latest_paid_at DESC,
                      debtor_username,
                      debtor_user_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      s.debtor_user_id                                      AS debtor_user_id,
      p.username                                            AS debtor_username,
      SUM(s.amount_cents)                                   AS total_paid_cents,
      COUNT(*) FILTER (WHERE s.recipient_viewed_at IS NULL) AS unseen_count,
      MAX(s.marked_paid_at)                                 AS latest_paid_at
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.profiles p
      ON p.id = s.debtor_user_id
    WHERE e.home_id            = p_home_id
      AND e.created_by_user_id = v_user
      AND s.status             = 'paid'
      AND s.marked_paid_at     IS NOT NULL
      AND s.debtor_user_id    <> e.created_by_user_id
    GROUP BY s.debtor_user_id, p.username
  ) debtors;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_current_paid_to_me_debtors(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_get_current_paid_to_me_debtors(uuid)
TO authenticated;


-- ---------------------------------------------------------------------
-- RPC: expenses_get_current_paid_to_me_by_debtor_details
-- - No e.status='active' filter (Option A)
-- - Filters marked_paid_at IS NOT NULL
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_get_current_paid_to_me_by_debtor_details(
  p_home_id uuid,
  p_debtor_user_id uuid
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

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  IF p_debtor_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Debtor id is required.',
      '22023'
    );
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',    e.id,
               'description',  e.description,
               'notes',        e.notes,
               'amountCents',  s.amount_cents,
               'markedPaidAt', s.marked_paid_at
             )
             ORDER BY s.marked_paid_at DESC, e.id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM public.expense_splits s
  JOIN public.expenses e
    ON e.id = s.expense_id
  WHERE e.home_id            = p_home_id
    AND e.created_by_user_id = v_user
    AND s.debtor_user_id     = p_debtor_user_id
    AND s.status             = 'paid'
    AND s.marked_paid_at     IS NOT NULL;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_current_paid_to_me_by_debtor_details(uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_get_current_paid_to_me_by_debtor_details(uuid, uuid)
TO authenticated;


-- ---------------------------------------------------------------------
-- RPC: expenses_mark_paid_received_viewed_for_debtor (JSONB)
-- - Marks recipient_viewed_at for paid splits from a specific debtor
-- - Filters marked_paid_at IS NOT NULL for consistency
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_mark_paid_received_viewed_for_debtor(
  p_home_id uuid,
  p_debtor_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user    uuid;
  v_updated integer := 0;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  IF p_debtor_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Debtor id is required.',
      '22023'
    );
  END IF;

  UPDATE public.expense_splits s
  SET recipient_viewed_at = now()
  FROM public.expenses e
  WHERE s.expense_id          = e.id
    AND e.home_id             = p_home_id
    AND e.created_by_user_id  = v_user
    AND s.debtor_user_id      = p_debtor_user_id
    AND s.status              = 'paid'
    AND s.marked_paid_at      IS NOT NULL
    AND s.debtor_user_id     <> e.created_by_user_id
    AND s.recipient_viewed_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('updated', COALESCE(v_updated, 0));
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_mark_paid_received_viewed_for_debtor(uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_mark_paid_received_viewed_for_debtor(uuid, uuid)
TO authenticated;
