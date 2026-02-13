-- Language-neutral, accent-insensitive ICU collation for stable multilingual ordering.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_collation
    WHERE collname = 'kinly_und_ai'
      AND collnamespace = 'public'::regnamespace
  ) THEN
    CREATE COLLATION public.kinly_und_ai (
      provider = icu,
      locale = 'und-u-ks-level1',
      deterministic = false
    );
  END IF;
END
$$;


CREATE OR REPLACE FUNCTION public.shopping_list_get_for_home(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_list public.shopping_lists;
  v_items jsonb;

  v_unarchived_count int := 0;
  v_uncompleted_count int := 0;

  v_list_json jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT *
  INTO v_list
  FROM public.shopping_lists sl
  WHERE sl.home_id = p_home_id
    AND sl.is_active = TRUE
  LIMIT 1;

  IF v_list.id IS NULL THEN
    v_list_json := jsonb_build_object(
      'id', NULL,
      'home_id', p_home_id,
      'created_by_user_id', NULL,
      'is_active', TRUE,
      'created_at', NULL,
      'updated_at', NULL,
      'items_unarchived_count', 0,
      'items_uncompleted_count', 0
    );

    RETURN jsonb_build_object(
      'list', v_list_json,
      'items', '[]'::jsonb
    );
  END IF;

  SELECT
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', i.id,
          'shopping_list_id', i.shopping_list_id,
          'home_id', i.home_id,
          'created_by_user_id', i.created_by_user_id,
          'name', i.name,
          'quantity', i.quantity,
          'details', i.details,
          'is_completed', (i.is_completed = TRUE AND i.completed_by_user_id = v_user),
          'completed_by_user_id', CASE WHEN i.completed_by_user_id = v_user THEN i.completed_by_user_id ELSE NULL END,
          'completed_by_avatar_id', CASE WHEN i.completed_by_user_id = v_user THEN p.avatar_id ELSE NULL END,
          'completed_at', CASE WHEN i.completed_by_user_id = v_user THEN i.completed_at ELSE NULL END,
          'reference_photo_path', i.reference_photo_path,
          'reference_added_by_user_id', i.reference_added_by_user_id,
          'linked_expense_id', i.linked_expense_id,
          'archived_at', i.archived_at,
          'archived_by_user_id', i.archived_by_user_id,
          'created_at', i.created_at,
          'updated_at', i.updated_at
        )
        ORDER BY
          lower(regexp_replace(btrim(i.name), '\s+', ' ', 'g')) COLLATE public.kinly_und_ai ASC,
          i.name COLLATE public.kinly_und_ai ASC,
          i.created_at DESC
      ),
      '[]'::jsonb
    ) AS items_json,
    COUNT(*)::int AS unarchived_count
  INTO v_items, v_unarchived_count
  FROM public.shopping_list_items i
  LEFT JOIN public.profiles p
    ON p.id = i.completed_by_user_id
  WHERE i.shopping_list_id = v_list.id
    AND i.archived_at IS NULL
    AND (
      i.is_completed = FALSE
      OR i.completed_by_user_id = v_user
    );

  SELECT COUNT(*)::int
  INTO v_uncompleted_count
  FROM public.shopping_list_items i
  WHERE i.shopping_list_id = v_list.id
    AND i.archived_at IS NULL
    AND i.is_completed = FALSE;

  v_list_json :=
    to_jsonb(v_list)
    || jsonb_build_object(
      'items_unarchived_count', v_unarchived_count,
      'items_uncompleted_count', v_uncompleted_count
    );

  RETURN jsonb_build_object(
    'list', v_list_json,
    'items', v_items
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.mood_get_current_weekly(
  p_home_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id         uuid := auth.uid();
  v_iso_week        int;
  v_iso_week_year   int;
  v_exists          boolean;
  v_home_created_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT h.created_at
  INTO v_home_created_at
  FROM public.homes h
  WHERE h.id = p_home_id;

  -- During initial setup period, hide mood flow by returning TRUE.
  IF v_home_created_at > (timezone('UTC', now()) - interval '7 days') THEN
    RETURN true;
  END IF;

  SELECT extract('week' FROM timezone('UTC', now()))::int,
         extract('isoyear' FROM timezone('UTC', now()))::int
  INTO v_iso_week, v_iso_week_year;

  SELECT EXISTS (
    SELECT 1
    FROM public.home_mood_entries e
    WHERE e.user_id       = v_user_id
      AND e.iso_week_year = v_iso_week_year
      AND e.iso_week      = v_iso_week
  )
  INTO v_exists;

  RETURN v_exists;
END;
$$;

COMMENT ON FUNCTION public.mood_get_current_weekly(uuid) IS
  'Returns TRUE while home onboarding is active (home created less than 7 days ago). '
  'After 7 days, returns TRUE only if the user already submitted a mood entry for the current ISO week (in ANY home). '
  'The p_home_id parameter is used for membership/home-active checks and home age gating.';

CREATE OR REPLACE FUNCTION public.home_assignees_list_v2(p_home_id uuid)
RETURNS TABLE (
  user_id uuid,
  username text,
  full_name text,
  email text,
  avatar_storage_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  RETURN QUERY
  SELECT
    m.user_id,
    p.username::text,
    p.full_name,
    p.email,
    a.storage_path
  FROM public.memberships m
  JOIN public.profiles p ON p.id = m.user_id
  JOIN public.avatars a ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
  ORDER BY COALESCE(NULLIF(p.full_name, ''), NULLIF(p.username::text, ''), p.email, '');
END;
$$;

-- Seed starter draft chores on home creation.
-- Keeps homes.create payload unchanged; adds additive side-effect only.

CREATE OR REPLACE FUNCTION public.homes_create_with_invite()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home public.homes;
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- 1) Create home
  INSERT INTO public.homes (owner_user_id)
  VALUES (v_user)
  RETURNING * INTO v_home;

  -- 2) Create owner membership (first active member)
  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  -- 3) Increment usage counters: active_members +1
  PERFORM public._home_usage_apply_delta(
    v_home.id,
    jsonb_build_object('active_members', 1)
  );

  -- 4) Set entitlements (default: free)
  INSERT INTO public.home_entitlements (home_id, plan, expires_at)
  VALUES (v_home.id, 'free', NULL);

  -- 5) Seed starter draft chores for quick household setup (weekly recurrence)
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Clean kitchen',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Clean bathroom',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Vacuum common area',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Take out trash',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  -- 6) Seed starter draft bill templates
  PERFORM public.expenses_create_v2(
    p_home_id => v_home.id,
    p_description => 'Internet bills'
  );
  PERFORM public.expenses_create_v2(
    p_home_id => v_home.id,
    p_description => 'Electric bills'
  );
  PERFORM public.expenses_create_v2(
    p_home_id => v_home.id,
    p_description => 'Water bills'
  );
  PERFORM public.expenses_create_v2(
    p_home_id => v_home.id,
    p_description => 'Rent'
  );

  -- 7) Create first invite (one active per home enforced by partial index)
  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING * INTO v_inv;

  IF NOT FOUND THEN
    SELECT *
    INTO v_inv
    FROM public.invites
    WHERE home_id = v_home.id
      AND revoked_at IS NULL
    LIMIT 1;
  END IF;

  -- 8) Attach existing subscription to this home (if any)
  PERFORM public._home_attach_subscription_to_home(v_user, v_home.id);

  -- 9) Return result
  RETURN jsonb_build_object(
    'home', jsonb_build_object(
      'id',            v_home.id,
      'owner_user_id', v_home.owner_user_id,
      'created_at',    v_home.created_at
    ),
    'invite', jsonb_build_object(
      'id',         v_inv.id,
      'home_id',    v_inv.home_id,
      'code',       v_inv.code,
      'created_at', v_inv.created_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.homes_create_with_invite() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.homes_create_with_invite() TO authenticated;

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

  IF v_split_count < 2 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
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
-- =====================================================================
-- expenses_get_for_edit: include recurrence_every/unit
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_get_for_edit(uuid);

CREATE OR REPLACE FUNCTION public.expenses_get_for_edit(
  p_expense_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_expense            public.expenses%ROWTYPE;
  v_home_is_active     boolean;
  v_plan_status        public.expense_plan_status;
  v_splits             jsonb := '[]'::jsonb;
  v_can_edit           boolean := FALSE;
  v_edit_disabled      text := NULL;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  SELECT e.*
    INTO v_expense
    FROM public.expenses e
   WHERE e.id = p_expense_id
     AND EXISTS (
       SELECT 1
         FROM public.memberships m
        WHERE m.home_id    = e.home_id
          AND m.user_id    = v_user
          AND m.is_current = TRUE
          AND m.valid_to IS NULL
     );

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_expense.home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_expense.home_id));
  END IF;

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can edit this expense.', '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_expense.plan_id IS NOT NULL THEN
    SELECT ep.status
      INTO v_plan_status
      FROM public.expense_plans ep
     WHERE ep.id = v_expense.plan_id
     LIMIT 1;
  END IF;

  v_can_edit := (
    v_expense.status = 'draft'::public.expense_status
    OR (
      v_expense.status = 'active'::public.expense_status
      AND v_expense.plan_id IS NULL
    )
  );

  IF NOT v_can_edit THEN
    IF v_expense.plan_id IS NOT NULL THEN
      IF v_expense.status = 'converted'::public.expense_status THEN
        v_edit_disabled := 'CONVERTED_TO_PLAN';
      ELSE
        v_edit_disabled := 'RECURRING_CYCLE_IMMUTABLE';
      END IF;
    ELSE
      CASE v_expense.status
        WHEN 'active'::public.expense_status THEN v_edit_disabled := 'ACTIVE_IMMUTABLE';
        WHEN 'converted'::public.expense_status THEN v_edit_disabled := 'CONVERTED_TO_PLAN';
        ELSE v_edit_disabled := 'NOT_EDITABLE';
      END CASE;
    END IF;
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',    s.expense_id,
               'debtorUserId', s.debtor_user_id,
               'amountCents',  s.amount_cents,
               'status',       s.status,
               'markedPaidAt', s.marked_paid_at
             )
             ORDER BY s.debtor_user_id
           ),
           '[]'::jsonb
         )
    INTO v_splits
    FROM public.expense_splits s
   WHERE s.expense_id = v_expense.id;

  RETURN jsonb_build_object(
    'expenseId',          v_expense.id,
    'homeId',             v_expense.home_id,
    'createdByUserId',    v_expense.created_by_user_id,
    'status',             v_expense.status,
    'splitType',          v_expense.split_type,
    'amountCents',        v_expense.amount_cents,
    'description',        v_expense.description,
    'notes',              v_expense.notes,
    'createdAt',          v_expense.created_at,
    'updatedAt',          v_expense.updated_at,
    'planId',             v_expense.plan_id,
    'planStatus',         v_plan_status,
    'recurrenceEvery',    v_expense.recurrence_every,
    'recurrenceUnit',     v_expense.recurrence_unit,
    'startDate',          v_expense.start_date,
    'canEdit',            v_can_edit,
    'editDisabledReason', v_edit_disabled,
    'splits',             v_splits
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_for_edit(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_get_for_edit(uuid)
TO authenticated;
