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

  IF v_split_count = 0 THEN
    PERFORM public.api_error(
      'SPLIT_MEMBERS_REQUIRED',
      'Split members are required when defining an active expense.',
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
           'unpaid',
           NULL
    FROM pg_temp.expense_split_buffer
    WHERE debtor_user_id <> v_user;
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
           'unpaid',
           NULL
    FROM pg_temp.expense_split_buffer
    WHERE debtor_user_id <> v_user;
  END IF;

  RETURN v_result;
END;
$$;


