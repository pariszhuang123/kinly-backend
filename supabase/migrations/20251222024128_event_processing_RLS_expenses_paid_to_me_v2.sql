ALTER TABLE public.revenuecat_webhook_events
  DROP COLUMN IF EXISTS received_at;

ALTER TABLE public.revenuecat_webhook_events
  ALTER COLUMN environment SET DEFAULT 'unknown';

UPDATE public.revenuecat_webhook_events
SET environment = 'unknown'
WHERE environment IS NULL OR length(trim(environment)) = 0;

ALTER TABLE public.revenuecat_webhook_events
  ALTER COLUMN environment SET NOT NULL;


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
               'debtorAvatarUrl', debtor_avatar_url,
               'isOwner',        debtor_is_owner,
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
      a.storage_path                                        AS debtor_avatar_url,
      (h.owner_user_id = s.debtor_user_id)                  AS debtor_is_owner,
      SUM(s.amount_cents)                                   AS total_paid_cents,
      COUNT(*) FILTER (WHERE s.recipient_viewed_at IS NULL) AS unseen_count,
      MAX(s.marked_paid_at)                                 AS latest_paid_at
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.profiles p
      ON p.id = s.debtor_user_id
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    JOIN public.homes h
      ON h.id = e.home_id
    WHERE e.home_id            = p_home_id
      AND e.created_by_user_id = v_user
      AND s.status             = 'paid'
      AND s.marked_paid_at     IS NOT NULL
      AND s.recipient_viewed_at IS NULL
      AND s.debtor_user_id    <> e.created_by_user_id
    GROUP BY s.debtor_user_id, p.username, a.storage_path, h.owner_user_id
  ) debtors
  WHERE unseen_count > 0;

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
               'expenseId',       expense_id,
               'description',     description,
               'notes',           notes,
               'amountCents',     amount_cents,
               'markedPaidAt',    marked_paid_at,
               'debtorUsername',  debtor_username,
               'debtorAvatarUrl', debtor_avatar_url,
               'isOwner',         debtor_is_owner
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
      (h.owner_user_id = s.debtor_user_id)      AS debtor_is_owner
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

REVOKE ALL ON FUNCTION public.expenses_get_current_paid_to_me_by_debtor_details(uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_get_current_paid_to_me_by_debtor_details(uuid, uuid)
TO authenticated;

