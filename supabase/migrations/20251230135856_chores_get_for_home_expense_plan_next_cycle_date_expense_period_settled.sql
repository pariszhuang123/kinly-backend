CREATE OR REPLACE FUNCTION public.chores_get_for_home(
  p_home_id  uuid,
  p_chore_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chore     jsonb;
  v_assignees jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  -- _chores_base_for_home already checks membership + home_active

  -- 1️⃣ Chore + current assignee (if any), using helper for current_due_on
  SELECT jsonb_build_object(
           'id',                    base.id,
           'home_id',               base.home_id,
           'created_by_user_id',    base.created_by_user_id,
           'assignee_user_id',      base.assignee_user_id,
           'name',                  base.name,

           -- 🔎 This is where we send the computed “start date”
           -- Option A: keep key name `start_date` but change semantics:
           'start_date',            base.current_due_on,

           -- Option B (cleaner, if you can update the client): 
           -- 'current_due_on',       base.current_due_on,

           'recurrence',            c.recurrence,
           'recurrence_cursor',     c.recurrence_cursor,
           'expectation_photo_path',c.expectation_photo_path,
           'how_to_video_url',      c.how_to_video_url,
           'notes',                 c.notes,
           'state',                 base.state,
           'completed_at',          c.completed_at,
           'created_at',            base.created_at,
           'updated_at',            c.updated_at,
           'assignee',
             CASE
               WHEN base.assignee_user_id IS NULL THEN NULL
               ELSE jsonb_build_object(
                 'id',                 base.assignee_user_id,
                 'full_name',          base.assignee_full_name,
                 'avatar_storage_path',base.assignee_avatar_storage_path
               )
             END
         )
    INTO v_chore
    FROM public._chores_base_for_home(p_home_id) AS base
    JOIN public.chores c
      ON c.id = base.id
   WHERE base.id = p_chore_id;

  IF v_chore IS NULL THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found for this home.',
      '22023',
      jsonb_build_object('home_id', p_home_id, 'chore_id', p_chore_id)
    );
  END IF;

  -- 2️⃣ All potential assignees in this home (unchanged)
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'user_id',             m.user_id,
               'full_name',           p.full_name,
               'avatar_storage_path', a.storage_path
             )
             ORDER BY p.full_name
           ),
           '[]'::jsonb
         )
    INTO v_assignees
    FROM public.memberships m
    JOIN public.profiles p
      ON p.id = m.user_id
    JOIN public.avatars a
      ON a.id = p.avatar_id
   WHERE m.home_id   = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'chore',     v_chore,
    'assignees', v_assignees
  );
END;
$$;


CREATE OR REPLACE FUNCTION public._expense_plan_next_cycle_date(
  p_interval public.recurrence_interval,
  p_from     date
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = ''
AS $$
BEGIN
  CASE p_interval
    WHEN 'weekly' THEN
      RETURN (p_from + 7)::date;
    WHEN 'every_2_weeks' THEN
      RETURN (p_from + 14)::date;
    WHEN 'monthly' THEN
      RETURN (p_from + INTERVAL '1 month')::date;
    WHEN 'every_2_months' THEN
      RETURN (p_from + INTERVAL '2 months')::date;
    WHEN 'annual' THEN
      RETURN (p_from + INTERVAL '1 year')::date;
    ELSE
      RAISE EXCEPTION
        'Recurrence interval % not supported for expense plans.',
        p_interval
        USING ERRCODE = '22023';
  END CASE;
END;
$$;

-- Adds recurrence metadata to share owed/paid detail payloads for period labels.

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

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

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
      a.storage_path                                AS payer_avatar_url,
      SUM(s.amount_cents)                           AS total_owed_cents,
      jsonb_agg(
        jsonb_build_object(
          'expenseId',          e.id,
          'description',        e.description,
          'amountCents',        s.amount_cents,
          'notes',              e.notes,
          'recurrenceInterval', e.recurrence_interval,
          'startDate',          e.start_date
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
               'expenseId',          expense_id,
               'description',        description,
               'notes',              notes,
               'amountCents',        amount_cents,
               'markedPaidAt',       marked_paid_at,
               'debtorUsername',     debtor_username,
               'debtorAvatarUrl',    debtor_avatar_url,
               'isOwner',            debtor_is_owner,
               'recurrenceInterval', recurrence_interval,
               'startDate',          start_date
             )
             ORDER BY marked_paid_at DESC, expense_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      e.id                                      AS expense_id,
      e.description                             AS description,
      e.notes                                   AS notes,
      s.amount_cents                            AS amount_cents,
      s.marked_paid_at                          AS marked_paid_at,
      p.username                                AS debtor_username,
      a.storage_path                            AS debtor_avatar_url,
      (h.owner_user_id = s.debtor_user_id)      AS debtor_is_owner,
      e.recurrence_interval                     AS recurrence_interval,
      e.start_date                              AS start_date
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.homes h
      ON h.id = e.home_id
    JOIN public.profiles p
      ON p.id = s.debtor_user_id
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE e.home_id            = p_home_id
      AND e.created_by_user_id = v_user
      AND s.debtor_user_id     = p_debtor_user_id
      AND s.status             = 'paid'
      AND s.marked_paid_at     IS NOT NULL
      AND s.recipient_viewed_at IS NULL
      AND s.debtor_user_id    <> e.created_by_user_id
  ) details;

  RETURN v_result;
END;
$$;
