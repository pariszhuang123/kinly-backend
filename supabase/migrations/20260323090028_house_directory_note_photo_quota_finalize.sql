-- House Directory note photo quota finalize
-- Split from 20260323090026 to avoid unsafe same-transaction enum usage.

INSERT INTO public.home_plan_limits (plan, metric, max_value)
VALUES ('free', 'house_directory_note_photos', 10)
ON CONFLICT (plan, metric) DO UPDATE
SET max_value = EXCLUDED.max_value;

CREATE OR REPLACE FUNCTION public._home_assert_quota(
  p_home_id uuid,
  p_deltas  jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan       text;
  v_is_premium boolean;
  v_counters   public.home_usage_counters%ROWTYPE;

  v_metric_key   text;
  v_metric_enum  public.home_usage_metric;
  v_raw_value    jsonb;
  v_delta        integer;
  v_current      integer;
  v_new          integer;
  v_max          integer;
BEGIN
  v_plan := public._home_effective_plan(p_home_id);

  v_is_premium := public._home_is_premium(p_home_id);
  IF v_is_premium THEN
    RETURN;
  END IF;

  IF p_deltas IS NULL OR jsonb_typeof(p_deltas) <> 'object' THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_counters
  FROM public.home_usage_counters
  WHERE home_id = p_home_id;

  IF NOT FOUND THEN
    v_counters.active_chores               := 0;
    v_counters.chore_photos                := 0;
    v_counters.active_members              := 0;
    v_counters.active_expenses             := 0;
    v_counters.shopping_item_photos        := 0;
    v_counters.expense_photos              := 0;
    v_counters.house_directory_note_photos := 0;
  END IF;

  FOR v_metric_key, v_raw_value IN
    SELECT key, value FROM jsonb_each(p_deltas)
  LOOP
    BEGIN
      v_metric_enum := v_metric_key::public.home_usage_metric;
    EXCEPTION WHEN invalid_text_representation THEN
      CONTINUE;
    END;

    IF jsonb_typeof(v_raw_value) <> 'number' THEN
      PERFORM public.api_error(
        'INVALID_QUOTA_DELTA',
        'Quota delta must be numeric.',
        '22023',
        jsonb_build_object('metric', v_metric_key, 'value', v_raw_value)
      );
    END IF;

    v_delta := (v_raw_value #>> '{}')::integer;
    IF COALESCE(v_delta, 0) <= 0 THEN
      CONTINUE;
    END IF;

    SELECT max_value
    INTO v_max
    FROM public.home_plan_limits
    WHERE plan = v_plan
      AND metric = v_metric_enum;

    IF v_max IS NULL THEN
      CONTINUE;
    END IF;

    v_current := CASE v_metric_enum
      WHEN 'active_chores'               THEN COALESCE(v_counters.active_chores, 0)
      WHEN 'chore_photos'                THEN COALESCE(v_counters.chore_photos, 0)
      WHEN 'active_members'              THEN COALESCE(v_counters.active_members, 0)
      WHEN 'active_expenses'             THEN COALESCE(v_counters.active_expenses, 0)
      WHEN 'shopping_item_photos'        THEN COALESCE(v_counters.shopping_item_photos, 0)
      WHEN 'expense_photos'              THEN COALESCE(v_counters.expense_photos, 0)
      WHEN 'house_directory_note_photos' THEN COALESCE(v_counters.house_directory_note_photos, 0)
    END;

    v_new := GREATEST(0, v_current + v_delta);

    IF v_new > v_max THEN
      PERFORM public.api_error(
        'PAYWALL_LIMIT_' || upper(v_metric_key),
        format('Free plan allows up to %s %s per home.', v_max, v_metric_key),
        'P0001',
        jsonb_build_object(
          'limit_type', v_metric_key,
          'plan',       v_plan,
          'max',        v_max,
          'current',    v_current,
          'projected',  v_new
        )
      );
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public._home_assert_quota(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._home_usage_apply_delta(
  p_home_id uuid,
  p_deltas  jsonb
)
RETURNS public.home_usage_counters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row                               public.home_usage_counters;
  v_home_active                       boolean;

  v_active_chores_delta               integer := 0;
  v_chore_photos_delta                integer := 0;
  v_active_members_delta              integer := 0;
  v_active_expenses_delta             integer := 0;
  v_shopping_item_photos_delta        integer := 0;
  v_expense_photos_delta              integer := 0;
  v_house_directory_note_photos_delta integer := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Home not found.',
      'P0002',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  INSERT INTO public.home_usage_counters (home_id)
  VALUES (p_home_id)
  ON CONFLICT (home_id) DO NOTHING;

  IF p_deltas IS NOT NULL AND jsonb_typeof(p_deltas) = 'object' THEN
    IF jsonb_typeof(p_deltas->'active_chores') = 'number' THEN
      v_active_chores_delta := (p_deltas->>'active_chores')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'chore_photos') = 'number' THEN
      v_chore_photos_delta := (p_deltas->>'chore_photos')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'active_members') = 'number' THEN
      v_active_members_delta := (p_deltas->>'active_members')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'active_expenses') = 'number' THEN
      v_active_expenses_delta := (p_deltas->>'active_expenses')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'shopping_item_photos') = 'number' THEN
      v_shopping_item_photos_delta := (p_deltas->>'shopping_item_photos')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'expense_photos') = 'number' THEN
      v_expense_photos_delta := (p_deltas->>'expense_photos')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'house_directory_note_photos') = 'number' THEN
      v_house_directory_note_photos_delta := (p_deltas->>'house_directory_note_photos')::integer;
    END IF;
  END IF;

  UPDATE public.home_usage_counters h
     SET active_chores               = GREATEST(0, COALESCE(h.active_chores, 0) + v_active_chores_delta),
         chore_photos                = GREATEST(0, COALESCE(h.chore_photos, 0) + v_chore_photos_delta),
         active_members              = GREATEST(0, COALESCE(h.active_members, 0) + v_active_members_delta),
         active_expenses             = GREATEST(0, COALESCE(h.active_expenses, 0) + v_active_expenses_delta),
         shopping_item_photos        = GREATEST(0, COALESCE(h.shopping_item_photos, 0) + v_shopping_item_photos_delta),
         expense_photos              = GREATEST(0, COALESCE(h.expense_photos, 0) + v_expense_photos_delta),
         house_directory_note_photos = GREATEST(0, COALESCE(h.house_directory_note_photos, 0) + v_house_directory_note_photos_delta),
         updated_at                  = now()
   WHERE h.home_id = p_home_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public._home_usage_apply_delta(uuid, jsonb)
FROM PUBLIC, anon, authenticated;
