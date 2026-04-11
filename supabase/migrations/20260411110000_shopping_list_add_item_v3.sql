BEGIN;

CREATE OR REPLACE FUNCTION public._shopping_list__build_add_item_payload_v2(
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

REVOKE ALL ON FUNCTION public._shopping_list__build_add_item_payload_v2(public.shopping_list_items)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._shopping_list__build_add_item_payload_v3(
  p_item public.shopping_list_items,
  p_purchase_memory jsonb,
  p_needs_confirmation boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN jsonb_build_object(
    'item',
    CASE
      WHEN p_item IS NULL THEN NULL
      ELSE to_jsonb(p_item) || jsonb_build_object('completed_by_avatar_id', NULL)
    END,
    'needs_confirmation',
    COALESCE(p_needs_confirmation, FALSE),
    'purchase_memory',
    p_purchase_memory
  );
END;
$$;

REVOKE ALL ON FUNCTION public._shopping_list__build_add_item_payload_v3(public.shopping_list_items, jsonb, boolean)
FROM PUBLIC, anon, authenticated;

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

  RETURN public._shopping_list__build_add_item_payload_v2(v_item);
END;
$$;

DROP FUNCTION IF EXISTS public._shopping_list__build_add_item_payload(public.shopping_list_items);

CREATE OR REPLACE FUNCTION public.shopping_list_add_item_v3(
  p_home_id uuid,
  p_name text,
  p_quantity text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_reference_photo_path text DEFAULT NULL,
  p_scope_type text DEFAULT 'house',
  p_unit_id uuid DEFAULT NULL,
  p_confirm_recent_purchase boolean DEFAULT FALSE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_resolved_scope record;
  v_purchase_memory jsonb := NULL;
  v_item public.shopping_list_items;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT *
  INTO v_resolved_scope
  FROM public._shopping_list__assert_scope_target(
    p_home_id,
    p_scope_type,
    p_unit_id
  );

  BEGIN
    v_purchase_memory := public._shopping_list__purchase_memory_payload(
      p_home_id,
      v_resolved_scope.scope_type,
      v_resolved_scope.unit_id,
      p_name
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_purchase_memory := NULL;
  END;

  IF v_purchase_memory IS NOT NULL
     AND COALESCE(p_confirm_recent_purchase, FALSE) = FALSE THEN
    RETURN public._shopping_list__build_add_item_payload_v3(
      NULL::public.shopping_list_items,
      v_purchase_memory,
      TRUE
    );
  END IF;

  v_item := public._shopping_list__add_item_core(
    p_home_id,
    p_name,
    p_quantity,
    p_details,
    p_reference_photo_path,
    p_scope_type,
    p_unit_id
  );

  RETURN public._shopping_list__build_add_item_payload_v3(
    v_item,
    v_purchase_memory,
    FALSE
  );
END;
$$;

REVOKE ALL ON FUNCTION public.shopping_list_add_item_v2(uuid, text, text, text, text, text, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_add_item_v2(uuid, text, text, text, text, text, uuid)
TO authenticated;

REVOKE ALL ON FUNCTION public.shopping_list_add_item_v3(uuid, text, text, text, text, text, uuid, boolean)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_add_item_v3(uuid, text, text, text, text, text, uuid, boolean)
TO authenticated;

COMMIT;
