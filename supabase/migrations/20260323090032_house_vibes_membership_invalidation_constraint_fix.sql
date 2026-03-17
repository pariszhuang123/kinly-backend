-- Fix house_vibes invalidation on membership changes.
--
-- Problem:
-- - The legacy memberships trigger still calls _house_vibes_mark_out_of_date().
-- - That helper rewrites coverage_total for every row in house_vibes for the home.
-- - When membership count shrinks, historical rows can transiently end up with
--   coverage_answered > coverage_total and violate chk_house_vibes_coverage_order.
--
-- Fix:
-- 1) Make the legacy helper clamp coverage_answered when it rewrites coverage_total.
-- 2) Repoint the memberships trigger to the newer _house_vibes_invalidate() helper,
--    which only marks rows stale and does not rewrite coverage coverage numbers.

CREATE OR REPLACE FUNCTION public._house_vibes_mark_out_of_date(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total int;
  v_active_mapping_version text;
BEGIN
  SELECT COUNT(*)
    INTO v_total
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.is_current = true;

  SELECT hv.mapping_version
    INTO v_active_mapping_version
  FROM public.house_vibe_versions hv
  WHERE hv.status = 'active'
  ORDER BY hv.created_at DESC
  LIMIT 1;

  IF v_active_mapping_version IS NULL THEN
    v_active_mapping_version := 'v1';
  END IF;

  UPDATE public.house_vibes
  SET
    out_of_date = true,
    invalidated_at = now(),
    computed_at = now(),
    coverage_answered = LEAST(coverage_answered, COALESCE(v_total, 0)),
    coverage_total = COALESCE(v_total, 0)
  WHERE home_id = p_home_id;

  INSERT INTO public.house_vibes (
    home_id,
    mapping_version,
    label_id,
    confidence,
    coverage_answered,
    coverage_total,
    axes,
    computed_at,
    out_of_date,
    invalidated_at
  )
  VALUES (
    p_home_id,
    v_active_mapping_version,
    'insufficient_data',
    0,
    0,
    COALESCE(v_total, 0),
    '{}'::jsonb,
    now(),
    true,
    now()
  )
  ON CONFLICT (home_id, mapping_version) DO UPDATE
    SET out_of_date       = true,
        label_id          = EXCLUDED.label_id,
        confidence        = EXCLUDED.confidence,
        coverage_answered = EXCLUDED.coverage_answered,
        coverage_total    = EXCLUDED.coverage_total,
        axes              = EXCLUDED.axes,
        computed_at       = EXCLUDED.computed_at,
        invalidated_at    = EXCLUDED.invalidated_at;
END;
$$;

CREATE OR REPLACE FUNCTION public._house_vibes_mark_out_of_date_memberships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old_home uuid := null;
  v_new_home uuid := null;
  v_should_invalidate boolean := false;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new_home := NEW.home_id;

    IF NEW.valid_to IS NULL THEN
      v_should_invalidate := true;
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    v_old_home := OLD.home_id;

    IF OLD.valid_to IS NULL THEN
      v_should_invalidate := true;
    END IF;
  ELSE
    v_old_home := OLD.home_id;
    v_new_home := NEW.home_id;

    IF OLD.valid_to IS NULL AND NEW.valid_to IS NOT NULL THEN
      v_should_invalidate := true;
    END IF;

    IF OLD.valid_from IS DISTINCT FROM NEW.valid_from THEN
      v_should_invalidate := true;
    END IF;

    IF NEW.valid_to IS NULL AND OLD.role IS DISTINCT FROM NEW.role THEN
      v_should_invalidate := true;
    END IF;

    IF OLD.home_id IS DISTINCT FROM NEW.home_id THEN
      v_should_invalidate := true;
    END IF;
  END IF;

  IF v_should_invalidate THEN
    IF v_old_home IS NOT NULL THEN
      PERFORM public._house_vibes_invalidate(v_old_home);
    END IF;

    IF v_new_home IS NOT NULL AND v_new_home IS DISTINCT FROM v_old_home THEN
      PERFORM public._house_vibes_invalidate(v_new_home);
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;
