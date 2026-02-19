
-- =====================================================================
-- _expenses_prepare_split_buffer (>=1 non-creator debtor invariant)
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
  v_split_count         integer := 0;
  v_split_sum           bigint  := 0;
  v_distinct_count      integer := 0;
  v_non_creator_members integer := 0;
  v_member_match_count  integer := 0;

  v_total_count         integer := 0;
  v_equal_share         bigint  := 0;
  v_remainder           bigint  := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_creator_id IS NULL THEN
    PERFORM public.api_error('INVALID_CREATOR', 'Creator id is required.', '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLIT', 'Split mode is required to build splits.', '22023');
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      'Amount must be a positive integer.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents)
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expense_split_buffer (
    debtor_user_id uuid NOT NULL,
    amount_cents   bigint NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE TABLE pg_temp.expense_split_buffer;

  IF p_split_mode = 'equal' THEN
    IF p_member_ids IS NULL OR array_length(p_member_ids, 1) IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Provide at least one member for an equal split.',
        '22023'
      );
    END IF;

    WITH ordered AS (
      SELECT
        member_id,
        ROW_NUMBER() OVER (ORDER BY ord_position) AS rn,
        COUNT(*) OVER () AS total_count
      FROM (
        SELECT DISTINCT ON (raw.member_id)
               raw.member_id,
               raw.ord_position
        FROM unnest(p_member_ids)
          WITH ORDINALITY AS raw(member_id, ord_position)
        WHERE raw.member_id IS NOT NULL
        ORDER BY raw.member_id, raw.ord_position
      ) deduped
    )
    SELECT COALESCE(MAX(total_count), 0)
      INTO v_total_count
      FROM ordered;

    IF v_total_count < 1 THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Include at least one member in the split.',
        '22023'
      );
    END IF;

    v_equal_share := p_amount_cents / v_total_count;
    v_remainder   := p_amount_cents % v_total_count;

    WITH ordered AS (
      SELECT
        member_id,
        ROW_NUMBER() OVER (ORDER BY ord_position) AS rn
      FROM (
        SELECT DISTINCT ON (raw.member_id)
               raw.member_id,
               raw.ord_position
        FROM unnest(p_member_ids)
          WITH ORDINALITY AS raw(member_id, ord_position)
        WHERE raw.member_id IS NOT NULL
        ORDER BY raw.member_id, raw.ord_position
      ) deduped
    )
    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT
      member_id,
      v_equal_share + CASE WHEN rn = v_total_count THEN v_remainder ELSE 0 END
    FROM ordered
    ORDER BY rn;

  ELSIF p_split_mode = 'custom' THEN
    IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
      PERFORM public.api_error('INVALID_SPLIT', 'p_splits must be a JSON array.', '22023');
    END IF;

    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT x.user_id, x.amount_cents
    FROM jsonb_to_recordset(p_splits) AS x(user_id uuid, amount_cents bigint);

  ELSE
    PERFORM public.api_error('INVALID_SPLIT', 'Unknown split type.', '22023');
  END IF;

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COUNT(DISTINCT debtor_user_id)::int
    INTO v_split_count, v_split_sum, v_distinct_count
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 1 THEN
    PERFORM public.api_error('SPLIT_MEMBERS_REQUIRED', 'Include at least one member in the split.', '22023');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.expense_split_buffer
    WHERE debtor_user_id IS NULL
       OR amount_cents   IS NULL
       OR amount_cents  <= 0
  ) THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'Each split requires a member and a positive amount.', '22023');
  END IF;

  IF v_distinct_count <> v_split_count THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'Each debtor must appear only once.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error(
      'SPLIT_SUM_MISMATCH',
      'Split amounts must add up to the total amount.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  SELECT COUNT(*)::int
    INTO v_non_creator_members
    FROM pg_temp.expense_split_buffer
   WHERE debtor_user_id <> p_creator_id;

  IF v_non_creator_members = 0 THEN
    PERFORM public.api_error('SPLIT_MEMBERS_REQUIRED', 'Include at least one other member in the split.', '22023');
  END IF;

  SELECT COUNT(*)::int
    INTO v_member_match_count
    FROM pg_temp.expense_split_buffer s
    JOIN public.memberships m
      ON m.home_id    = p_home_id
     AND m.user_id    = s.debtor_user_id
     AND m.is_current = TRUE
     AND m.valid_to IS NULL;

  IF v_member_match_count <> v_split_count THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'All debtors must be current members of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;
END;
$$;

-- =====================================================================
-- expenses_create_v2 (>=1 non-creator debtor invariant)
-- =====================================================================
CREATE OR REPLACE FUNCTION public.expenses_create_v2(
  p_home_id          uuid,
  p_description      text,
  p_amount_cents     bigint DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_split_mode       public.expense_split_type DEFAULT NULL,
  p_member_ids       uuid[] DEFAULT NULL,
  p_splits           jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit  text DEFAULT NULL,
  p_start_date       date DEFAULT current_date
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
  v_plan           public.expense_plans%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;
  v_is_recurring   boolean := FALSE;

  v_recur_every    integer := p_recurrence_every;
  v_recur_unit     text := p_recurrence_unit;

  v_split_count    integer := 0;
  v_split_sum      bigint  := 0;
  v_split_min      bigint  := 0;

  v_join_date      date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_start_date IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  v_is_recurring := p_recurrence_every IS NOT NULL;

  IF v_is_recurring THEN
    IF p_recurrence_every < 1 THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence every must be >= 1.',
        '22023'
      );
    END IF;

    IF p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence unit must be day, week, month, or year.',
        '22023'
      );
    END IF;
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

  -- Draft vs active based on splits presence (p_split_mode)
  IF p_split_mode IS NULL THEN
    -- Draft
    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    -- Draft may optionally include amount, but if present must be valid.
    IF p_amount_cents IS NOT NULL THEN
      IF p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
        PERFORM public.api_error(
          'INVALID_AMOUNT',
          format('Amount must be between 1 and %s cents when provided.', v_amount_cap),
          '22023',
          jsonb_build_object('amountCents', p_amount_cents)
        );
      END IF;
    END IF;

    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;
  ELSE
    -- Activating (one-off active) OR recurring activation (plan + first cycle)
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;

    IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023'
      );
    END IF;
  END IF;

  -- Membership join date for start_date validation
  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a current member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id, 'userId', v_user)
    );
  END IF;

  IF p_start_date < v_join_date OR p_start_date < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  p_start_date
      )
    );
  END IF;

  -- Lock home (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- If activating (splits present), build/validate split buffer (also validates members + sums)
  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );

    SELECT COUNT(*)::int,
           COALESCE(SUM(amount_cents), 0),
           COALESCE(MIN(amount_cents), 0)
      INTO v_split_count, v_split_sum, v_split_min
      FROM pg_temp.expense_split_buffer;

    IF v_split_count < 1 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
    END IF;

    IF v_split_min <= 0 THEN
      PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
    END IF;

    IF v_split_sum <> p_amount_cents THEN
      PERFORM public.api_error(
        'INVALID_SPLITS_SUM',
        'Split amounts must sum to the expense amount.',
        '22023',
        jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
      );
    END IF;
  END IF;
  -- One-off path (non-recurring)
  IF NOT v_is_recurring THEN
    -- Paywall only if we are creating an ACTIVE expense (splits present)
    IF v_new_status = 'active' THEN
      PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_home_id,
      v_user,
      v_new_status,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    -- Create splits only for active
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
             CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
                  ELSE 'unpaid'::public.expense_share_status
             END,
             CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
        FROM pg_temp.expense_split_buffer;
    END IF;

    -- Usage only for active
    IF v_new_status = 'active' THEN
      PERFORM public._home_usage_apply_delta(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    RETURN v_result;
  END IF;

  -- Recurring activation path (user-generated): enforce quota for FIRST cycle intent
  -- (cron later ignores quota by design)
  PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    split_type,
    amount_cents,
    description,
    notes,
    recurrence_every,
    recurrence_unit,
    start_date,
    next_cycle_date,
    status
  )
  VALUES (
    v_home_id,
    v_user,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), ''),
    v_recur_every,
    v_recur_unit,
    p_start_date,
    public._expense_plan_next_cycle_date_v2(v_recur_every, v_recur_unit, p_start_date),
    'active'
  )
  RETURNING * INTO v_plan;

  INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
  SELECT v_plan.id, debtor_user_id, amount_cents
    FROM pg_temp.expense_split_buffer;

  -- First cycle creation increments usage inside _expense_plan_generate_cycle (canonical)
  v_result := public._expense_plan_generate_cycle(v_plan.id, p_start_date);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create_v2(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_create_v2(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) TO authenticated;

-- =====================================================================
-- expenses_edit_v2
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_edit_v2(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date
);

CREATE OR REPLACE FUNCTION public.expenses_edit_v2(
  p_expense_id       uuid,
  p_amount_cents     bigint,
  p_description      text,
  p_notes            text DEFAULT NULL,
  p_split_mode       public.expense_split_type DEFAULT NULL,
  p_member_ids       uuid[] DEFAULT NULL,
  p_splits           jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit  text DEFAULT NULL,
  p_start_date       date DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user            uuid := auth.uid();

  v_existing_unsafe public.expenses%ROWTYPE;
  v_existing        public.expenses%ROWTYPE;

  v_result          public.expenses%ROWTYPE;
  v_plan            public.expense_plans%ROWTYPE;

  v_home_is_active  boolean;

  v_target_split       public.expense_split_type;
  v_target_recur_every integer;
  v_target_recur_unit  text;
  v_target_start       date;
  v_is_recurring       boolean := FALSE;

  v_split_count     integer := 0;
  v_split_sum       bigint  := 0;
  v_split_min       bigint  := 0;

  v_join_date       date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  SELECT *
    INTO v_existing_unsafe
    FROM public.expenses e
   WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  -- Lock home first (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_existing_unsafe.home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_existing_unsafe.home_id));
  END IF;

  -- Lock expense row next (homes -> expenses)
  SELECT *
    INTO v_existing
    FROM public.expenses e
   WHERE e.id = p_expense_id
   FOR UPDATE;

  IF v_existing.home_id <> v_existing_unsafe.home_id THEN
    PERFORM public.api_error('CONCURRENT_MODIFICATION', 'Expense changed while editing. Please retry.', '40001', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_existing.home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error('NOT_HOME_MEMBER', 'You are not a current member of this home.', '42501',
      jsonb_build_object('homeId', v_existing.home_id, 'userId', v_user)
    );
  END IF;

  IF v_existing.plan_id IS NOT NULL THEN
    PERFORM public.api_error('IMMUTABLE_CYCLE', 'Expenses generated from a recurring plan cannot be edited.', '42501');
  END IF;

  IF v_existing.status = 'active' THEN
    IF v_existing.created_by_user_id <> v_user THEN
      PERFORM public.api_error(
        'NOT_CREATOR',
        'Only the creator can edit this active expense.',
        '42501'
      );
    END IF;

    IF p_amount_cents IS DISTINCT FROM v_existing.amount_cents THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Amount is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'amountCents', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_split_mode IS NOT NULL AND p_split_mode IS DISTINCT FROM v_existing.split_type THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Split mode is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'splitMode', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_member_ids IS NOT NULL OR p_splits IS NOT NULL THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Splits are immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'splits', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_recurrence_every IS NOT NULL OR p_recurrence_unit IS NOT NULL THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Recurrence is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'recurrence', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_start_date IS NOT NULL AND p_start_date IS DISTINCT FROM v_existing.start_date THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Start date is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'startDate', 'expenseId', v_existing.id)
      );
    END IF;

    IF btrim(COALESCE(p_description, '')) = '' THEN
      PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
    END IF;

    IF char_length(btrim(p_description)) > v_desc_max THEN
      PERFORM public.api_error('INVALID_DESCRIPTION', format('Description must be %s characters or fewer.', v_desc_max), '22023');
    END IF;

    IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
      PERFORM public.api_error('INVALID_NOTES', format('Notes must be %s characters or fewer.', v_notes_max), '22023');
    END IF;

    UPDATE public.expenses
       SET description = btrim(p_description),
           notes = NULLIF(btrim(p_notes), ''),
           updated_at = now()
     WHERE id = v_existing.id
     RETURNING * INTO v_result;

    RETURN v_result;
  END IF;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can modify this expense.', '42501');
  END IF;

  IF v_existing.status <> 'draft' THEN
    PERFORM public.api_error('INVALID_STATE', 'Only draft expenses can be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  -- Draft editing path always activates and requires full payload.
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error('INVALID_AMOUNT', format('Amount must be between 1 and %s cents.', v_amount_cap), '22023');
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', format('Description must be %s characters or fewer.', v_desc_max), '22023');
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error('INVALID_NOTES', format('Notes must be %s characters or fewer.', v_notes_max), '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Splits are required. Editing an expense always activates it.', '22023');
  END IF;

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  v_target_split := p_split_mode;
  v_target_recur_every := p_recurrence_every;
  v_target_recur_unit := p_recurrence_unit;
  v_is_recurring := v_target_recur_every IS NOT NULL;

  IF v_is_recurring THEN
    IF v_target_recur_every < 1 THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence every must be >= 1.',
        '22023'
      );
    END IF;

    IF v_target_recur_unit NOT IN ('day', 'week', 'month', 'year') THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence unit must be day, week, month, or year.',
        '22023'
      );
    END IF;
  END IF;

  v_target_start := COALESCE(p_start_date, v_existing.start_date);

  IF v_target_start IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF v_target_start < v_join_date OR v_target_start < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  v_target_start
      )
    );
  END IF;

  -- Build splits (this truncates pg_temp buffer itself)
  PERFORM public._expenses_prepare_split_buffer(
    v_existing.home_id,
    v_user,
    p_amount_cents,
    v_target_split,
    p_member_ids,
    p_splits
  );

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COALESCE(MIN(amount_cents), 0)
    INTO v_split_count, v_split_sum, v_split_min
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 1 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
  END IF;

  IF v_split_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error('INVALID_SPLITS_SUM', 'Split amounts must sum to the expense amount.', '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  -- Lock order convention: expense already locked; now safe to mutate splits
  DELETE FROM public.expense_splits s
   WHERE s.expense_id = v_existing.id;
  IF v_is_recurring THEN
    -- User-generated recurring activation consumes quota for the first cycle intent
    PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

    INSERT INTO public.expense_plans (
      home_id,
      created_by_user_id,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_every,
      recurrence_unit,
      start_date,
      next_cycle_date,
      status
    )
    VALUES (
      v_existing.home_id,
      v_user,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_target_recur_every,
      v_target_recur_unit,
      v_target_start,
      public._expense_plan_next_cycle_date_v2(v_target_recur_every, v_target_recur_unit, v_target_start),
      'active'
    )
    RETURNING * INTO v_plan;

    INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
    SELECT v_plan.id, debtor_user_id, amount_cents
      FROM pg_temp.expense_split_buffer;

    -- Mark original draft as converted; do NOT increment usage here
    UPDATE public.expenses
       SET status           = 'converted',
           plan_id          = v_plan.id,
           recurrence_every = v_target_recur_every,
           recurrence_unit  = v_target_recur_unit,
           start_date       = v_target_start,
           updated_at       = now()
     WHERE id = v_existing.id;

    -- First cycle creation increments usage inside _expense_plan_generate_cycle
    v_result := public._expense_plan_generate_cycle(v_plan.id, v_target_start);
    RETURN v_result;
  END IF;

  -- One-off activation path
  PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  UPDATE public.expenses
     SET status           = 'active',
         split_type       = v_target_split,
         amount_cents     = p_amount_cents,
         description      = btrim(p_description),
         notes            = NULLIF(btrim(p_notes), ''),
         recurrence_every = NULL,
         recurrence_unit  = NULL,
         start_date       = v_target_start,
         updated_at       = now()
   WHERE id = v_existing.id
   RETURNING * INTO v_result;

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
         CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
              ELSE 'unpaid'::public.expense_share_status
         END,
         CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;

  PERFORM public._home_usage_apply_delta(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_edit_v2(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_edit_v2(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) TO authenticated;