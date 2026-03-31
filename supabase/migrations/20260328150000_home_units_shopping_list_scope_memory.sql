BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

/* ---------------------------------------------------------------------
   1) Home units foundation
   - remove representative_membership_id
   - database-enforced race protection for active shared membership
   - standardize active membership checks to valid_to IS NULL
--------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS public.home_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  unit_type text NOT NULL CHECK (unit_type IN ('personal', 'shared')),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  personal_membership_id uuid NULL REFERENCES public.memberships(id) ON DELETE CASCADE,
  created_by_user_id uuid NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
  archived_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_home_units_personal_shape CHECK (
    (unit_type = 'personal' AND personal_membership_id IS NOT NULL)
    OR
    (unit_type = 'shared' AND personal_membership_id IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_units_active_personal_per_membership
  ON public.home_units (home_id, personal_membership_id)
  WHERE unit_type = 'personal' AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_home_units_home_active
  ON public.home_units (home_id, unit_type)
  WHERE archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_units_id_home_id
  ON public.home_units (id, home_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_memberships_id_home_id
  ON public.memberships (id, home_id);

CREATE TABLE IF NOT EXISTS public.home_unit_members (
  unit_id uuid NOT NULL,
  home_id uuid NOT NULL,
  membership_id uuid NOT NULL,
  is_active_shared boolean NOT NULL DEFAULT FALSE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (unit_id, membership_id),
  CONSTRAINT fk_home_unit_members_unit
    FOREIGN KEY (unit_id, home_id)
    REFERENCES public.home_units(id, home_id)
    ON DELETE CASCADE,
  CONSTRAINT fk_home_unit_members_membership
    FOREIGN KEY (membership_id, home_id)
    REFERENCES public.memberships(id, home_id)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_home_unit_members_membership
  ON public.home_unit_members (membership_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_unit_members_one_active_shared_per_membership
  ON public.home_unit_members (membership_id)
  WHERE is_active_shared = TRUE;

ALTER TABLE public.home_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_unit_members ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.home_units, public.home_unit_members
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_home_units_updated_at ON public.home_units;
CREATE TRIGGER trg_home_units_updated_at
BEFORE UPDATE ON public.home_units
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

CREATE OR REPLACE FUNCTION public._home_units__sync_member_projection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_unit public.home_units;
BEGIN
  SELECT *
  INTO v_unit
  FROM public.home_units hu
  WHERE hu.id = NEW.unit_id
  LIMIT 1;

  IF v_unit.id IS NULL THEN
    PERFORM public.api_error(
      'unit_not_found',
      'Home unit not found.',
      'P0002',
      jsonb_build_object('unit_id', NEW.unit_id)
    );
  END IF;

  NEW.home_id := v_unit.home_id;
  NEW.is_active_shared := (v_unit.unit_type = 'shared' AND v_unit.archived_at IS NULL);

  IF v_unit.unit_type = 'personal'
     AND NEW.membership_id <> v_unit.personal_membership_id THEN
    PERFORM public.api_error(
      'invalid_personal_unit_member',
      'Personal units may only contain their linked personal membership.',
      '22023',
      jsonb_build_object('unit_id', NEW.unit_id, 'membership_id', NEW.membership_id)
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._home_units__sync_member_projection()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_home_unit_members_sync_projection ON public.home_unit_members;
CREATE TRIGGER trg_home_unit_members_sync_projection
BEFORE INSERT OR UPDATE OF unit_id, membership_id
ON public.home_unit_members
FOR EACH ROW EXECUTE FUNCTION public._home_units__sync_member_projection();

CREATE OR REPLACE FUNCTION public._home_units__sync_members_from_unit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.home_unit_members hum
  SET
    home_id = NEW.home_id,
    is_active_shared = (NEW.unit_type = 'shared' AND NEW.archived_at IS NULL)
  WHERE hum.unit_id = NEW.id;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._home_units__sync_members_from_unit()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_home_units_sync_members_from_unit ON public.home_units;
CREATE TRIGGER trg_home_units_sync_members_from_unit
AFTER UPDATE OF home_id, unit_type, archived_at
ON public.home_units
FOR EACH ROW EXECUTE FUNCTION public._home_units__sync_members_from_unit();

CREATE OR REPLACE FUNCTION public._home_units__reconcile_member_projection(
  p_home_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_updated integer := 0;
BEGIN
  UPDATE public.home_unit_members hum
  SET
    home_id = hu.home_id,
    is_active_shared = (hu.unit_type = 'shared' AND hu.archived_at IS NULL)
  FROM public.home_units hu
  WHERE hu.id = hum.unit_id
    AND (p_home_id IS NULL OR hu.home_id = p_home_id)
    AND (
      hum.home_id IS DISTINCT FROM hu.home_id
      OR hum.is_active_shared IS DISTINCT FROM (hu.unit_type = 'shared' AND hu.archived_at IS NULL)
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public._home_units__reconcile_member_projection(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._home_units__ensure_personal(
  p_home_id uuid,
  p_membership_id uuid,
  p_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_unit_id uuid;
  v_name text;
BEGIN
  PERFORM 1
  FROM public.memberships m
  WHERE m.id = p_membership_id
    AND m.home_id = p_home_id
    AND m.valid_to IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'membership_not_active',
      'Membership is not active for this home.',
      '42501',
      jsonb_build_object('home_id', p_home_id, 'membership_id', p_membership_id)
    );
  END IF;

  SELECT hu.id
  INTO v_unit_id
  FROM public.home_units hu
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'personal'
    AND hu.personal_membership_id = p_membership_id
    AND hu.archived_at IS NULL
  LIMIT 1;

  IF v_unit_id IS NULL THEN
    SELECT COALESCE(
      NULLIF(btrim(p.full_name), ''),
      'Personal'
    )
    INTO v_name
    FROM public.profiles p
    WHERE p.id = p_user_id;

    INSERT INTO public.home_units (
      home_id,
      unit_type,
      name,
      personal_membership_id,
      created_by_user_id
    )
    VALUES (
      p_home_id,
      'personal',
      COALESCE(v_name, 'Personal'),
      p_membership_id,
      p_user_id
    )
    RETURNING id INTO v_unit_id;
  END IF;

  INSERT INTO public.home_unit_members (unit_id, home_id, membership_id)
  VALUES (v_unit_id, p_home_id, p_membership_id)
  ON CONFLICT (unit_id, membership_id) DO NOTHING;

  RETURN v_unit_id;
END;
$$;

REVOKE ALL ON FUNCTION public._home_units__ensure_personal(uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._home_units__ensure_personal_membership_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.valid_to IS NULL THEN
    PERFORM public._home_units__ensure_personal(NEW.home_id, NEW.id, NEW.user_id);
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._home_units__ensure_personal_membership_trigger()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_home_units_membership_insert_personal ON public.memberships;
CREATE TRIGGER trg_home_units_membership_insert_personal
AFTER INSERT ON public.memberships
FOR EACH ROW EXECUTE FUNCTION public._home_units__ensure_personal_membership_trigger();

CREATE OR REPLACE FUNCTION public._home_units__membership_departure_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.valid_to IS NULL AND NEW.valid_to IS NOT NULL THEN
    UPDATE public.home_units hu
    SET archived_at = COALESCE(hu.archived_at, now())
    WHERE hu.unit_type = 'personal'
      AND hu.personal_membership_id = NEW.id
      AND hu.archived_at IS NULL;

    DELETE FROM public.home_unit_members hum
    USING public.home_units hu
    WHERE hum.unit_id = hu.id
      AND hum.membership_id = NEW.id
      AND hu.unit_type = 'shared'
      AND hu.archived_at IS NULL;

    UPDATE public.home_units hu
    SET archived_at = COALESCE(hu.archived_at, now())
    WHERE hu.unit_type = 'shared'
      AND hu.archived_at IS NULL
      AND hu.home_id = NEW.home_id
      AND hu.id IN (
        SELECT hu2.id
        FROM public.home_units hu2
        LEFT JOIN public.home_unit_members hum2
          ON hum2.unit_id = hu2.id
        LEFT JOIN public.memberships m2
          ON m2.id = hum2.membership_id
         AND m2.valid_to IS NULL
        WHERE hu2.unit_type = 'shared'
          AND hu2.archived_at IS NULL
          AND hu2.home_id = NEW.home_id
        GROUP BY hu2.id
        HAVING COUNT(m2.id) < 2
      );

    PERFORM public._home_units__reconcile_member_projection(NEW.home_id);
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._home_units__membership_departure_trigger()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_home_units_membership_departure ON public.memberships;
CREATE TRIGGER trg_home_units_membership_departure
AFTER UPDATE OF valid_to ON public.memberships
FOR EACH ROW EXECUTE FUNCTION public._home_units__membership_departure_trigger();

INSERT INTO public.home_units (
  home_id,
  unit_type,
  name,
  personal_membership_id,
  created_by_user_id
)
SELECT
  m.home_id,
  'personal',
  COALESCE(NULLIF(btrim(p.full_name), ''), 'Personal'),
  m.id,
  m.user_id
FROM public.memberships m
LEFT JOIN public.profiles p
  ON p.id = m.user_id
WHERE m.valid_to IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.home_units hu
    WHERE hu.home_id = m.home_id
      AND hu.unit_type = 'personal'
      AND hu.personal_membership_id = m.id
      AND hu.archived_at IS NULL
  );

INSERT INTO public.home_unit_members (unit_id, home_id, membership_id)
SELECT hu.id, hu.home_id, hu.personal_membership_id
FROM public.home_units hu
WHERE hu.unit_type = 'personal'
  AND hu.personal_membership_id IS NOT NULL
ON CONFLICT (unit_id, membership_id) DO NOTHING;

SELECT public._home_units__reconcile_member_projection();

CREATE OR REPLACE FUNCTION public._home_units__member_user_ids(
  p_unit_id uuid
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    array_agg(m.user_id::text ORDER BY m.user_id::text),
    ARRAY[]::text[]
  )
  FROM public.home_unit_members hum
  JOIN public.memberships m
    ON m.id = hum.membership_id
   AND m.valid_to IS NULL
  WHERE hum.unit_id = p_unit_id;
$$;

REVOKE ALL ON FUNCTION public._home_units__member_user_ids(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._home_units__unit_json(
  p_unit_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'unit_id', hu.id,
    'home_id', hu.home_id,
    'name', hu.name,
    'unit_type', hu.unit_type,
    'member_user_ids', to_jsonb(public._home_units__member_user_ids(hu.id))
  )
  FROM public.home_units hu
  WHERE hu.id = p_unit_id
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public._home_units__unit_json(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.home_units_get_my_context(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_personal_unit_id uuid;
  v_shared_unit_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  v_personal_unit_id := public._home_units__ensure_personal(
    p_home_id,
    v_membership_id,
    v_user
  );

  SELECT hu.id
  INTO v_shared_unit_id
  FROM public.home_units hu
  JOIN public.home_unit_members hum
    ON hum.unit_id = hu.id
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
    AND hum.membership_id = v_membership_id
    AND hum.is_active_shared = TRUE
  LIMIT 1;

  RETURN jsonb_build_object(
    'personal_unit', public._home_units__unit_json(v_personal_unit_id),
    'active_shared_unit', CASE
      WHEN v_shared_unit_id IS NULL THEN NULL
      ELSE public._home_units__unit_json(v_shared_unit_id)
    END,
    'allowed_shopping_scopes', jsonb_build_array('house', 'unit')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_get_my_context(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_get_my_context(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_list_selectable_expense_units(
  p_home_id uuid
)
RETURNS TABLE (
  unit_id uuid,
  home_id uuid,
  name text,
  unit_type text,
  member_user_ids text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_personal_unit_id uuid;
  v_shared_unit_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  v_personal_unit_id := public._home_units__ensure_personal(
    p_home_id,
    v_membership_id,
    v_user
  );

  SELECT hu.id
  INTO v_shared_unit_id
  FROM public.home_units hu
  JOIN public.home_unit_members hum
    ON hum.unit_id = hu.id
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
    AND hum.membership_id = v_membership_id
    AND hum.is_active_shared = TRUE
  LIMIT 1;

  RETURN QUERY
  SELECT
    hu.id,
    hu.home_id,
    hu.name,
    hu.unit_type,
    public._home_units__member_user_ids(hu.id)
  FROM public.home_units hu
  WHERE hu.id IN (
    v_personal_unit_id,
    v_shared_unit_id
  )
  ORDER BY CASE
    WHEN hu.id = v_shared_unit_id THEN 0
    ELSE 1
  END, hu.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_list_selectable_expense_units(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_list_selectable_expense_units(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_list_create_shared_candidates(
  p_home_id uuid
)
RETURNS TABLE (
  membership_id uuid,
  user_id uuid,
  display_name text,
  avatar_url text,
  is_owner boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.home_unit_members hum
    WHERE hum.membership_id = v_membership_id
      AND hum.is_active_shared = TRUE
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.user_id,
    COALESCE(
      NULLIF(btrim(p.full_name), ''),
      NULLIF(btrim(p.username), ''),
      split_part(p.email, '@', 1),
      'Member'
    ) AS display_name,
    a.storage_path AS avatar_url,
    (h.owner_user_id = m.user_id) AS is_owner
  FROM public.memberships m
  JOIN public.homes h
    ON h.id = m.home_id
  LEFT JOIN public.profiles p
    ON p.id = m.user_id
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.valid_to IS NULL
    AND m.id <> v_membership_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.home_unit_members hum
      WHERE hum.membership_id = m.id
        AND hum.is_active_shared = TRUE
    )
  ORDER BY
    CASE WHEN h.owner_user_id = m.user_id THEN 0 ELSE 1 END,
    display_name,
    m.id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_list_create_shared_candidates(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_list_create_shared_candidates(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_list_joinable_shared_units(
  p_home_id uuid
)
RETURNS TABLE (
  unit_id uuid,
  home_id uuid,
  name text,
  unit_type text,
  member_user_ids text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.home_unit_members hum
    WHERE hum.membership_id = v_membership_id
      AND hum.is_active_shared = TRUE
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    hu.id,
    hu.home_id,
    hu.name,
    hu.unit_type,
    public._home_units__member_user_ids(hu.id)
  FROM public.home_units hu
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.home_unit_members hum
      WHERE hum.unit_id = hu.id
        AND hum.membership_id = v_membership_id
    )
  ORDER BY hu.created_at, hu.id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_list_joinable_shared_units(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_list_joinable_shared_units(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_create_shared(
  p_home_id uuid,
  p_name text,
  p_membership_ids uuid[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_actor_membership_id uuid;
  v_unit_id uuid;
  v_membership_ids uuid[];
  v_count integer;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  IF COALESCE(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'invalid_unit_name',
      'Shared unit name is required.',
      '22023'
    );
  END IF;

  SELECT m.id
  INTO v_actor_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_actor_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  SELECT array_agg(x.membership_id ORDER BY x.membership_id)
  INTO v_membership_ids
  FROM (
    SELECT DISTINCT unnest(COALESCE(p_membership_ids, ARRAY[]::uuid[])) AS membership_id
    UNION
    SELECT v_actor_membership_id
  ) x;

  v_count := COALESCE(cardinality(v_membership_ids), 0);

  IF v_count < 2 THEN
    PERFORM public.api_error(
      'invalid_shared_unit_members',
      'Shared unit must contain at least two distinct current members.',
      '22023'
    );
  END IF;

  PERFORM 1
  FROM public.memberships m
  WHERE m.id = ANY(v_membership_ids)
    AND m.home_id = p_home_id
    AND m.valid_to IS NULL
  ORDER BY m.id
  FOR UPDATE;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count <> cardinality(v_membership_ids) THEN
    PERFORM public.api_error(
      'invalid_shared_unit_members',
      'All memberships must be current members of the same home.',
      '22023'
    );
  END IF;

  PERFORM 1
  FROM public.home_unit_members hum
  WHERE hum.membership_id = ANY(v_membership_ids)
    AND hum.is_active_shared = TRUE
  LIMIT 1;

  IF FOUND THEN
    PERFORM public.api_error(
      'membership_already_in_shared_unit',
      'A member is already in an active shared unit.',
      '42501'
    );
  END IF;

  INSERT INTO public.home_units (
    home_id,
    unit_type,
    name,
    created_by_user_id
  )
  VALUES (
    p_home_id,
    'shared',
    btrim(p_name),
    v_user
  )
  RETURNING id INTO v_unit_id;

  INSERT INTO public.home_unit_members (unit_id, home_id, membership_id)
  SELECT v_unit_id, p_home_id, membership_id
  FROM unnest(v_membership_ids) AS membership_id
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count <> cardinality(v_membership_ids) THEN
    DELETE FROM public.home_units
    WHERE id = v_unit_id;

    PERFORM public.api_error(
      'membership_already_in_shared_unit',
      'A member is already in an active shared unit.',
      '42501'
    );
  END IF;

  RETURN v_unit_id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_create_shared(uuid, text, uuid[])
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_create_shared(uuid, text, uuid[])
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_update_shared(
  p_unit_id uuid,
  p_name text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  IF COALESCE(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'invalid_unit_name',
      'Shared unit name is required.',
      '22023'
    );
  END IF;

  PERFORM 1
  FROM public.home_units hu
  JOIN public.home_unit_members hum
    ON hum.unit_id = hu.id
  JOIN public.memberships m
    ON m.id = hum.membership_id
   AND m.user_id = v_user
   AND m.valid_to IS NULL
  WHERE hu.id = p_unit_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'unit_not_found',
      'Shared unit not found or caller is not a member of it.',
      'P0002'
    );
  END IF;

  UPDATE public.home_units
  SET name = btrim(p_name)
  WHERE id = p_unit_id
    AND name IS DISTINCT FROM btrim(p_name);

  RETURN p_unit_id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_update_shared(uuid, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_update_shared(uuid, text)
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_join_shared(
  p_unit_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home_id uuid;
  v_membership_id uuid;
  v_count integer := 0;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT hu.home_id
  INTO v_home_id
  FROM public.home_units hu
  WHERE hu.id = p_unit_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
  FOR UPDATE;

  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'unit_not_found',
      'Shared unit not found.',
      'P0002'
    );
  END IF;

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = v_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  FOR UPDATE;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'unit_not_found',
      'Shared unit not found or caller is not in the same home.',
      'P0002'
    );
  END IF;

  PERFORM 1
  FROM public.home_unit_members hum
  WHERE hum.membership_id = v_membership_id
    AND hum.is_active_shared = TRUE
  LIMIT 1;

  IF FOUND THEN
    PERFORM public.api_error(
      'membership_already_in_shared_unit',
      'Caller is already in an active shared unit.',
      '42501'
    );
  END IF;

  INSERT INTO public.home_unit_members (unit_id, home_id, membership_id)
  VALUES (p_unit_id, v_home_id, v_membership_id)
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count = 0 THEN
    PERFORM public.api_error(
      'membership_already_in_shared_unit',
      'Caller is already in an active shared unit.',
      '42501'
    );
  END IF;

  RETURN p_unit_id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_join_shared(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_join_shared(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.home_units_leave_shared(
  p_unit_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_home_id uuid;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT hu.home_id, m.id
  INTO v_home_id, v_membership_id
  FROM public.home_units hu
  JOIN public.home_unit_members hum
    ON hum.unit_id = hu.id
  JOIN public.memberships m
    ON m.id = hum.membership_id
   AND m.user_id = v_user
   AND m.valid_to IS NULL
  WHERE hu.id = p_unit_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'unit_not_found',
      'Shared unit not found or caller is not a member of it.',
      'P0002'
    );
  END IF;

  DELETE FROM public.home_unit_members
  WHERE unit_id = p_unit_id
    AND membership_id = v_membership_id;

  UPDATE public.home_units hu
  SET archived_at = COALESCE(hu.archived_at, now())
  WHERE hu.id = p_unit_id
    AND hu.archived_at IS NULL
    AND (
      SELECT COUNT(*)
      FROM public.home_unit_members hum
      JOIN public.memberships m
        ON m.id = hum.membership_id
       AND m.valid_to IS NULL
      WHERE hum.unit_id = p_unit_id
    ) < 2;

  PERFORM public._home_units__reconcile_member_projection(v_home_id);

  RETURN p_unit_id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_leave_shared(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_leave_shared(uuid)
TO authenticated;

/* ---------------------------------------------------------------------
   2) Shopping list scope + recency-aware memory
   - simplify purchase memory to "recently bought"
   - add composite FK so unit_id must belong to same home
--------------------------------------------------------------------- */

ALTER TABLE public.shopping_list_items
  ADD COLUMN IF NOT EXISTS scope_type text NOT NULL DEFAULT 'house',
  ADD COLUMN IF NOT EXISTS unit_id uuid NULL;

ALTER TABLE public.shopping_list_items
  DROP CONSTRAINT IF EXISTS chk_shopping_list_items_scope_shape;

ALTER TABLE public.shopping_list_items
  ADD CONSTRAINT chk_shopping_list_items_scope_shape
  CHECK (
    (scope_type = 'house' AND unit_id IS NULL)
    OR
    (scope_type = 'unit' AND unit_id IS NOT NULL)
  );

ALTER TABLE public.shopping_list_items
  DROP CONSTRAINT IF EXISTS fk_shopping_list_items_unit_id;

ALTER TABLE public.shopping_list_items
  DROP CONSTRAINT IF EXISTS fk_shopping_list_items_unit_home;

ALTER TABLE public.shopping_list_items
  ADD CONSTRAINT fk_shopping_list_items_unit_home
  FOREIGN KEY (unit_id, home_id)
  REFERENCES public.home_units(id, home_id)
  ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_shopping_list_items_scope_visibility
  ON public.shopping_list_items (
    home_id,
    archived_at,
    scope_type,
    unit_id,
    is_completed,
    completed_at DESC,
    created_at DESC
  );

CREATE OR REPLACE FUNCTION public._shopping_list__rehome_open_items_from_archived_unit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.archived_at IS NULL
     AND NEW.archived_at IS NOT NULL
     AND NEW.unit_type = 'shared' THEN
    UPDATE public.shopping_list_items i
    SET
      scope_type = 'house',
      unit_id = NULL,
      updated_at = now()
    WHERE i.home_id = NEW.home_id
      AND i.archived_at IS NULL
      AND i.is_completed = FALSE
      AND i.scope_type = 'unit'
      AND i.unit_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__rehome_open_items_from_archived_unit()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_shopping_list_rehome_archived_shared_unit
ON public.home_units;

CREATE TRIGGER trg_shopping_list_rehome_archived_shared_unit
AFTER UPDATE OF archived_at
ON public.home_units
FOR EACH ROW
EXECUTE FUNCTION public._shopping_list__rehome_open_items_from_archived_unit();

CREATE TABLE IF NOT EXISTS public.shopping_list_purchase_memory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  scope_type text NOT NULL CHECK (scope_type IN ('house', 'unit')),
  unit_id uuid NULL,
  canonical_name text NOT NULL,
  display_name text NOT NULL,
  last_purchased_at timestamptz NOT NULL,
  last_purchased_by_user_id uuid NOT NULL,
  warning_window_days integer NOT NULL CHECK (warning_window_days >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_shopping_list_purchase_memory_scope_shape CHECK (
    (scope_type = 'house' AND unit_id IS NULL)
    OR
    (scope_type = 'unit' AND unit_id IS NOT NULL)
  ),
  CONSTRAINT chk_shopping_list_purchase_memory_canonical_name CHECK (btrim(canonical_name) <> ''),
  CONSTRAINT fk_shopping_list_purchase_memory_unit_home
    FOREIGN KEY (unit_id, home_id)
    REFERENCES public.home_units(id, home_id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_shopping_list_purchase_memory_house
  ON public.shopping_list_purchase_memory (home_id, canonical_name)
  WHERE scope_type = 'house';

CREATE UNIQUE INDEX IF NOT EXISTS uq_shopping_list_purchase_memory_unit
  ON public.shopping_list_purchase_memory (home_id, unit_id, canonical_name)
  WHERE scope_type = 'unit';

ALTER TABLE public.shopping_list_purchase_memory ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.shopping_list_purchase_memory
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_shopping_list_purchase_memory_updated_at ON public.shopping_list_purchase_memory;
CREATE TRIGGER trg_shopping_list_purchase_memory_updated_at
BEFORE UPDATE ON public.shopping_list_purchase_memory
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

CREATE OR REPLACE FUNCTION public._shopping_list__canonicalize_token(
  p_token text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_token text := lower(btrim(coalesce(p_token, '')));
BEGIN
  IF v_token = '' THEN
    RETURN '';
  END IF;

  IF length(v_token) > 4 AND v_token ~ 'ies$' THEN
    RETURN left(v_token, length(v_token) - 3) || 'y';
  END IF;

  IF length(v_token) > 4 AND v_token ~ 'oes$' THEN
    RETURN left(v_token, length(v_token) - 2);
  END IF;

  IF length(v_token) > 4 AND v_token ~ '(ches|shes|xes|zes|ses)$' THEN
    RETURN left(v_token, length(v_token) - 2);
  END IF;

  IF length(v_token) > 3 AND v_token LIKE '%s' AND v_token NOT LIKE '%ss' THEN
    RETURN left(v_token, length(v_token) - 1);
  END IF;

  RETURN v_token;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__canonicalize_token(text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__canonicalize_name(
  p_name text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH cleaned AS (
    SELECT regexp_replace(
      lower(btrim(coalesce(p_name, ''))),
      '[^a-z0-9]+',
      ' ',
      'g'
    ) AS value
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

REVOKE ALL ON FUNCTION public._shopping_list__canonicalize_name(text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__warning_window_days(
  p_canonical_name text
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE public._shopping_list__canonicalize_name(p_canonical_name)
    WHEN 'milk' THEN 7
    WHEN 'bread' THEN 7
    WHEN 'banana' THEN 7
    WHEN 'lettuce' THEN 7
    WHEN 'tomato' THEN 7
    WHEN 'chicken' THEN 7
    WHEN 'egg' THEN 7
    WHEN 'toilet paper' THEN 30
    WHEN 'paper towel' THEN 30
    WHEN 'pasta' THEN 60
    WHEN 'rice' THEN 60
    WHEN 'flour' THEN 60
    WHEN 'sugar' THEN 60
    ELSE 14
  END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__warning_window_days(text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__assert_scope_target(
  p_home_id uuid,
  p_scope_type text,
  p_unit_id uuid
)
RETURNS TABLE (
  scope_type text,
  unit_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_personal_unit_id uuid;
  v_shared_unit_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  PERFORM public._home_units__ensure_personal(p_home_id, v_membership_id, v_user);

  SELECT hu.id
  INTO v_personal_unit_id
  FROM public.home_units hu
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'personal'
    AND hu.personal_membership_id = v_membership_id
    AND hu.archived_at IS NULL
  LIMIT 1;

  SELECT hu.id
  INTO v_shared_unit_id
  FROM public.home_units hu
  JOIN public.home_unit_members hum
    ON hum.unit_id = hu.id
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
    AND hum.membership_id = v_membership_id
    AND hum.is_active_shared = TRUE
  LIMIT 1;

  IF p_scope_type = 'house' THEN
    IF p_unit_id IS NOT NULL THEN
      PERFORM public.api_error(
        'invalid_unit_scope',
        'House-scoped items must not include a unit_id.',
        '22023'
      );
    END IF;

    RETURN QUERY SELECT 'house'::text, NULL::uuid;
    RETURN;
  END IF;

  IF p_scope_type <> 'unit' THEN
    PERFORM public.api_error(
      'invalid_scope_type',
      'Scope type must be house or unit.',
      '22023'
    );
  END IF;

  IF p_unit_id IS NULL THEN
    PERFORM public.api_error(
      'invalid_unit_scope',
      'Unit-scoped items must include a unit_id.',
      '22023'
    );
  END IF;

  IF v_shared_unit_id IS NOT NULL THEN
    IF p_unit_id <> v_shared_unit_id THEN
      PERFORM public.api_error(
        'invalid_unit_scope',
        'Caller may only target their active shared unit.',
        '42501'
      );
    END IF;
  ELSE
    IF p_unit_id <> v_personal_unit_id THEN
      PERFORM public.api_error(
        'invalid_unit_scope',
        'Caller may only target their personal unit.',
        '42501'
      );
    END IF;
  END IF;

  RETURN QUERY SELECT 'unit'::text, p_unit_id;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__assert_scope_target(uuid, text, uuid)
FROM PUBLIC, anon, authenticated;

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
BEGIN
  SELECT
    pm.last_purchased_at,
    p.username AS last_purchased_by_display_name,
    floor(extract(epoch FROM (now() - pm.last_purchased_at)) / 86400)::integer AS days_since_last_purchase,
    pm.warning_window_days
  INTO v_row
  FROM public.shopping_list_purchase_memory pm
  LEFT JOIN public.profiles p
    ON p.id = pm.last_purchased_by_user_id
  WHERE pm.home_id = p_home_id
    AND pm.scope_type = p_scope_type
    AND pm.canonical_name = public._shopping_list__canonicalize_name(p_name)
    AND (
      (p_scope_type = 'house' AND pm.unit_id IS NULL)
      OR
      (p_scope_type = 'unit' AND pm.unit_id = p_unit_id)
    )
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
      public._shopping_list__canonicalize_name(i.name)
    )
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name(i.name) AS canonical_name,
      btrim(i.name) AS display_name,
      i.completed_by_user_id AS last_purchased_by_user_id,
      i.completed_at AS last_purchased_at,
      i.id
    FROM public.shopping_list_items i
    WHERE i.id = ANY(p_item_ids)
      AND i.is_completed = TRUE
      AND i.completed_by_user_id IS NOT NULL
      AND i.completed_at IS NOT NULL
    ORDER BY
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name(i.name),
      i.completed_at DESC,
      i.id ASC
  )
  INSERT INTO public.shopping_list_purchase_memory (
    home_id,
    scope_type,
    unit_id,
    canonical_name,
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
    c.display_name,
    c.last_purchased_at,
    c.last_purchased_by_user_id,
    public._shopping_list__warning_window_days(c.canonical_name)
  FROM latest_candidate c
  WHERE c.scope_type = 'house'
  ON CONFLICT (home_id, canonical_name)
    WHERE scope_type = 'house'
  DO UPDATE
  SET
    display_name = EXCLUDED.display_name,
    last_purchased_at = EXCLUDED.last_purchased_at,
    last_purchased_by_user_id = EXCLUDED.last_purchased_by_user_id,
    warning_window_days = EXCLUDED.warning_window_days;

  WITH latest_candidate AS (
    SELECT DISTINCT ON (
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name(i.name)
    )
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name(i.name) AS canonical_name,
      btrim(i.name) AS display_name,
      i.completed_by_user_id AS last_purchased_by_user_id,
      i.completed_at AS last_purchased_at,
      i.id
    FROM public.shopping_list_items i
    WHERE i.id = ANY(p_item_ids)
      AND i.is_completed = TRUE
      AND i.completed_by_user_id IS NOT NULL
      AND i.completed_at IS NOT NULL
    ORDER BY
      i.home_id,
      i.scope_type,
      i.unit_id,
      public._shopping_list__canonicalize_name(i.name),
      i.completed_at DESC,
      i.id ASC
  )
  INSERT INTO public.shopping_list_purchase_memory (
    home_id,
    scope_type,
    unit_id,
    canonical_name,
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
    c.display_name,
    c.last_purchased_at,
    c.last_purchased_by_user_id,
    public._shopping_list__warning_window_days(c.canonical_name)
  FROM latest_candidate c
  WHERE c.scope_type = 'unit'
  ON CONFLICT (home_id, unit_id, canonical_name)
    WHERE scope_type = 'unit'
  DO UPDATE
  SET
    display_name = EXCLUDED.display_name,
    last_purchased_at = EXCLUDED.last_purchased_at,
    last_purchased_by_user_id = EXCLUDED.last_purchased_by_user_id,
    warning_window_days = EXCLUDED.warning_window_days;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__write_purchase_memory(uuid[])
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__add_item_core(
  p_home_id uuid,
  p_name text,
  p_quantity text,
  p_details text,
  p_reference_photo_path text,
  p_scope_type text,
  p_unit_id uuid
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
  v_resolved_scope record;
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

  SELECT *
  INTO v_resolved_scope
  FROM public._shopping_list__assert_scope_target(p_home_id, p_scope_type, p_unit_id);

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
    reference_added_by_user_id,
    scope_type,
    unit_id
  )
  VALUES (
    v_list.id,
    p_home_id,
    v_user,
    btrim(p_name),
    p_quantity,
    p_details,
    p_reference_photo_path,
    CASE WHEN p_reference_photo_path IS NULL THEN NULL ELSE v_user END,
    v_resolved_scope.scope_type,
    v_resolved_scope.unit_id
  )
  RETURNING * INTO v_item;

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__add_item_core(uuid, text, text, text, text, text, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__build_add_item_payload(
  p_item public.shopping_list_items
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_purchase_memory jsonb;
BEGIN
  v_purchase_memory := public._shopping_list__purchase_memory_payload(
    p_item.home_id,
    p_item.scope_type,
    p_item.unit_id,
    p_item.name
  );

  RETURN jsonb_build_object(
    'item',
    to_jsonb(p_item) || jsonb_build_object('completed_by_avatar_id', NULL),
    'purchase_memory',
    v_purchase_memory
  );
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__build_add_item_payload(public.shopping_list_items)
FROM PUBLIC, anon, authenticated;

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
BEGIN
  RETURN public._shopping_list__add_item_core(
    p_home_id,
    p_name,
    p_quantity,
    p_details,
    p_reference_photo_path,
    'house',
    NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.shopping_list_add_item_v2(
  p_home_id uuid,
  p_name text,
  p_quantity text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_reference_photo_path text DEFAULT NULL,
  p_scope_type text DEFAULT 'house',
  p_unit_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_item public.shopping_list_items;
BEGIN
  v_item := public._shopping_list__add_item_core(
    p_home_id,
    p_name,
    p_quantity,
    p_details,
    p_reference_photo_path,
    p_scope_type,
    p_unit_id
  );

  RETURN public._shopping_list__build_add_item_payload(v_item);
END;
$$;

CREATE OR REPLACE FUNCTION public.shopping_list_get_for_home(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public._shopping_list__get_for_home_core(p_home_id, NULL, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public._shopping_list__get_for_home_core(
  p_home_id uuid,
  p_scope_type text,
  p_unit_id uuid
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
  v_visible_unit_id uuid;
  v_filter_scope_type text;
  v_filter_unit_id uuid;
  v_membership_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  IF p_scope_type IS NOT NULL THEN
    SELECT scope_type, unit_id
    INTO v_filter_scope_type, v_filter_unit_id
    FROM public._shopping_list__assert_scope_target(p_home_id, p_scope_type, p_unit_id);
  ELSE
    SELECT m.id
    INTO v_membership_id
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.user_id = v_user
      AND m.valid_to IS NULL
    LIMIT 1;

    PERFORM public._home_units__ensure_personal(p_home_id, v_membership_id, v_user);

    SELECT hu.id
    INTO v_visible_unit_id
    FROM public.home_units hu
    JOIN public.home_unit_members hum
      ON hum.unit_id = hu.id
    WHERE hu.home_id = p_home_id
      AND hu.unit_type = 'shared'
      AND hu.archived_at IS NULL
      AND hum.membership_id = v_membership_id
      AND hum.is_active_shared = TRUE
    LIMIT 1;

    IF v_visible_unit_id IS NULL THEN
      SELECT hu.id
      INTO v_visible_unit_id
      FROM public.home_units hu
      WHERE hu.home_id = p_home_id
        AND hu.unit_type = 'personal'
        AND hu.personal_membership_id = v_membership_id
        AND hu.archived_at IS NULL
      LIMIT 1;
    END IF;
  END IF;

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

  WITH visible_items AS (
    SELECT
      i.*,
      p.avatar_id AS completed_by_avatar_id,
      hu.name AS unit_name
    FROM public.shopping_list_items i
    LEFT JOIN public.profiles p
      ON p.id = i.completed_by_user_id
    LEFT JOIN public.home_units hu
      ON hu.id = i.unit_id
     AND hu.home_id = i.home_id
    WHERE i.shopping_list_id = v_list.id
      AND i.archived_at IS NULL
      AND (
        (
          p_scope_type IS NOT NULL
          AND (
            (v_filter_scope_type = 'house' AND i.scope_type = 'house')
            OR
            (v_filter_scope_type = 'unit' AND i.scope_type = 'unit' AND i.unit_id = v_filter_unit_id)
          )
        )
        OR
        (
          p_scope_type IS NULL
          AND (
            i.scope_type = 'house'
            OR
            (i.scope_type = 'unit' AND i.unit_id = v_visible_unit_id)
          )
        )
      )
      AND (
        i.is_completed = FALSE
        OR i.completed_by_user_id = v_user
      )
  )
  SELECT
    COALESCE(
      jsonb_agg(
        to_jsonb(vi)
        ORDER BY vi.is_completed ASC, vi.completed_at DESC NULLS LAST, vi.created_at DESC
      ),
      '[]'::jsonb
    ),
    COUNT(*)::int,
    COUNT(*) FILTER (WHERE vi.is_completed = FALSE)::int
  INTO v_items, v_unarchived_count, v_uncompleted_count
  FROM visible_items vi;

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

REVOKE ALL ON FUNCTION public._shopping_list__get_for_home_core(uuid, text, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.shopping_list_get_for_home_v2(
  p_home_id uuid,
  p_scope_type text DEFAULT NULL,
  p_unit_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public._shopping_list__get_for_home_core(
    p_home_id,
    p_scope_type,
    p_unit_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._shopping_list__update_item_core(
  p_item_id uuid,
  p_name text,
  p_quantity text,
  p_details text,
  p_is_completed boolean,
  p_reference_photo_path text,
  p_replace_photo boolean,
  p_scope_type text,
  p_unit_id uuid
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
  v_resolved_scope_type text;
  v_resolved_unit_id uuid;
  v_updated public.shopping_list_items;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT i.*
  INTO v_existing
  FROM public.shopping_list_items i
  JOIN public.memberships m
    ON m.home_id = i.home_id
   AND m.user_id = v_user
   AND m.valid_to IS NULL
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
    IF v_existing.is_completed AND v_existing.completed_by_user_id <> v_user THEN
      PERFORM public.api_error(
        'item_already_completed_by_other',
        'Item is already completed by another member.',
        '42501'
      );
    END IF;

    v_next_is_completed := TRUE;
    v_next_completed_by := COALESCE(v_existing.completed_by_user_id, v_user);
    v_next_completed_at := COALESCE(v_existing.completed_at, now());
  ELSE
    IF v_existing.is_completed AND v_existing.completed_by_user_id <> v_user THEN
      PERFORM public.api_error(
        'item_already_completed_by_other',
        'Only the original completer can clear this item.',
        '42501'
      );
    END IF;

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

  IF p_scope_type IS NULL THEN
    v_resolved_scope_type := v_existing.scope_type;
    v_resolved_unit_id := v_existing.unit_id;
  ELSE
    SELECT scope_type, unit_id
    INTO v_resolved_scope_type, v_resolved_unit_id
    FROM public._shopping_list__assert_scope_target(
      v_existing.home_id,
      p_scope_type,
      p_unit_id
    );
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
    reference_added_by_user_id = v_next_reference_added_by,
    scope_type = v_resolved_scope_type,
    unit_id = v_resolved_unit_id
  WHERE id = p_item_id
  RETURNING * INTO v_updated;

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__update_item_core(uuid, text, text, text, boolean, text, boolean, text, uuid)
FROM PUBLIC, anon, authenticated;

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
BEGIN
  RETURN public._shopping_list__update_item_core(
    p_item_id,
    p_name,
    p_quantity,
    p_details,
    p_is_completed,
    p_reference_photo_path,
    p_replace_photo,
    NULL,
    NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.shopping_list_update_item_v2(
  p_item_id uuid,
  p_name text,
  p_quantity text,
  p_details text,
  p_is_completed boolean,
  p_reference_photo_path text,
  p_replace_photo boolean,
  p_scope_type text,
  p_unit_id uuid
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public._shopping_list__update_item_core(
    p_item_id,
    p_name,
    p_quantity,
    p_details,
    p_is_completed,
    p_reference_photo_path,
    p_replace_photo,
    p_scope_type,
    p_unit_id
  );
END;
$$;

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
  v_updated_item_ids uuid[];
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  IF p_item_ids IS NULL OR cardinality(p_item_ids) = 0 THEN
    RETURN 0;
  END IF;

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
    RETURNING i.id
  )
  SELECT count(*)::int, array_agg(id)
  INTO v_updated, v_updated_item_ids
  FROM updated;

  IF v_updated > 0 THEN
    PERFORM public._shopping_list__write_purchase_memory(v_updated_item_ids);
  END IF;

  IF v_updated > 0 AND NOT v_had_any_linked THEN
    PERFORM public._home_usage_apply_delta(
      p_home_id,
      jsonb_build_object('active_expenses', 1)
    );
  END IF;

  RETURN v_updated;
END;
$$;

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
  v_updated_item_ids uuid[];
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
    RETURNING i.id
  )
  SELECT count(*)::int, array_agg(id)
  INTO v_updated, v_updated_item_ids
  FROM updated;

  IF v_updated > 0 THEN
    PERFORM public._shopping_list__write_purchase_memory(v_updated_item_ids);
  END IF;

  RETURN v_updated;
END;
$$;

CREATE OR REPLACE FUNCTION public.shopping_list_archive_item(
  p_item_id uuid
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_existing public.shopping_list_items;
  v_updated public.shopping_list_items;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT i.*
  INTO v_existing
  FROM public.shopping_list_items i
  JOIN public.memberships m
    ON m.home_id = i.home_id
   AND m.user_id = v_user
   AND m.valid_to IS NULL
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

  UPDATE public.shopping_list_items
  SET
    archived_at = now(),
    archived_by_user_id = v_user
  WHERE id = p_item_id
  RETURNING * INTO v_updated;

  IF v_updated.is_completed = TRUE THEN
    PERFORM public._shopping_list__write_purchase_memory(ARRAY[v_updated.id]);
  END IF;

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.shopping_list_get_for_home_v2(uuid, text, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_get_for_home_v2(uuid, text, uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_add_item_v2(uuid, text, text, text, text, text, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_add_item_v2(uuid, text, text, text, text, text, uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_update_item_v2(uuid, text, text, text, boolean, text, boolean, text, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_update_item_v2(uuid, text, text, text, boolean, text, boolean, text, uuid)
TO authenticated;

COMMIT;
