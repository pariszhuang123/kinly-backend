-- =====================================================================
-- Shopping list v1 (FULL • adjusted • concurrency-safe active_expenses)
--
-- Changes in this revision:
--  ✅ Security hardening:
--     - REVOKE EXECUTE on internal helpers:
--         public._home_assert_quota(uuid, jsonb)
--         public._home_usage_apply_delta(uuid, jsonb)
--       (they are called only from other SECURITY DEFINER RPCs that already
--        assert auth + home membership)
--
--  ✅ Concurrency fix:
--     - shopping_list_link_items_to_expense_for_user now locks the expense row
--       (FOR UPDATE) before checking "had any linked" + performing updates,
--       preventing double-count increments of active_expenses under concurrency.
-- =====================================================================

/* ---------------------------------------------------------------------
   0) Quota system extensions: new metric + counter + free limit
--------------------------------------------------------------------- */

-- 0.1 Add counter column to home_usage_counters (idempotent)
ALTER TABLE public.home_usage_counters
ADD COLUMN IF NOT EXISTS shopping_item_photos integer NOT NULL DEFAULT 0;

DO $$
BEGIN
  BEGIN
    ALTER TABLE public.home_usage_counters
      ADD CONSTRAINT home_usage_counters_shopping_item_photos_check
      CHECK (shopping_item_photos >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;

-- 0.2 Ensure plan limit exists (free: 10)
INSERT INTO public.home_plan_limits (plan, metric, max_value)
VALUES ('free', 'shopping_item_photos', 10)
ON CONFLICT (plan, metric) DO UPDATE
SET max_value = EXCLUDED.max_value;

/* ---------------------------------------------------------------------
   0.3 Extend _home_assert_quota to support shopping_item_photos
        (keeps your existing behavior: premium bypass; unknown metrics ignored)
--------------------------------------------------------------------- */

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
    v_counters.active_chores        := 0;
    v_counters.chore_photos         := 0;
    v_counters.active_members       := 0;
    v_counters.active_expenses      := 0;
    v_counters.shopping_item_photos := 0;
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
      WHEN 'active_chores'        THEN COALESCE(v_counters.active_chores, 0)
      WHEN 'chore_photos'         THEN COALESCE(v_counters.chore_photos, 0)
      WHEN 'active_members'       THEN COALESCE(v_counters.active_members, 0)
      WHEN 'active_expenses'      THEN COALESCE(v_counters.active_expenses, 0)
      WHEN 'shopping_item_photos' THEN COALESCE(v_counters.shopping_item_photos, 0)
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

-- 🔒 INTERNAL ONLY: do NOT grant to authenticated/anon/public
REVOKE ALL ON FUNCTION public._home_assert_quota(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

/* ---------------------------------------------------------------------
   0.4 Extend _home_usage_apply_delta to apply shopping_item_photos
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public._home_usage_apply_delta(
  p_home_id uuid,
  p_deltas  jsonb   -- e.g. {"active_expenses": 1, "shopping_item_photos": 1}
)
RETURNS public.home_usage_counters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row                         public.home_usage_counters;
  v_home_active                 boolean;

  v_active_chores_delta         integer := 0;
  v_chore_photos_delta          integer := 0;
  v_active_members_delta        integer := 0;
  v_active_expenses_delta       integer := 0;
  v_shopping_item_photos_delta  integer := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  -- Lock home FIRST to match global lock order (homes -> ...)
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
  END IF;

  UPDATE public.home_usage_counters h
     SET active_chores        = GREATEST(0, COALESCE(h.active_chores, 0) + v_active_chores_delta),
         chore_photos         = GREATEST(0, COALESCE(h.chore_photos, 0) + v_chore_photos_delta),
         active_members       = GREATEST(0, COALESCE(h.active_members, 0) + v_active_members_delta),
         active_expenses      = GREATEST(0, COALESCE(h.active_expenses, 0) + v_active_expenses_delta),
         shopping_item_photos = GREATEST(0, COALESCE(h.shopping_item_photos, 0) + v_shopping_item_photos_delta),
         updated_at           = now()
   WHERE h.home_id = p_home_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- 🔒 INTERNAL ONLY: do NOT grant to authenticated/anon/public
REVOKE ALL ON FUNCTION public._home_usage_apply_delta(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

/* ---------------------------------------------------------------------
   1) Shopping list tables + indexes
--------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS public.shopping_lists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  created_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  is_active boolean NOT NULL DEFAULT TRUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.shopping_lists IS 'One active shared shopping list per home.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_shopping_lists_one_active_per_home
  ON public.shopping_lists (home_id)
  WHERE is_active = TRUE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_shopping_lists_id_home
  ON public.shopping_lists (id, home_id);

CREATE INDEX IF NOT EXISTS idx_shopping_lists_home_active
  ON public.shopping_lists (home_id, is_active);

CREATE TABLE IF NOT EXISTS public.shopping_list_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shopping_list_id uuid NOT NULL,
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  created_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name text NOT NULL,
  quantity text,
  details text,
  is_completed boolean NOT NULL DEFAULT FALSE,
  completed_by_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  completed_at timestamptz,
  reference_photo_path text,
  reference_added_by_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  linked_expense_id uuid REFERENCES public.expenses(id) ON DELETE SET NULL,
  archived_at timestamptz,
  archived_by_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT fk_shopping_list_items_list_home
    FOREIGN KEY (shopping_list_id, home_id)
    REFERENCES public.shopping_lists(id, home_id)
    ON DELETE CASCADE,

  CONSTRAINT chk_shopping_list_items_name
    CHECK (char_length(btrim(name)) BETWEEN 1 AND 140),

  CONSTRAINT chk_shopping_list_items_quantity_length
    CHECK (quantity IS NULL OR char_length(quantity) <= 80),

  CONSTRAINT chk_shopping_list_items_details_length
    CHECK (details IS NULL OR char_length(details) <= 2000),

  CONSTRAINT chk_shopping_list_items_completion_alignment
    CHECK (
      (is_completed = TRUE AND completed_by_user_id IS NOT NULL AND completed_at IS NOT NULL)
      OR
      (is_completed = FALSE AND completed_by_user_id IS NULL AND completed_at IS NULL)
    ),

  CONSTRAINT chk_shopping_list_items_archive_alignment
    CHECK (
      (archived_at IS NULL AND archived_by_user_id IS NULL)
      OR
      (archived_at IS NOT NULL AND archived_by_user_id IS NOT NULL)
    ),

  CONSTRAINT chk_shopping_list_items_reference_alignment
    CHECK (
      (reference_photo_path IS NULL AND reference_added_by_user_id IS NULL)
      OR
      (reference_photo_path IS NOT NULL AND reference_added_by_user_id IS NOT NULL)
    ),

  CONSTRAINT chk_shopping_list_items_reference_path
    CHECK (
      reference_photo_path IS NULL
      OR reference_photo_path LIKE 'households/%'
    )
);

COMMENT ON TABLE public.shopping_list_items IS 'Items in a home shopping list; completed items can be linked to an expense and archived.';

CREATE INDEX IF NOT EXISTS idx_shopping_list_items_home_active
  ON public.shopping_list_items (home_id, archived_at, is_completed, completed_at DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_shopping_list_items_list_active
  ON public.shopping_list_items (shopping_list_id, archived_at, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_shopping_list_items_expense
  ON public.shopping_list_items (linked_expense_id)
  WHERE linked_expense_id IS NOT NULL;

/* ---------------------------------------------------------------------
   2) RLS + privileges (RPC-only)
--------------------------------------------------------------------- */

ALTER TABLE public.shopping_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopping_list_items ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.shopping_lists, public.shopping_list_items
FROM PUBLIC, anon, authenticated;

/* ---------------------------------------------------------------------
   3) updated_at trigger helper + triggers
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public._touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shopping_lists_updated_at ON public.shopping_lists;
CREATE TRIGGER trg_shopping_lists_updated_at
BEFORE UPDATE ON public.shopping_lists
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

DROP TRIGGER IF EXISTS trg_shopping_list_items_updated_at ON public.shopping_list_items;
CREATE TRIGGER trg_shopping_list_items_updated_at
BEFORE UPDATE ON public.shopping_list_items
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

/* ---------------------------------------------------------------------
   4) Internal helper: get-or-create active list (guarded)
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public._shopping_list_get_or_create_active(
  p_home_id uuid
)
RETURNS public.shopping_lists
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_list public.shopping_lists;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  INSERT INTO public.shopping_lists (
    home_id,
    created_by_user_id,
    is_active,
    created_at,
    updated_at
  )
  VALUES (
    p_home_id,
    v_user,
    TRUE,
    now(),
    now()
  )
  ON CONFLICT (home_id) WHERE is_active = TRUE
  DO UPDATE
    SET updated_at = EXCLUDED.updated_at
  RETURNING * INTO v_list;

  RETURN v_list;
END;
$$;

/* ---------------------------------------------------------------------
   5) RPC: Get list + items (includes list.items_count)
       If no list exists, returns an "empty active list object" (no insert)
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public.shopping_list_get_for_home(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
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
          'is_completed', i.is_completed,
          'completed_by_user_id', i.completed_by_user_id,
          'completed_by_avatar_id', p.avatar_id,
          'completed_at', i.completed_at,
          'reference_photo_path', i.reference_photo_path,
          'reference_added_by_user_id', i.reference_added_by_user_id,
          'linked_expense_id', i.linked_expense_id,
          'archived_at', i.archived_at,
          'archived_by_user_id', i.archived_by_user_id,
          'created_at', i.created_at,
          'updated_at', i.updated_at
        )
        ORDER BY i.is_completed ASC, i.completed_at DESC NULLS LAST, i.created_at DESC
      ),
      '[]'::jsonb
    ) AS items_json,
    COUNT(*)::int AS unarchived_count
  INTO v_items, v_unarchived_count
  FROM public.shopping_list_items i
  LEFT JOIN public.profiles p
    ON p.id = i.completed_by_user_id
  WHERE i.shopping_list_id = v_list.id
    AND i.archived_at IS NULL;

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

/* ---------------------------------------------------------------------
   6) RPC: Add item (explicit photo guard + quota+usage on photo add)
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public.shopping_list_add_item(
  p_home_id uuid,
  p_name text,
  p_quantity text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_reference_photo_path text DEFAULT NULL
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_list public.shopping_lists;
  v_item public.shopping_list_items;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  IF COALESCE(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'invalid_name',
      'Item name is required.',
      '22023',
      jsonb_build_object('field', 'name')
    );
  END IF;

  IF p_reference_photo_path IS NOT NULL
     AND p_reference_photo_path NOT LIKE 'households/%' THEN
    PERFORM public.api_error(
      'invalid_reference_photo_path',
      'Reference photo path must start with households/.',
      '22023',
      jsonb_build_object('field', 'reference_photo_path')
    );
  END IF;

  IF p_reference_photo_path IS NOT NULL THEN
    PERFORM public._home_assert_quota(
      p_home_id,
      jsonb_build_object('shopping_item_photos', 1)
    );

    PERFORM public._home_usage_apply_delta(
      p_home_id,
      jsonb_build_object('shopping_item_photos', 1)
    );
  END IF;

  v_list := public._shopping_list_get_or_create_active(p_home_id);

  INSERT INTO public.shopping_list_items (
    shopping_list_id,
    home_id,
    created_by_user_id,
    name,
    quantity,
    details,
    reference_photo_path,
    reference_added_by_user_id
  )
  VALUES (
    v_list.id,
    p_home_id,
    v_user,
    btrim(p_name),
    p_quantity,
    p_details,
    p_reference_photo_path,
    CASE WHEN p_reference_photo_path IS NULL THEN NULL ELSE v_user END
  )
  RETURNING * INTO v_item;

  RETURN v_item;
END;
$$;

/* ---------------------------------------------------------------------
   7) RPC: Update item (explicit photo guard + quota+usage only on FIRST add)
       - If p_replace_photo=true: replacement allowed, no usage increment
       - Removing photo is not allowed (must stay immutable once set)
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public.shopping_list_update_item(
  p_item_id uuid,
  p_name text DEFAULT NULL,
  p_quantity text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_is_completed boolean DEFAULT NULL,
  p_reference_photo_path text DEFAULT NULL,
  p_replace_photo boolean DEFAULT FALSE
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_existing public.shopping_list_items;
  v_next_name text;
  v_next_quantity text;
  v_next_details text;
  v_next_is_completed boolean;
  v_next_completed_by uuid;
  v_next_completed_at timestamptz;
  v_next_reference_path text;
  v_next_reference_added_by uuid;
  v_updated public.shopping_list_items;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT i.*
  INTO v_existing
  FROM public.shopping_list_items i
  JOIN public.memberships m
    ON m.home_id = i.home_id
   AND m.user_id = v_user
   AND m.is_current = TRUE
  WHERE i.id = p_item_id
    AND i.archived_at IS NULL
  FOR UPDATE;

  IF v_existing.id IS NULL THEN
    PERFORM public.api_error(
      'item_not_found',
      'Shopping list item not found.',
      'P0002',
      jsonb_build_object('item_id', p_item_id)
    );
  END IF;

  IF p_name IS NOT NULL AND COALESCE(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'invalid_name',
      'Item name is required.',
      '22023',
      jsonb_build_object('field', 'name')
    );
  END IF;

  IF p_reference_photo_path IS NOT NULL
     AND p_reference_photo_path NOT LIKE 'households/%' THEN
    PERFORM public.api_error(
      'invalid_reference_photo_path',
      'Reference photo path must start with households/.',
      '22023',
      jsonb_build_object('field', 'reference_photo_path')
    );
  END IF;

  IF v_existing.reference_photo_path IS NULL
     AND p_reference_photo_path IS NOT NULL THEN
    PERFORM public._home_assert_quota(
      v_existing.home_id,
      jsonb_build_object('shopping_item_photos', 1)
    );

    PERFORM public._home_usage_apply_delta(
      v_existing.home_id,
      jsonb_build_object('shopping_item_photos', 1)
    );
  END IF;

  v_next_name := COALESCE(NULLIF(btrim(p_name), ''), v_existing.name);
  v_next_quantity := COALESCE(p_quantity, v_existing.quantity);
  v_next_details := COALESCE(p_details, v_existing.details);

  IF p_is_completed IS NULL THEN
    v_next_is_completed := v_existing.is_completed;
    v_next_completed_by := v_existing.completed_by_user_id;
    v_next_completed_at := v_existing.completed_at;
  ELSIF p_is_completed THEN
    v_next_is_completed := TRUE;
    v_next_completed_by := v_user;
    v_next_completed_at := now();
  ELSE
    v_next_is_completed := FALSE;
    v_next_completed_by := NULL;
    v_next_completed_at := NULL;
  END IF;

  v_next_reference_path := v_existing.reference_photo_path;
  v_next_reference_added_by := v_existing.reference_added_by_user_id;

  IF p_replace_photo THEN
    IF p_reference_photo_path IS NULL THEN
      PERFORM public.api_error(
        'photo_delete_not_allowed',
        'Removing a reference photo is not allowed.',
        '22023',
        jsonb_build_object('item_id', p_item_id)
      );
    END IF;

    v_next_reference_path := p_reference_photo_path;
    v_next_reference_added_by := v_user;

  ELSIF v_existing.reference_photo_path IS NULL AND p_reference_photo_path IS NOT NULL THEN
    v_next_reference_path := p_reference_photo_path;
    v_next_reference_added_by := v_user;
  END IF;

  UPDATE public.shopping_list_items
  SET
    name = v_next_name,
    quantity = v_next_quantity,
    details = v_next_details,
    is_completed = v_next_is_completed,
    completed_by_user_id = v_next_completed_by,
    completed_at = v_next_completed_at,
    reference_photo_path = v_next_reference_path,
    reference_added_by_user_id = v_next_reference_added_by
  WHERE id = p_item_id
  RETURNING * INTO v_updated;

  RETURN v_updated;
END;
$$;

/* ---------------------------------------------------------------------
   8) RPC: Prepare expense defaults from "my completed, unlinked" items
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public.shopping_list_prepare_expense_for_user(
  p_home_id uuid
)
RETURNS TABLE (
  default_description text,
  default_notes text,
  item_ids uuid[],
  item_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  RETURN QUERY
  WITH candidate AS (
    SELECT i.id, i.name, i.completed_at, i.created_at
    FROM public.shopping_list_items i
    WHERE i.home_id = p_home_id
      AND i.archived_at IS NULL
      AND i.is_completed = TRUE
      AND i.completed_by_user_id = v_user
      AND i.linked_expense_id IS NULL
  )
  SELECT
    format('Groceries (%s items)', count(*)::int) AS default_description,
    left(string_agg(c.name, E'\n' ORDER BY c.completed_at DESC NULLS LAST, c.created_at DESC), 2000) AS default_notes,
    array_agg(c.id ORDER BY c.completed_at DESC NULLS LAST, c.created_at DESC) AS item_ids,
    count(*)::int AS item_count
  FROM candidate c
  HAVING count(*) > 0;
END;
$$;

/* ---------------------------------------------------------------------
   9) RPC: Link items to expense (tightened) + archive
      - Requires items: completed + owned by caller + unarchived + unlinked
      - Increments active_expenses by +1 ONLY if this expense had no links before
      - Never blocks on active_expenses over-limit (NO _home_assert_quota call)
      - ✅ Concurrency-safe: locks expense row FOR UPDATE to prevent double-count
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public.shopping_list_link_items_to_expense_for_user(
  p_home_id uuid,
  p_expense_id uuid,
  p_item_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_updated integer := 0;
  v_had_any_linked boolean := false;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  IF p_item_ids IS NULL OR cardinality(p_item_ids) = 0 THEN
    RETURN 0;
  END IF;

  -- ✅ Lock the expense row to serialize "first link?" logic per expense.
  PERFORM 1
  FROM public.expenses e
  WHERE e.id = p_expense_id
    AND e.home_id = p_home_id
    AND e.created_by_user_id = v_user
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'invalid_expense',
      'Expense does not belong to caller in this home.',
      '22023',
      jsonb_build_object('home_id', p_home_id, 'expense_id', p_expense_id)
    );
  END IF;

  -- With expense locked, this check is now concurrency-safe.
  SELECT EXISTS (
    SELECT 1
    FROM public.shopping_list_items i
    WHERE i.home_id = p_home_id
      AND i.linked_expense_id = p_expense_id
  )
  INTO v_had_any_linked;

  WITH ids AS (
    SELECT DISTINCT unnest(p_item_ids) AS id
  ),
  updated AS (
    UPDATE public.shopping_list_items i
    SET
      linked_expense_id = p_expense_id,
      archived_at = now(),
      archived_by_user_id = v_user
    FROM ids
    WHERE i.id = ids.id
      AND i.home_id = p_home_id
      AND i.archived_at IS NULL
      AND i.is_completed = TRUE
      AND i.completed_by_user_id = v_user
      AND i.linked_expense_id IS NULL
    RETURNING 1
  )
  SELECT count(*)::int INTO v_updated
  FROM updated;

  -- If we created the first link for this expense, bump active_expenses (+1).
  -- No quota assertion here: exceeding limit must NOT block.
  IF v_updated > 0 AND NOT v_had_any_linked THEN
    PERFORM public._home_usage_apply_delta(
      p_home_id,
      jsonb_build_object('active_expenses', 1)
    );
  END IF;

  RETURN v_updated;
END;
$$;

/* ---------------------------------------------------------------------
   10) RPC: Archive items for user (caller-owned completion)
       Rule: only the completer can archive
--------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION public.shopping_list_archive_items_for_user(
  p_home_id uuid,
  p_item_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_updated integer := 0;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  IF p_item_ids IS NULL OR cardinality(p_item_ids) = 0 THEN
    RETURN 0;
  END IF;

  WITH ids AS (
    SELECT DISTINCT unnest(p_item_ids) AS id
  ),
  updated AS (
    UPDATE public.shopping_list_items i
    SET
      archived_at = now(),
      archived_by_user_id = v_user
    FROM ids
    WHERE i.id = ids.id
      AND i.home_id = p_home_id
      AND i.archived_at IS NULL
      AND i.completed_by_user_id = v_user
    RETURNING 1
  )
  SELECT count(*)::int INTO v_updated
  FROM updated;

  RETURN v_updated;
END;
$$;

/* ---------------------------------------------------------------------
   11) Grants (RPC-only)
--------------------------------------------------------------------- */

REVOKE ALL ON FUNCTION public.shopping_list_get_for_home(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_get_for_home(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_add_item(uuid, text, text, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_add_item(uuid, text, text, text, text)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_update_item(uuid, text, text, text, boolean, text, boolean)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_update_item(uuid, text, text, text, boolean, text, boolean)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_prepare_expense_for_user(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_prepare_expense_for_user(uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_link_items_to_expense_for_user(uuid, uuid, uuid[])
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_link_items_to_expense_for_user(uuid, uuid, uuid[])
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_archive_items_for_user(uuid, uuid[])
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_archive_items_for_user(uuid, uuid[])
TO authenticated;
