BEGIN;

ALTER TABLE public.shopping_list_purchase_memory
  ADD COLUMN IF NOT EXISTS canonical_name_v2 text;

ALTER TABLE public.shopping_list_purchase_memory
  DROP CONSTRAINT IF EXISTS chk_shopping_list_purchase_memory_canonical_name_v2;

ALTER TABLE public.shopping_list_purchase_memory
  ADD CONSTRAINT chk_shopping_list_purchase_memory_canonical_name_v2
  CHECK (canonical_name_v2 IS NULL OR btrim(canonical_name_v2) <> '');

CREATE OR REPLACE FUNCTION public._shopping_list__canonicalize_name_v2(
  p_name text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH folded AS (
    SELECT lower(
      btrim(
        replace(
          replace(
            replace(
              replace(
                replace(
                  replace(
                    replace(
                      replace(
                        replace(
                          replace(
                            replace(
                              replace(
                                replace(coalesce(p_name, ''), ' ', ' '),
                                '　', ' '
                              ),
                              '’', ' '
                            ),
                            '‘', ' '
                          ),
                          '＇', ' '
                        ),
                        '‐', ' '
                      ),
                      '‑', ' '
                    ),
                    '‒', ' '
                  ),
                  '–', ' '
                ),
                '—', ' '
              ),
              '―', ' '
            ),
            '−', ' '
          ),
          '。', ' '
        )
      )
    ) AS value
  ),
  cleaned AS (
    SELECT regexp_replace(
      regexp_replace(
        regexp_replace(
          value,
          '、+',
          ' ',
          'g'
        ),
        '[[:punct:]]+',
        ' ',
        'g'
      ),
      '\s+',
      ' ',
      'g'
    ) AS value
    FROM folded
  ),
  tokens AS (
    SELECT token, ordinality
    FROM cleaned c
    CROSS JOIN LATERAL regexp_split_to_table(btrim(c.value), '\s+') WITH ORDINALITY AS t(token, ordinality)
    WHERE token <> ''
  )
  SELECT coalesce(
    string_agg(public._shopping_list__canonicalize_token(token), ' ' ORDER BY ordinality),
    ''
  )
  FROM tokens;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__canonicalize_name_v2(text)
FROM PUBLIC, anon, authenticated;

UPDATE public.shopping_list_purchase_memory pm
SET
  canonical_name_v2 = public._shopping_list__canonicalize_name_v2(pm.display_name),
  warning_window_days = public._shopping_list__warning_window_days(
    public._shopping_list__canonicalize_name_v2(pm.display_name)
  )
WHERE canonical_name_v2 IS NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.shopping_list_purchase_memory pm
    WHERE pm.canonical_name_v2 IS NULL
       OR btrim(pm.canonical_name_v2) = ''
  ) THEN
    RAISE EXCEPTION 'shopping_list_purchase_memory canonical_name_v2 backfill produced blank rows';
  END IF;
END;
$$;

WITH ranked AS (
  SELECT
    pm.id,
    row_number() OVER (
      PARTITION BY pm.home_id, pm.canonical_name_v2
      ORDER BY pm.last_purchased_at DESC, pm.id ASC
    ) AS rn
  FROM public.shopping_list_purchase_memory pm
  WHERE pm.scope_type = 'house'
    AND pm.canonical_name_v2 IS NOT NULL
)
DELETE FROM public.shopping_list_purchase_memory pm
USING ranked r
WHERE pm.id = r.id
  AND r.rn > 1;

WITH ranked AS (
  SELECT
    pm.id,
    row_number() OVER (
      PARTITION BY pm.home_id, pm.unit_id, pm.canonical_name_v2
      ORDER BY pm.last_purchased_at DESC, pm.id ASC
    ) AS rn
  FROM public.shopping_list_purchase_memory pm
  WHERE pm.scope_type = 'unit'
    AND pm.canonical_name_v2 IS NOT NULL
)
DELETE FROM public.shopping_list_purchase_memory pm
USING ranked r
WHERE pm.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_shopping_list_purchase_memory_house_v2
  ON public.shopping_list_purchase_memory (home_id, canonical_name_v2)
  WHERE scope_type = 'house'
    AND canonical_name_v2 IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_shopping_list_purchase_memory_unit_v2
  ON public.shopping_list_purchase_memory (home_id, unit_id, canonical_name_v2)
  WHERE scope_type = 'unit'
    AND canonical_name_v2 IS NOT NULL;

CREATE OR REPLACE FUNCTION public._shopping_list__purchase_memory_payload(
  p_home_id uuid,
  p_scope_type text,
  p_unit_id uuid,
  p_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row record;
  v_canonical_name text := public._shopping_list__canonicalize_name(p_name);
  v_canonical_name_v2 text := public._shopping_list__canonicalize_name_v2(p_name);
BEGIN
  WITH candidates AS (
    SELECT
      0 AS priority,
      pm.last_purchased_at,
      p.username AS last_purchased_by_display_name,
      floor(extract(epoch FROM (now() - pm.last_purchased_at)) / 86400)::integer AS days_since_last_purchase,
      pm.warning_window_days
    FROM public.shopping_list_purchase_memory pm
    LEFT JOIN public.profiles p
      ON p.id = pm.last_purchased_by_user_id
    WHERE pm.home_id = p_home_id
      AND pm.scope_type = p_scope_type
      AND pm.canonical_name_v2 = v_canonical_name_v2
      AND (
        (p_scope_type = 'house' AND pm.unit_id IS NULL)
        OR
        (p_scope_type = 'unit' AND pm.unit_id = p_unit_id)
      )

    UNION ALL

    SELECT
      1 AS priority,
      pm.last_purchased_at,
      p.username AS last_purchased_by_display_name,
      floor(extract(epoch FROM (now() - pm.last_purchased_at)) / 86400)::integer AS days_since_last_purchase,
      pm.warning_window_days
    FROM public.shopping_list_purchase_memory pm
    LEFT JOIN public.profiles p
      ON p.id = pm.last_purchased_by_user_id
    WHERE pm.home_id = p_home_id
      AND pm.scope_type = p_scope_type
      AND pm.canonical_name = v_canonical_name
      AND (
        pm.canonical_name_v2 IS NULL
        OR pm.canonical_name_v2 <> v_canonical_name_v2
      )
      AND (
        (p_scope_type = 'house' AND pm.unit_id IS NULL)
        OR
        (p_scope_type = 'unit' AND pm.unit_id = p_unit_id)
      )
  )
  SELECT
    c.last_purchased_at,
    c.last_purchased_by_display_name,
    c.days_since_last_purchase,
    c.warning_window_days
  INTO v_row
  FROM candidates c
  ORDER BY c.priority
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_row.days_since_last_purchase >= v_row.warning_window_days THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'last_purchased_at', v_row.last_purchased_at,
    'last_purchased_by_display_name', v_row.last_purchased_by_display_name,
    'days_since_last_purchase', v_row.days_since_last_purchase,
    'warning_window_days', v_row.warning_window_days
  );
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__purchase_memory_payload(uuid, text, uuid, text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__write_purchase_memory(
  p_item_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_item_ids IS NULL OR cardinality(p_item_ids) = 0 THEN
    RETURN;
  END IF;

  WITH latest_candidate AS (
    SELECT DISTINCT ON (
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name_v2(i.name)
    )
      i.home_id,
      i.scope_type,
      i.unit_id,
      COALESCE(
        NULLIF(public._shopping_list__canonicalize_name(i.name), ''),
        public._shopping_list__canonicalize_name_v2(i.name)
      ) AS canonical_name,
      public._shopping_list__canonicalize_name_v2(i.name) AS canonical_name_v2,
      btrim(i.name) AS display_name,
      i.completed_by_user_id AS last_purchased_by_user_id,
      i.completed_at AS last_purchased_at,
      i.id
    FROM public.shopping_list_items i
    WHERE i.id = ANY(p_item_ids)
      AND i.is_completed = TRUE
      AND i.completed_by_user_id IS NOT NULL
      AND i.completed_at IS NOT NULL
      AND public._shopping_list__canonicalize_name_v2(i.name) <> ''
    ORDER BY
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name_v2(i.name),
      i.completed_at DESC,
      i.id ASC
  )
  INSERT INTO public.shopping_list_purchase_memory (
    home_id,
    scope_type,
    unit_id,
    canonical_name,
    canonical_name_v2,
    display_name,
    last_purchased_at,
    last_purchased_by_user_id,
    warning_window_days
  )
  SELECT
    c.home_id,
    c.scope_type,
    c.unit_id,
    c.canonical_name,
    c.canonical_name_v2,
    c.display_name,
    c.last_purchased_at,
    c.last_purchased_by_user_id,
    public._shopping_list__warning_window_days(c.canonical_name_v2)
  FROM latest_candidate c
  WHERE c.scope_type = 'house'
  ON CONFLICT (home_id, canonical_name_v2)
    WHERE scope_type = 'house'
      AND canonical_name_v2 IS NOT NULL
  DO UPDATE
  SET
    canonical_name = EXCLUDED.canonical_name,
    canonical_name_v2 = EXCLUDED.canonical_name_v2,
    display_name = EXCLUDED.display_name,
    last_purchased_at = EXCLUDED.last_purchased_at,
    last_purchased_by_user_id = EXCLUDED.last_purchased_by_user_id,
    warning_window_days = EXCLUDED.warning_window_days;

  WITH latest_candidate AS (
    SELECT DISTINCT ON (
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name_v2(i.name)
    )
      i.home_id,
      i.scope_type,
      i.unit_id,
      COALESCE(
        NULLIF(public._shopping_list__canonicalize_name(i.name), ''),
        public._shopping_list__canonicalize_name_v2(i.name)
      ) AS canonical_name,
      public._shopping_list__canonicalize_name_v2(i.name) AS canonical_name_v2,
      btrim(i.name) AS display_name,
      i.completed_by_user_id AS last_purchased_by_user_id,
      i.completed_at AS last_purchased_at,
      i.id
    FROM public.shopping_list_items i
    WHERE i.id = ANY(p_item_ids)
      AND i.is_completed = TRUE
      AND i.completed_by_user_id IS NOT NULL
      AND i.completed_at IS NOT NULL
      AND public._shopping_list__canonicalize_name_v2(i.name) <> ''
    ORDER BY
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name_v2(i.name),
      i.completed_at DESC,
      i.id ASC
  )
  INSERT INTO public.shopping_list_purchase_memory (
    home_id,
    scope_type,
    unit_id,
    canonical_name,
    canonical_name_v2,
    display_name,
    last_purchased_at,
    last_purchased_by_user_id,
    warning_window_days
  )
  SELECT
    c.home_id,
    c.scope_type,
    c.unit_id,
    c.canonical_name,
    c.canonical_name_v2,
    c.display_name,
    c.last_purchased_at,
    c.last_purchased_by_user_id,
    public._shopping_list__warning_window_days(c.canonical_name_v2)
  FROM latest_candidate c
  WHERE c.scope_type = 'unit'
  ON CONFLICT (home_id, unit_id, canonical_name_v2)
    WHERE scope_type = 'unit'
      AND canonical_name_v2 IS NOT NULL
  DO UPDATE
  SET
    canonical_name = EXCLUDED.canonical_name,
    canonical_name_v2 = EXCLUDED.canonical_name_v2,
    display_name = EXCLUDED.display_name,
    last_purchased_at = EXCLUDED.last_purchased_at,
    last_purchased_by_user_id = EXCLUDED.last_purchased_by_user_id,
    warning_window_days = EXCLUDED.warning_window_days;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__write_purchase_memory(uuid[])
FROM PUBLIC, anon, authenticated;

COMMIT;
