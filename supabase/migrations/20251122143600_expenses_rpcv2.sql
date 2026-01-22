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
      AND s.debtor_user_id <> v_expense.created_by_user_id
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

-- =====================================================================
--  RPC: expenses.cancel
-- =====================================================================

CREATE OR REPLACE FUNCTION public.expenses_cancel(
  p_expense_id uuid
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_expense        public.expenses%ROWTYPE;
  v_home_is_active boolean;
  v_has_paid       boolean := FALSE;
BEGIN
  -- Auth
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  -- Input validation
  IF p_expense_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EXPENSE',
      'Expense id is required.',
      '22023'
    );
  END IF;

  -- Load and lock the expense
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

  -- Creator-only
  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can cancel this expense.',
      '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  -- Idempotent: already cancelled? just return
  IF v_expense.status = 'cancelled' THEN
    RETURN v_expense;
  END IF;

  -- Only draft/active can be cancelled (you can tighten this if you add more statuses later)
  IF v_expense.status NOT IN ('draft', 'active') THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Only draft or active expenses can be cancelled.',
      'P0003'
    );
  END IF;

  -- Membership + home state
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

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_expense.home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  -- Lock splits rowset to avoid races with mark_share_paid
  PERFORM 1
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id
  FOR UPDATE;

  -- Check whether any share is already paid
  SELECT EXISTS (
    SELECT 1
    FROM public.expense_splits s
    WHERE s.expense_id = v_expense.id
      AND s.status     = 'paid'
      AND s.debtor_user_id <> v_expense.created_by_user_id
  )
  INTO v_has_paid;

  IF v_has_paid THEN
    PERFORM public.api_error(
      'EXPENSE_LOCKED_AFTER_PAYMENT',
      'Expenses with paid shares cannot be cancelled.',
      'P0004',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  -- Perform cancel: keep splits for audit, just change expense status
  UPDATE public.expenses
  SET status     = 'cancelled',
      updated_at = now()
  WHERE id = v_expense.id
  RETURNING * INTO v_expense;

  RETURN v_expense;
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

  -- Enforce home is active (mirror other expenses RPCs)
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
      a.storage_path                 AS payer_avatar_url,
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
      ON a.id = p.avatar_id
    WHERE e.home_id        = p_home_id
      AND e.status         = 'active'
      AND s.debtor_user_id = v_user
      AND s.status         = 'unpaid'
    GROUP BY e.created_by_user_id, payer_display, payer_avatar_url
  ) owed;

  RETURN v_result;
END;
$$;

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

  -- Build list of live expenses created by the current user
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
             ORDER BY e.created_at DESC, e.id
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
        AND s.debtor_user_id <> e.created_by_user_id
    ) stats ON TRUE
  WHERE e.home_id            = p_home_id
    AND e.created_by_user_id = v_user
    AND e.status IN ('draft', 'active');

  RETURN v_result;
END;
$$;


-- =====================================================================
--  Helper: _expenses_prepare_split_buffer
-- =====================================================================

CREATE OR REPLACE FUNCTION public._expenses_prepare_split_buffer(
  p_home_id      uuid,
  p_creator_id   uuid,
  p_amount_cents bigint,
  p_split_mode   public.expense_split_type,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_split_count         integer;
  v_split_sum           bigint;
  v_member_count        integer;
  v_non_creator_members integer;
BEGIN
  IF p_split_mode IS NULL THEN
    PERFORM public.api_error(
      'INVALID_SPLIT',
      'Split mode is required to build splits.',
      '22023'
    );
  END IF;

  -- Temp buffer for splits
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expense_split_buffer (
    debtor_user_id uuid,
    amount_cents   bigint
  ) ON COMMIT DROP;

  TRUNCATE pg_temp.expense_split_buffer;

  -- Build buffer from equal/custom
  IF p_split_mode = 'equal' THEN
    IF p_member_ids IS NULL OR array_length(p_member_ids, 1) IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Provide at least one member for an equal split.',
        '22023'
      );
    END IF;

    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT
      member_id,
      (p_amount_cents / total_count)
        + CASE WHEN row_number = total_count
               THEN p_amount_cents % total_count
               ELSE 0
          END AS share
    FROM (
      SELECT member_id,
             ord_position,
             ROW_NUMBER() OVER (ORDER BY ord_position) AS row_number,
             COUNT(*) OVER () AS total_count
      FROM (
        -- Deduplicate member IDs while preserving original order
        SELECT member_id, ord_position
        FROM (
          SELECT raw.member_id,
                 raw.ord_position,
                 ROW_NUMBER() OVER (
                   PARTITION BY raw.member_id
                   ORDER BY raw.ord_position
                 ) AS dup_rank
          FROM unnest(p_member_ids)
            WITH ORDINALITY AS raw(member_id, ord_position)
          WHERE raw.member_id IS NOT NULL
        ) filtered
        WHERE dup_rank = 1
      ) deduped
    ) ordered;

  ELSIF p_split_mode = 'custom' THEN
    IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
      PERFORM public.api_error(
        'INVALID_SPLIT',
        'p_splits must be a JSON array.',
        '22023'
      );
    END IF;

    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT user_id, amount_cents
    FROM jsonb_to_recordset(p_splits) AS x(user_id uuid, amount_cents bigint);
  ELSE
    PERFORM public.api_error('INVALID_SPLIT', 'Unknown split type.', '22023');
  END IF;

  -- Validations
  SELECT COUNT(*) INTO v_split_count
  FROM pg_temp.expense_split_buffer;

  IF v_split_count < 2 THEN
    PERFORM public.api_error(
      'SPLIT_MEMBERS_REQUIRED',
      'Include at least two members in the split.',
      '22023'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.expense_split_buffer
    WHERE debtor_user_id IS NULL
       OR amount_cents   IS NULL
       OR amount_cents  <= 0
  ) THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Each split requires a member and positive amount.',
      '22023'
    );
  END IF;

  -- Each debtor appears only once
  SELECT COUNT(DISTINCT debtor_user_id)
  INTO v_member_count
  FROM pg_temp.expense_split_buffer;

  IF v_member_count <> v_split_count THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Each debtor must appear only once.',
      '22023'
    );
  END IF;

  -- Sum must match for custom
  SELECT SUM(amount_cents)
  INTO v_split_sum
  FROM pg_temp.expense_split_buffer;

  IF p_split_mode = 'custom' AND v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error(
      'SPLIT_SUM_MISMATCH',
      'Custom splits must add up to the total amount.',
      '22023',
      jsonb_build_object('amount', p_amount_cents, 'splitSum', v_split_sum)
    );
  END IF;

  -- At least one non-creator debtor must be present for activated expenses
  SELECT COUNT(*)
  INTO v_non_creator_members
  FROM pg_temp.expense_split_buffer
  WHERE debtor_user_id <> p_creator_id;

  IF v_non_creator_members = 0 THEN
    PERFORM public.api_error(
      'SPLIT_MEMBERS_REQUIRED',
      'Include at least one other member in the split.',
      '22023'
    );
  END IF;

  -- All debtors must be active members of this home
  SELECT COUNT(*)
  INTO v_member_count
  FROM pg_temp.expense_split_buffer s
  JOIN public.memberships m
    ON m.home_id    = p_home_id
   AND m.user_id    = s.debtor_user_id
   AND m.is_current = TRUE;

  IF v_member_count <> v_split_count THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'All debtors must be active members of this home.',
      '42501'
    );
  END IF;
END;
$$;


-- =====================================================================
--  RPC: expenses_create
-- =====================================================================

CREATE OR REPLACE FUNCTION public.expenses_create(
  p_home_id      uuid,
  p_amount_cents bigint,
  p_description  text,
  p_notes        text DEFAULT NULL,
  p_split_mode   public.expense_split_type DEFAULT NULL,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid := p_home_id;
  v_home_is_active boolean;
  v_result         public.expenses%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  -- Must be logged in
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  -- Basic required inputs
  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_amount_cents IS NULL
     OR p_amount_cents <= 0
     OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      format('Amount must be between 1 and %s cents.', v_amount_cap),
      '22023'
    );
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  -- Decide if this is DRAFT or ACTIVE
  IF p_split_mode IS NULL THEN
    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;
  ELSE
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;
  END IF;

  -- Membership + home state
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- Prepare splits if ACTIVE
  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );
  END IF;

  -- Persist NEW expense
  INSERT INTO public.expenses (
    home_id,
    created_by_user_id,
    status,
    split_type,
    amount_cents,
    description,
    notes
  )
  VALUES (
    v_home_id,
    v_user,
    v_new_status,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), '')
  )
  RETURNING * INTO v_result;

  -- Persist splits if ACTIVE
  IF v_has_splits THEN
    INSERT INTO public.expense_splits (
      expense_id,
      debtor_user_id,
      amount_cents,
      status,
      marked_paid_at
    )
    SELECT v_result.id,
           debtor_user_id,
           amount_cents,
           CASE
             WHEN debtor_user_id = v_user
               THEN 'paid'::public.expense_share_status
             ELSE 'unpaid'::public.expense_share_status
           END,
           CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;
  END IF;

  RETURN v_result;
END;
$$;


-- =====================================================================
--  RPC: expenses_edit
-- =====================================================================

CREATE OR REPLACE FUNCTION public.expenses_edit(
  p_expense_id   uuid,
  p_amount_cents bigint,
  p_description  text,
  p_notes        text DEFAULT NULL,
  p_split_mode   public.expense_split_type DEFAULT NULL,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid;
  v_home_is_active boolean;

  v_existing       public.expenses%ROWTYPE;
  v_result         public.expenses%ROWTYPE;

  v_has_paid       boolean := FALSE;
  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_should_replace boolean := FALSE;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  IF p_amount_cents IS NULL
     OR p_amount_cents <= 0
     OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      format('Amount must be between 1 and %s cents.', v_amount_cap),
      '22023'
    );
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  -- Load existing expense and lock it
  SELECT *
  INTO v_existing
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

  v_home_id := v_existing.home_id;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can modify this expense.',
      '42501'
    );
  END IF;

  IF v_existing.status = 'cancelled' THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Cancelled expenses cannot be edited.',
      'P0003'
    );
  END IF;

  -- Lock splits rowset for this expense to avoid races
  PERFORM 1
  FROM public.expense_splits s
  WHERE s.expense_id = v_existing.id
  FOR UPDATE;

  -- Check if any share is paid
  SELECT EXISTS (
    SELECT 1
    FROM public.expense_splits s
    WHERE s.expense_id = v_existing.id
      AND s.status     = 'paid'
      AND s.debtor_user_id <> v_existing.created_by_user_id
  )
  INTO v_has_paid;

  -- Determine new status + split_type
  IF v_existing.status = 'draft' THEN
    -- New rule: editing a draft MUST choose a split and becomes active
    IF p_split_mode IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_REQUIRED',
        'Draft edits must choose a split; editing will activate the expense.',
        '22023'
      );
    END IF;

    v_target_split   := p_split_mode;
    v_new_status     := 'active';
    v_should_replace := TRUE;

  ELSE
    -- Existing is active (cancelled already rejected)
    v_new_status := 'active';

    IF v_has_paid THEN
      -- Lock amount and split once any share is paid
      IF p_split_mode IS NOT NULL THEN
        PERFORM public.api_error(
          'EXPENSE_LOCKED_AFTER_PAYMENT',
          'Split settings cannot change after a payment.',
          'P0004'
        );
      END IF;

      IF p_amount_cents <> v_existing.amount_cents THEN
        PERFORM public.api_error(
          'EXPENSE_LOCKED_AFTER_PAYMENT',
          'Amount cannot change after a payment.',
          'P0004'
        );
      END IF;

      v_target_split   := v_existing.split_type;
      v_should_replace := FALSE;
    ELSE
      -- No paid shares yet on an active expense
      IF p_split_mode IS NULL THEN
        -- Keep current split_type
        IF p_amount_cents <> v_existing.amount_cents THEN
          PERFORM public.api_error(
            'SPLIT_REQUIRED',
            'Provide split details when changing the amount of an active expense.',
            '22023'
          );
        END IF;

        v_target_split   := v_existing.split_type;
        v_should_replace := FALSE;
      ELSE
        -- Update split_type and rebuild splits
        v_target_split   := p_split_mode;
        v_should_replace := TRUE;
      END IF;
    END IF;
  END IF;

  IF v_new_status = 'active' AND v_target_split IS NULL THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Active expenses must keep a split.',
      'P0003'
    );
  END IF;

  -- Membership + home state
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  -- Prepare split buffer if we need to rebuild splits
  IF v_should_replace THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );
  END IF;

  -- Persist UPDATE
  UPDATE public.expenses
  SET amount_cents = p_amount_cents,
      description  = btrim(p_description),
      notes        = NULLIF(btrim(p_notes), ''),
      status       = v_new_status,
      split_type   = v_target_split,
      updated_at   = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_result;

  -- Rebuild splits if required
  IF v_should_replace THEN
    DELETE FROM public.expense_splits
    WHERE expense_id = v_result.id;

    INSERT INTO public.expense_splits (
      expense_id,
      debtor_user_id,
      amount_cents,
      status,
      marked_paid_at
    )
    SELECT v_result.id,
           debtor_user_id,
           amount_cents,
           CASE
             WHEN debtor_user_id = v_user
               THEN 'paid'::public.expense_share_status
             ELSE 'unpaid'::public.expense_share_status
           END,
           CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;
  END IF;

  RETURN v_result;
END;
$$;


