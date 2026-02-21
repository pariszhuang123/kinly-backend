-- House Norms member review wiring:
-- - per-member view timestamps
-- - record view RPC
-- - member_viewed_at added to house_norms_get_for_home for non-owner callers

CREATE TABLE IF NOT EXISTS public.house_norms_member_views (
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  viewed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (home_id, user_id)
);

ALTER TABLE public.house_norms_member_views ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.house_norms_member_views FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.house_norms_get_for_home(
  p_home_id uuid,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms%ROWTYPE;
  v_requested_locale_base text;
  v_is_owner boolean := false;
  v_norms_change_at timestamptz := NULL;
  v_show_member_review_card boolean := false;
  v_show_publish_button boolean := false;
  v_show_republish_button boolean := false;
  v_show_public_url boolean := false;
  v_owner_meta jsonb := '{}'::jsonb;
  v_member_meta jsonb := '{}'::jsonb;
  v_member_viewed_at timestamptz := NULL;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  v_is_owner := public.is_home_owner(p_home_id, auth.uid());

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  v_requested_locale_base := lower(COALESCE(public.locale_base(p_locale), 'en'));

  PERFORM public.api_assert(
    v_requested_locale_base ~ '^[a-z]{2}$',
    'INVALID_LOCALE',
    'Locale base must be ISO 639-1 lowercase (e.g. en).',
    '22023',
    jsonb_build_object('locale_base', v_requested_locale_base)
  );

  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id;

  IF v_row.home_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'home_id', p_home_id,
      'requested_locale_base', v_requested_locale_base,
      'house_norms', NULL
    );
  END IF;

  IF v_is_owner THEN
    IF v_row.published_content IS NULL THEN
      v_show_publish_button := true;
      v_show_republish_button := false;
      v_show_public_url := false;
    ELSIF v_row.generated_content IS DISTINCT FROM v_row.published_content THEN
      v_show_publish_button := false;
      v_show_republish_button := true;
      v_show_public_url := true;
    ELSE
      v_show_publish_button := false;
      v_show_republish_button := false;
      v_show_public_url := true;
    END IF;

    v_owner_meta := jsonb_build_object(
      'home_public_id', v_row.home_public_id,
      'public_url',
        CASE
          WHEN v_row.home_public_id IS NULL THEN NULL
          ELSE public._house_norms_build_public_url(v_row.home_public_id::text)
        END,
      'show_publish_button', v_show_publish_button,
      'show_republish_button', v_show_republish_button,
      'show_public_url', v_show_public_url
    );
  ELSE
    SELECT mv.viewed_at
      INTO v_member_viewed_at
    FROM public.house_norms_member_views mv
    WHERE mv.home_id = p_home_id
      AND mv.user_id = auth.uid()
    LIMIT 1;

    v_norms_change_at := COALESCE(v_row.last_edited_at, v_row.generated_at);
    v_show_member_review_card := (
      v_norms_change_at IS NOT NULL
      AND now() >= (v_norms_change_at + interval '24 hours')
      AND (v_member_viewed_at IS NULL OR v_member_viewed_at < v_norms_change_at)
    );

    v_member_meta := jsonb_build_object(
      'member_viewed_at', v_member_viewed_at,
      'show_member_review_card', v_show_member_review_card
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'house_norms', jsonb_build_object(
      'template_key', v_row.template_key,
      'status', v_row.status,
      'inputs', v_row.inputs,
      -- Draft
      'draft_content', v_row.generated_content,
      'draft_updated_at', v_row.generated_at,
      -- Published snapshot (web/share)
      'published_content', v_row.published_content,
      'published_at', v_row.published_at,
      'published_version', v_row.published_version,
      'is_published', (v_row.published_content IS NOT NULL),
      'has_unpublished_changes',
        (v_row.published_content IS NULL OR v_row.generated_content IS DISTINCT FROM v_row.published_content),
      'show_member_review_card', false,
      'last_edited_at', v_row.last_edited_at,
      'last_edited_by', v_row.last_edited_by
    ) || v_owner_meta || v_member_meta
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.house_norms_record_view(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := now();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  INSERT INTO public.house_norms_member_views (
    home_id,
    user_id,
    viewed_at
  )
  VALUES (
    p_home_id,
    auth.uid(),
    v_now
  )
  ON CONFLICT (home_id, user_id) DO UPDATE
  SET viewed_at = EXCLUDED.viewed_at;

  RETURN jsonb_build_object(
    'ok', true,
    'viewed_at', v_now
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.house_norms_record_view(uuid) TO authenticated;


-- 
-- 3) Membership-change plan termination (no usage decrements)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._expense_plans_terminate_for_member_change(
  p_home_id uuid,
  p_affected_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.expense_plans ep
     SET status = 'terminated',
         terminated_at = now(),
         updated_at = now()
   WHERE ep.home_id = p_home_id
     AND ep.status = 'active'
     AND (
       ep.created_by_user_id = p_affected_user_id
       OR EXISTS (
         SELECT 1
           FROM public.expense_plan_debtors d
          WHERE d.plan_id = ep.id
            AND d.debtor_user_id = p_affected_user_id
       )
     );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_plans_terminate_for_member_change(uuid, uuid)
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9) pay-my-due: decrement active_expenses on first fully-paid
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_pay_my_due(
  p_recipient_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user                 uuid := auth.uid();
  v_split_count          integer := 0;
  v_expense_count        integer := 0;
  v_newly_fully_paid_cnt integer := 0;
  v_touched_count        integer := 0;
  v_newly_photo_cnt      integer := 0;
  r                      record;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_recipient_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_RECIPIENT',
      'Recipient (expense creator) is required.',
      '22023'
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expenses_touched (
    expense_id uuid PRIMARY KEY
  ) ON COMMIT DROP;
  TRUNCATE TABLE pg_temp.expenses_touched;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expenses_newly_paid (
    home_id uuid NOT NULL,
    expense_photo_dec integer NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  TRUNCATE TABLE pg_temp.expenses_newly_paid;

  WITH target_expenses AS (
    SELECT DISTINCT e.id, e.home_id
      FROM public.expense_splits s
      JOIN public.expenses e ON e.id = s.expense_id
      JOIN public.homes h ON h.id = e.home_id
      JOIN public.memberships m
        ON m.home_id    = e.home_id
       AND m.user_id    = v_user
       AND m.is_current = TRUE
       AND m.valid_to IS NULL
     WHERE s.debtor_user_id = v_user
       AND s.status = 'unpaid'
       AND e.status = 'active'
       AND e.created_by_user_id = p_recipient_user_id
       AND h.is_active = TRUE
  ),
  locked_homes AS (
    SELECT h.id
      FROM public.homes h
     WHERE h.id IN (SELECT home_id FROM target_expenses)
     ORDER BY h.id
     FOR UPDATE
  ),
  locked_expenses AS (
    SELECT e.id, e.home_id
      FROM public.expenses e
      JOIN locked_homes lh ON lh.id = e.home_id
      JOIN public.homes h ON h.id = e.home_id
     WHERE e.id IN (SELECT id FROM target_expenses)
       AND e.status = 'active'
       AND h.is_active = TRUE
     ORDER BY e.id
     FOR UPDATE
  ),
  updated AS (
    UPDATE public.expense_splits s
       SET status              = 'paid',
           marked_paid_at      = now(),
           recipient_viewed_at = NULL
     WHERE s.debtor_user_id = v_user
       AND s.expense_id IN (SELECT id FROM locked_expenses)
       AND s.status = 'unpaid'
    RETURNING s.expense_id
  ),
  aggregates AS (
    SELECT
      COUNT(*)::int AS split_count,
      COUNT(DISTINCT expense_id)::int AS expense_count
    FROM updated
  ),
  inserted AS (
    INSERT INTO pg_temp.expenses_touched (expense_id)
    SELECT DISTINCT expense_id FROM updated
    RETURNING 1
  )
  SELECT
    COALESCE(a.split_count, 0),
    COALESCE(a.expense_count, 0),
    COALESCE((SELECT COUNT(*) FROM inserted), 0)
  INTO
    v_split_count,
    v_expense_count,
    v_touched_count
  FROM aggregates a;

  WITH newly_paid AS (
    UPDATE public.expenses e
       SET fully_paid_at = now()
     WHERE e.id IN (SELECT expense_id FROM pg_temp.expenses_touched)
       AND e.fully_paid_at IS NULL
       AND NOT EXISTS (
         SELECT 1
           FROM public.expense_splits s
          WHERE s.expense_id = e.id
            AND s.status = 'unpaid'
       )
    RETURNING
      e.home_id,
      0 AS expense_photo_dec
  )
  INSERT INTO pg_temp.expenses_newly_paid (home_id, expense_photo_dec)
  SELECT home_id, expense_photo_dec FROM newly_paid;

  SELECT
    COUNT(*)::int,
    COALESCE(SUM(expense_photo_dec), 0)::int
    INTO v_newly_fully_paid_cnt, v_newly_photo_cnt
    FROM pg_temp.expenses_newly_paid;

  FOR r IN
    SELECT
      home_id,
      COUNT(*)::int AS dec_count,
      COALESCE(SUM(expense_photo_dec), 0)::int AS dec_expense_photo_count
    FROM pg_temp.expenses_newly_paid
    GROUP BY home_id
  LOOP
    PERFORM public._home_usage_apply_delta(
      r.home_id,
      jsonb_build_object(
        'active_expenses', -r.dec_count
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'recipientUserId',          p_recipient_user_id,
    'splitsPaid',               v_split_count,
    'expensesTouched',          v_expense_count,
    'expensesNewlyFullyPaid',   v_newly_fully_paid_cnt,
    'expensePhotosFreed',       v_newly_photo_cnt
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_pay_my_due(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_pay_my_due(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 10) plan terminate (no usage decrements)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expense_plans_terminate(
  p_plan_id uuid
)
RETURNS public.expense_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user  uuid := auth.uid();
  v_plan  public.expense_plans%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_plan_id IS NULL THEN
    PERFORM public.api_error('INVALID_PLAN', 'Plan id is required.', '22023');
  END IF;

  SELECT *
    INTO v_plan
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense plan not found.',
      'P0002',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  IF v_plan.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the plan creator can terminate this plan.',
      '42501'
    );
  END IF;

  PERFORM public._assert_home_member(v_plan.home_id);
  PERFORM public._assert_home_active(v_plan.home_id);

  IF v_plan.status = 'terminated' THEN
    RETURN v_plan;
  END IF;

  UPDATE public.expense_plans
     SET status        = 'terminated',
         terminated_at = now(),
         updated_at    = now()
   WHERE id = p_plan_id
  RETURNING * INTO v_plan;

  RETURN v_plan;
END;
$$;

REVOKE ALL ON FUNCTION public.expense_plans_terminate(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expense_plans_terminate(uuid)
TO authenticated;

-- ---------------------------------------------------------------------
-- 11) cancel: free active_expenses only for active rows
-- ---------------------------------------------------------------------
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
  v_was_active     boolean := FALSE;
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

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can cancel this expense.',
      '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_expense.status = 'cancelled' THEN
    RETURN v_expense;
  END IF;

  IF v_expense.status NOT IN ('draft', 'active') THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Only draft or active expenses can be cancelled.',
      'P0003'
    );
  END IF;

  v_was_active := (v_expense.status = 'active');

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

  PERFORM 1
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id
  FOR UPDATE;

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

  UPDATE public.expenses
  SET status     = 'cancelled',
      updated_at = now()
  WHERE id = v_expense.id
  RETURNING * INTO v_expense;

  IF v_was_active THEN
    PERFORM public._home_usage_apply_delta(
      v_expense.home_id,
      jsonb_build_object('active_expenses', -1)
    );
  END IF;

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_cancel(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_cancel(uuid)
TO authenticated;



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
    p_name => 'Take out trash',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week',
    p_how_to_video_url => 'https://www.youtube.com/shorts/tF_smwdwzMk',
    p_expectation_photo_path => 'flow/expectations/1771359335379-pc7yvv_template.jpg',
    p_notes => 'Don''t forget to throw the rubbish, or else need to wait for a month!!'
  );
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
  -- 6) Seed starter draft bill templates
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Internet bills'
  );
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Electric bills'
  );
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Water bills'
  );
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Rent'
  );
  PERFORM public.shopping_list_add_item(
    p_home_id => v_home.id,
    p_name => 'Toilet paper',
    p_quantity => '1',
    p_details => 'Get the 3-ply one for extra comfort!', 
    p_reference_photo_path => 'households/shopping/item/1771297308238-ecgval_template.jpg'
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

