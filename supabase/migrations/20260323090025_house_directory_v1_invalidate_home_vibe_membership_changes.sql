-- House Directory v1
-- Adjusted architecture:
-- - Wi-Fi is a separate top-level feature block on the Directory page
-- - Home directory content RPC returns shared directory content only (services + links)
-- - Due reminders are fetched separately for the Today page
-- - Reminder configuration is edited through the underlying home directory service
-- - Wi-Fi raw password is intentionally never returned by public RPCs
-- - Wi-Fi QR generation assumes a simplified consumer-wifi model
-- - service/link upserts use replace semantics, not patch semantics
-- - validation is intentionally duplicated:
--     * RPC validation = stable domain-friendly API errors
--     * table constraints = final integrity guardrails
-- - tables are RPC-only:
--     * direct table access is revoked from anon/authenticated
--     * SECURITY DEFINER functions enforce authorization
--     * RLS is enabled as a deny-by-default safeguard for non-RPC access
-- - backend reminder truth uses UTC date logic for now
-- - UI may localize date display separately
-- - term_end_date is an inclusive human date
-- - Wi-Fi QR support note: Works for most standard home Wi-Fi networks.

-- ---------------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.home_directory_wifi (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  ssid text NOT NULL,
  password text NULL,
  created_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT home_directory_wifi_home_unique UNIQUE (home_id),
  CONSTRAINT home_directory_wifi_ssid_check
    CHECK (char_length(btrim(ssid)) BETWEEN 1 AND 64),
  CONSTRAINT home_directory_wifi_password_check
    CHECK (
      password IS NULL
      OR (
        char_length(password) <= 128
        AND btrim(password) <> ''
      )
    )
);

COMMENT ON TABLE public.home_directory_wifi IS
  'Current-state Wi-Fi details for a home. Intentionally does not preserve history.';
COMMENT ON COLUMN public.home_directory_wifi.password IS
  'Stored server-side for QR generation and owner updates. Never returned by public RPC responses. Works for most standard home Wi-Fi networks.';

CREATE TABLE IF NOT EXISTS public.home_directory_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  service_type text NOT NULL,
  custom_label text NULL,
  provider_name text NOT NULL,
  account_reference text NULL,
  link_url text NULL,
  term_start_date date NULL,
  term_end_date date NULL,
  renewal_reminder_offset_value integer NULL,
  renewal_reminder_offset_unit text NULL,
  notes text NULL,
  archived_at timestamptz NULL,
  created_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT home_directory_services_service_type_check
    CHECK (service_type IN ('rent', 'internet', 'electricity', 'gas', 'water', 'other')),
  CONSTRAINT home_directory_services_other_custom_label_check
    CHECK (
      (service_type = 'other' AND char_length(btrim(COALESCE(custom_label, ''))) BETWEEN 1 AND 40)
      OR
      (service_type <> 'other' AND custom_label IS NULL)
    ),
  CONSTRAINT home_directory_services_provider_name_check
    CHECK (char_length(btrim(provider_name)) BETWEEN 1 AND 120),
  CONSTRAINT home_directory_services_account_reference_check
    CHECK (account_reference IS NULL OR char_length(account_reference) <= 120),
  CONSTRAINT home_directory_services_link_url_check
    CHECK (
      link_url IS NULL
      OR (
        char_length(link_url) <= 2048
        AND link_url ~* '^https?://'
      )
    ),
  CONSTRAINT home_directory_services_term_range_check
    CHECK (
      (term_start_date IS NULL AND term_end_date IS NULL)
      OR
      (term_start_date IS NOT NULL AND term_end_date IS NOT NULL AND term_start_date <= term_end_date)
    ),
  CONSTRAINT home_directory_services_rent_term_required_check
    CHECK (
      service_type <> 'rent'
      OR
      (term_start_date IS NOT NULL AND term_end_date IS NOT NULL)
    ),
  CONSTRAINT home_directory_services_offset_pair_check
    CHECK (
      (renewal_reminder_offset_value IS NULL AND renewal_reminder_offset_unit IS NULL)
      OR
      (renewal_reminder_offset_value IS NOT NULL AND renewal_reminder_offset_unit IS NOT NULL)
    ),
  CONSTRAINT home_directory_services_offset_value_check
    CHECK (
      renewal_reminder_offset_value IS NULL
      OR renewal_reminder_offset_value >= 1
    ),
  CONSTRAINT home_directory_services_offset_unit_check
    CHECK (
      renewal_reminder_offset_unit IS NULL
      OR renewal_reminder_offset_unit IN ('day', 'week', 'month')
    ),
  CONSTRAINT home_directory_services_notes_check
    CHECK (notes IS NULL OR char_length(notes) <= 2000)
);

COMMENT ON TABLE public.home_directory_services IS
  'Shared home directory services. Reminder timing is configured on the service row and surfaced on the Today page when due.';

CREATE TABLE IF NOT EXISTS public.home_directory_service_reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id uuid NOT NULL REFERENCES public.home_directory_services(id) ON DELETE CASCADE,
  reminder_kind text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  term_start_date date NOT NULL,
  term_end_date date NOT NULL,
  due_at date NOT NULL,
  dismissed_at timestamptz NULL,
  dismissed_by_user_id uuid NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT home_directory_service_reminders_kind_check
    CHECK (reminder_kind = 'renewal'),
  CONSTRAINT home_directory_service_reminders_status_check
    CHECK (status IN ('active', 'dismissed', 'retired')),
  CONSTRAINT home_directory_service_reminders_term_check
    CHECK (term_start_date <= term_end_date),
  CONSTRAINT home_directory_service_reminders_due_at_check
    CHECK (term_start_date <= due_at AND due_at <= term_end_date),
  CONSTRAINT home_directory_service_reminders_status_alignment_check
    CHECK (
      (status = 'active' AND dismissed_at IS NULL AND dismissed_by_user_id IS NULL)
      OR
      (status = 'dismissed' AND dismissed_at IS NOT NULL AND dismissed_by_user_id IS NOT NULL)
      OR
      (
        status = 'retired'
        AND (
          (dismissed_at IS NULL AND dismissed_by_user_id IS NULL)
          OR
          (dismissed_at IS NOT NULL AND dismissed_by_user_id IS NOT NULL)
        )
      )
    ),
  CONSTRAINT home_directory_service_reminders_identity_unique
    UNIQUE (service_id, reminder_kind, term_start_date, term_end_date)
);

COMMENT ON TABLE public.home_directory_service_reminders IS
  'Materialized reminder projection for a service term. Retired rows preserve superseded reminder history.';

CREATE TABLE IF NOT EXISTS public.home_directory_service_reminder_acknowledgements (
  reminder_id uuid NOT NULL REFERENCES public.home_directory_service_reminders(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  acknowledged_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (reminder_id, user_id)
);

COMMENT ON TABLE public.home_directory_service_reminder_acknowledgements IS
  'Per-member acknowledgement state for reminders. Used to hide a due reminder for that member after they explicitly acknowledge it.';

CREATE TABLE IF NOT EXISTS public.home_directory_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  title text NOT NULL,
  url text NOT NULL,
  tag text NOT NULL,
  custom_tag text NULL,
  start_date date NULL,
  end_date date NULL,
  archived_at timestamptz NULL,
  created_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT home_directory_links_tag_check
    CHECK (tag IN ('rent', 'bond', 'utilities', 'other')),
  CONSTRAINT home_directory_links_other_custom_tag_check
    CHECK (
      (tag = 'other' AND char_length(btrim(COALESCE(custom_tag, ''))) BETWEEN 1 AND 24)
      OR
      (tag <> 'other' AND custom_tag IS NULL)
    ),
  CONSTRAINT home_directory_links_title_check
    CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  CONSTRAINT home_directory_links_url_check
    CHECK (
      char_length(url) <= 2048
      AND url ~* '^https?://'
    ),
  CONSTRAINT home_directory_links_date_range_check
    CHECK (
      (start_date IS NULL AND end_date IS NULL)
      OR
      (start_date IS NOT NULL AND end_date IS NOT NULL AND start_date <= end_date)
    )
);

COMMENT ON TABLE public.home_directory_links IS
  'Shared home directory links. Tag can remain other until stable category requirements emerge.';

-- ---------------------------------------------------------------------------
-- INDEXES
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_home_directory_services_home_active
  ON public.home_directory_services (home_id, created_at DESC, id)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_home_directory_services_home_type_active
  ON public.home_directory_services (home_id, service_type, id)
  WHERE archived_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_directory_services_one_active_rent_per_home
  ON public.home_directory_services (home_id)
  WHERE archived_at IS NULL AND service_type = 'rent';

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_directory_services_one_active_internet_per_home
  ON public.home_directory_services (home_id)
  WHERE archived_at IS NULL AND service_type = 'internet';

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_directory_services_one_active_electricity_per_home
  ON public.home_directory_services (home_id)
  WHERE archived_at IS NULL AND service_type = 'electricity';

CREATE INDEX IF NOT EXISTS idx_home_directory_links_home_active
  ON public.home_directory_links (home_id, created_at DESC, id)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_home_directory_service_reminders_service_status_due
  ON public.home_directory_service_reminders (service_id, status, due_at);

CREATE INDEX IF NOT EXISTS idx_home_directory_service_reminder_acks_user_acknowledged
  ON public.home_directory_service_reminder_acknowledgements (user_id, acknowledged_at DESC);

-- ---------------------------------------------------------------------------
-- RLS / PERMISSIONS
-- ---------------------------------------------------------------------------

ALTER TABLE public.home_directory_wifi ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_directory_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_directory_service_reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_directory_service_reminder_acknowledgements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_directory_links ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.home_directory_wifi,
  public.home_directory_services,
  public.home_directory_service_reminders,
  public.home_directory_service_reminder_acknowledgements,
  public.home_directory_links
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- UPDATED_AT TRIGGERS
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_home_directory_wifi_touch_updated_at ON public.home_directory_wifi;
CREATE TRIGGER trg_home_directory_wifi_touch_updated_at
BEFORE UPDATE ON public.home_directory_wifi
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

DROP TRIGGER IF EXISTS trg_home_directory_services_touch_updated_at ON public.home_directory_services;
CREATE TRIGGER trg_home_directory_services_touch_updated_at
BEFORE UPDATE ON public.home_directory_services
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

DROP TRIGGER IF EXISTS trg_home_directory_service_reminders_touch_updated_at ON public.home_directory_service_reminders;
CREATE TRIGGER trg_home_directory_service_reminders_touch_updated_at
BEFORE UPDATE ON public.home_directory_service_reminders
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

DROP TRIGGER IF EXISTS trg_home_directory_links_touch_updated_at ON public.home_directory_links;
CREATE TRIGGER trg_home_directory_links_touch_updated_at
BEFORE UPDATE ON public.home_directory_links
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._house_directory_assert_owner(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM public._assert_authenticated();

  IF NOT public.is_home_owner(p_home_id, auth.uid()) THEN
    PERFORM public.api_error(
      'FORBIDDEN_OWNER_ONLY',
      'Only the home owner can perform this action.',
      '42501',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public._house_directory_escape_qr_part(
  p_value text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT replace(
           replace(
             replace(
               replace(COALESCE(p_value, ''), E'\\', E'\\\\'),
               ';', E'\\;'
             ),
             ',', E'\\,'
           ),
           ':', E'\\:'
         );
$$;

CREATE OR REPLACE FUNCTION public._house_directory_build_wifi_qr(
  p_ssid text,
  p_password text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_ssid text := public._house_directory_escape_qr_part(p_ssid);
  v_password text := public._house_directory_escape_qr_part(p_password);
BEGIN
  -- Simplified consumer-wifi assumption.
  -- Works for most standard home Wi-Fi networks.
  -- - open network => nopass
  -- - password-based network => WPA
  -- Hidden SSIDs, enterprise auth, and uncommon security modes are out of scope for v1.
  IF p_password IS NULL THEN
    RETURN format('WIFI:T:nopass;S:%s;;', v_ssid);
  END IF;

  RETURN format('WIFI:T:WPA;S:%s;P:%s;;', v_ssid, v_password);
END;
$$;

CREATE OR REPLACE FUNCTION public._house_directory_today_utc()
RETURNS date
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT (now() AT TIME ZONE 'UTC')::date;
$$;

CREATE OR REPLACE FUNCTION public._house_directory_compute_renewal_due_at(
  p_term_start_date date,
  p_term_end_date date,
  p_offset_value integer,
  p_offset_unit text
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_offset_value integer := COALESCE(p_offset_value, 3);
  v_offset_unit text := COALESCE(p_offset_unit, 'month');
  v_due_at date;
BEGIN
  IF p_term_start_date IS NULL OR p_term_end_date IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_offset_value < 1 THEN
    RETURN NULL;
  END IF;

  IF v_offset_unit = 'day' THEN
    v_due_at := (p_term_end_date::timestamp - make_interval(days => v_offset_value))::date;
  ELSIF v_offset_unit = 'week' THEN
    v_due_at := (p_term_end_date::timestamp - make_interval(days => v_offset_value * 7))::date;
  ELSIF v_offset_unit = 'month' THEN
    v_due_at := (p_term_end_date::timestamp - make_interval(months => v_offset_value))::date;
  ELSE
    RETURN NULL;
  END IF;

  IF v_due_at < p_term_start_date OR v_due_at > p_term_end_date THEN
    RETURN NULL;
  END IF;

  RETURN v_due_at;
END;
$$;

CREATE OR REPLACE FUNCTION public._house_directory_assert_valid_reminder_offset(
  p_term_start_date date,
  p_term_end_date date,
  p_offset_value integer,
  p_offset_unit text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_due_at date;
BEGIN
  IF p_offset_value IS NULL AND p_offset_unit IS NULL THEN
    RETURN;
  END IF;

  v_due_at := public._house_directory_compute_renewal_due_at(
    p_term_start_date,
    p_term_end_date,
    p_offset_value,
    p_offset_unit
  );

  PERFORM public.api_assert(
    v_due_at IS NOT NULL,
    'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
    'Reminder offset falls outside the service term.',
    '22023',
    jsonb_build_object(
      'term_start_date', p_term_start_date,
      'term_end_date', p_term_end_date,
      'renewal_reminder_offset_value', p_offset_value,
      'renewal_reminder_offset_unit', p_offset_unit
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._house_directory_reconcile_service_reminder(
  p_service_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_service public.home_directory_services%ROWTYPE;
  v_due_at date;
  v_target public.home_directory_service_reminders%ROWTYPE;
  v_had_target boolean := false;
  v_material_change boolean := false;
BEGIN
  -- Lock the service row first.
  SELECT *
    INTO v_service
  FROM public.home_directory_services
  WHERE id = p_service_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_SERVICE_NOT_FOUND',
      'House directory service was not found.',
      'P0002',
      jsonb_build_object('service_id', p_service_id)
    );
  END IF;

  -- Archived service => retire all reminder rows for that service.
  IF v_service.archived_at IS NOT NULL THEN
    UPDATE public.home_directory_service_reminders r
       SET status = 'retired'
     WHERE r.service_id = v_service.id
       AND r.reminder_kind = 'renewal'
       AND r.status <> 'retired';

    RETURN;
  END IF;

  v_due_at := public._house_directory_compute_renewal_due_at(
    v_service.term_start_date,
    v_service.term_end_date,
    v_service.renewal_reminder_offset_value,
    v_service.renewal_reminder_offset_unit
  );

  -- No valid due date => retire all reminder rows for that service.
  IF v_due_at IS NULL THEN
    UPDATE public.home_directory_service_reminders r
       SET status = 'retired'
     WHERE r.service_id = v_service.id
       AND r.reminder_kind = 'renewal'
       AND r.status <> 'retired';

    RETURN;
  END IF;

  -- Find the current non-retired reminder row for the current term, if any.
  SELECT *
    INTO v_target
  FROM public.home_directory_service_reminders r
  WHERE r.service_id = v_service.id
    AND r.reminder_kind = 'renewal'
    AND r.term_start_date = v_service.term_start_date
    AND r.term_end_date = v_service.term_end_date
    AND r.status <> 'retired'
  FOR UPDATE;

  v_had_target := FOUND;

  IF NOT v_had_target THEN
    -- There is no current live reminder row for this term, but there may be
    -- a retired row already occupying the unique key. Reopen/refresh it.
    UPDATE public.home_directory_service_reminders r
       SET due_at = v_due_at,
           status = 'active',
           dismissed_at = NULL,
           dismissed_by_user_id = NULL
     WHERE r.service_id = v_service.id
       AND r.reminder_kind = 'renewal'
       AND r.term_start_date = v_service.term_start_date
       AND r.term_end_date = v_service.term_end_date
    RETURNING * INTO v_target;

    IF FOUND THEN
      v_material_change := true;
    ELSE
      INSERT INTO public.home_directory_service_reminders (
        service_id,
        reminder_kind,
        status,
        term_start_date,
        term_end_date,
        due_at
      )
      VALUES (
        v_service.id,
        'renewal',
        'active',
        v_service.term_start_date,
        v_service.term_end_date,
        v_due_at
      )
      RETURNING * INTO v_target;

      v_material_change := true;
    END IF;
  ELSE
    -- Compare old vs new state explicitly.
    v_material_change :=
      v_target.due_at IS DISTINCT FROM v_due_at
      OR v_target.status <> 'active';

    IF v_material_change THEN
      UPDATE public.home_directory_service_reminders r
         SET due_at = v_due_at,
             status = 'active',
             dismissed_at = NULL,
             dismissed_by_user_id = NULL
       WHERE r.id = v_target.id
      RETURNING * INTO v_target;
    END IF;
  END IF;

  -- If materially changed, reopen visibility for members.
  IF v_material_change THEN
    DELETE FROM public.home_directory_service_reminder_acknowledgements ra
    WHERE ra.reminder_id = v_target.id;
  END IF;

  -- Retire any other reminder rows for this service that are no longer current.
  UPDATE public.home_directory_service_reminders r
     SET status = 'retired'
   WHERE r.service_id = v_service.id
     AND r.reminder_kind = 'renewal'
     AND r.id <> v_target.id
     AND r.status <> 'retired';

END;
$$;

CREATE OR REPLACE FUNCTION public._house_directory_due_reminders_json(
  p_home_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH due_rows AS (
    SELECT
      r.id,
      r.service_id,
      r.reminder_kind,
      r.status,
      r.term_start_date,
      r.term_end_date,
      r.due_at,
      r.dismissed_at,
      r.dismissed_by_user_id,
      s.service_type,
      s.provider_name,
      s.custom_label,
      s.link_url
    FROM public.home_directory_service_reminders r
    JOIN public.home_directory_services s
      ON s.id = r.service_id
    WHERE s.home_id = p_home_id
      AND r.reminder_kind = 'renewal'
      AND r.status = 'active'
      AND s.archived_at IS NULL
      AND s.term_start_date = r.term_start_date
      AND s.term_end_date = r.term_end_date
      AND public._house_directory_today_utc() >= r.due_at
      AND NOT EXISTS (
        SELECT 1
        FROM public.home_directory_service_reminder_acknowledgements ra
        WHERE ra.reminder_id = r.id
          AND ra.user_id = p_user_id
      )
  )
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', d.id,
               'service_id', d.service_id,
               'reminder_kind', d.reminder_kind,
               'status', d.status,
               'term_start_date', d.term_start_date,
               'term_end_date', d.term_end_date,
               'due_at', d.due_at,
               'service_type', d.service_type,
               'provider_name', d.provider_name,
               'custom_label', d.custom_label,
               'link_url', d.link_url,
               'acknowledged_by_me', false
             )
             ORDER BY d.due_at, lower(d.provider_name), d.service_id
           ),
           '[]'::jsonb
         )
  FROM due_rows d;
$$;

-- ---------------------------------------------------------------------------
-- WIFI READ / WRITE RPCS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_home_directory_wifi(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_wifi jsonb := NULL;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT jsonb_build_object(
           'id', w.id,
           'home_id', w.home_id,
           'ssid', w.ssid,
           'qr_payload', public._house_directory_build_wifi_qr(w.ssid, w.password),
           'created_at', w.created_at,
           'updated_at', w.updated_at
         )
    INTO v_wifi
  FROM public.home_directory_wifi w
  WHERE w.home_id = p_home_id;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'wifi', v_wifi
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_home_directory_wifi(
  p_home_id uuid,
  p_ssid text,
  p_password text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_ssid text := nullif(btrim(p_ssid), '');
  v_password text := p_password;
  v_row public.home_directory_wifi%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  PERFORM public.api_assert(
    v_ssid IS NOT NULL,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'SSID is required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_ssid) BETWEEN 1 AND 64,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'SSID must be between 1 and 64 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    v_password IS NULL OR btrim(v_password) <> '',
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'Wi-Fi password cannot be whitespace-only.',
    '22023'
  );

  PERFORM public.api_assert(
    v_password IS NULL OR char_length(v_password) <= 128,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'Wi-Fi password must be 128 characters or fewer.',
    '22023'
  );

  INSERT INTO public.home_directory_wifi (
    home_id,
    ssid,
    password,
    created_by_user_id,
    updated_by_user_id
  )
  VALUES (
    p_home_id,
    v_ssid,
    v_password,
    v_user,
    v_user
  )
  ON CONFLICT (home_id)
  DO UPDATE
     SET ssid = EXCLUDED.ssid,
         password = EXCLUDED.password,
         updated_by_user_id = EXCLUDED.updated_by_user_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'wifi', jsonb_build_object(
      'id', v_row.id,
      'home_id', v_row.home_id,
      'ssid', v_row.ssid,
      'qr_payload', public._house_directory_build_wifi_qr(v_row.ssid, v_row.password),
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- HOME DIRECTORY CONTENT READ RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_home_directory_content(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_services jsonb := '[]'::jsonb;
  v_links jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', s.id,
               'home_id', s.home_id,
               'service_type', s.service_type,
               'custom_label', s.custom_label,
               'provider_name', s.provider_name,
               'account_reference', s.account_reference,
               'link_url', s.link_url,
               'term_start_date', s.term_start_date,
               'term_end_date', s.term_end_date,
               'renewal_reminder_offset_value', s.renewal_reminder_offset_value,
               'renewal_reminder_offset_unit', s.renewal_reminder_offset_unit,
               'notes', s.notes,
               'created_at', s.created_at,
               'updated_at', s.updated_at
             )
             ORDER BY lower(s.provider_name), s.created_at DESC, s.id
           ),
           '[]'::jsonb
         )
    INTO v_services
  FROM public.home_directory_services s
  WHERE s.home_id = p_home_id
    AND s.archived_at IS NULL;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', l.id,
               'home_id', l.home_id,
               'title', l.title,
               'url', l.url,
               'tag', l.tag,
               'custom_tag', l.custom_tag,
               'start_date', l.start_date,
               'end_date', l.end_date,
               'created_at', l.created_at,
               'updated_at', l.updated_at
             )
             ORDER BY lower(l.title), l.created_at DESC, l.id
           ),
           '[]'::jsonb
         )
    INTO v_links
  FROM public.home_directory_links l
  WHERE l.home_id = p_home_id
    AND l.archived_at IS NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'services', v_services,
    'links', v_links
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- SERVICE RPCS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.upsert_home_directory_service(
  p_home_id uuid,
  p_service_id uuid DEFAULT NULL,
  p_service_type text DEFAULT NULL,
  p_custom_label text DEFAULT NULL,
  p_provider_name text DEFAULT NULL,
  p_account_reference text DEFAULT NULL,
  p_link_url text DEFAULT NULL,
  p_term_start_date date DEFAULT NULL,
  p_term_end_date date DEFAULT NULL,
  p_renewal_reminder_offset_value integer DEFAULT NULL,
  p_renewal_reminder_offset_unit text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_service public.home_directory_services%ROWTYPE;
  v_service_type text := lower(nullif(btrim(p_service_type), ''));
  v_custom_label text := nullif(btrim(p_custom_label), '');
  v_provider_name text := nullif(btrim(p_provider_name), '');
  v_account_reference text := nullif(btrim(p_account_reference), '');
  v_link_url text := nullif(btrim(p_link_url), '');
  v_offset_unit text := lower(nullif(btrim(p_renewal_reminder_offset_unit), ''));
  v_notes text := nullif(btrim(p_notes), '');
  v_reminder jsonb := NULL;
  v_constraint_name text;
BEGIN
  -- Replace semantics: callers should send the full intended current state.
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  PERFORM public.api_assert(
    v_service_type IS NOT NULL,
    'HOUSE_DIRECTORY_INVALID_ENUM',
    'service_type is required.',
    '22023'
  );

  PERFORM public.api_assert(
    v_service_type IN ('rent', 'internet', 'electricity', 'gas', 'water', 'other'),
    'HOUSE_DIRECTORY_INVALID_ENUM',
    'service_type must be one of rent, internet, electricity, gas, water, other.',
    '22023'
  );

  IF v_service_type = 'other' THEN
    PERFORM public.api_assert(
      v_custom_label IS NOT NULL,
      'HOUSE_DIRECTORY_OTHER_LABEL_REQUIRED',
      'custom_label is required when service_type is other.',
      '22023'
    );
    PERFORM public.api_assert(
      char_length(v_custom_label) BETWEEN 1 AND 40,
      'HOUSE_DIRECTORY_OTHER_LABEL_REQUIRED',
      'custom_label must be between 1 and 40 characters.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_custom_label IS NULL,
      'HOUSE_DIRECTORY_OTHER_LABEL_FORBIDDEN',
      'custom_label must be null unless service_type is other.',
      '22023'
    );
  END IF;

  PERFORM public.api_assert(
    v_provider_name IS NOT NULL,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'provider_name is required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_provider_name) BETWEEN 1 AND 120,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'provider_name must be between 1 and 120 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    v_account_reference IS NULL OR char_length(v_account_reference) <= 120,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'account_reference must be 120 characters or fewer.',
    '22023'
  );

  PERFORM public.api_assert(
    v_link_url IS NULL OR (char_length(v_link_url) <= 2048 AND v_link_url ~* '^https?://'),
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'link_url must be null or an http/https URL.',
    '22023'
  );

  IF p_term_end_date IS NOT NULL AND p_term_start_date IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_INVALID_TERM_RANGE',
      'term_start_date is required when term_end_date is provided.',
      '22023'
    );
  END IF;

  IF p_term_start_date IS NOT NULL AND p_term_end_date IS NOT NULL AND p_term_start_date > p_term_end_date THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_INVALID_TERM_RANGE',
      'term_start_date must be on or before term_end_date.',
      '22023'
    );
  END IF;

  IF v_service_type = 'rent' THEN
    PERFORM public.api_assert(
      p_term_start_date IS NOT NULL AND p_term_end_date IS NOT NULL,
      'HOUSE_DIRECTORY_RENT_TERM_REQUIRED',
      'Rent services require both term_start_date and term_end_date.',
      '22023'
    );
  END IF;

  IF (p_renewal_reminder_offset_value IS NULL) <> (v_offset_unit IS NULL) THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
      'renewal_reminder_offset_value and renewal_reminder_offset_unit must both be provided or both be null.',
      '22023'
    );
  END IF;

  IF p_renewal_reminder_offset_value IS NOT NULL THEN
    PERFORM public.api_assert(
      p_renewal_reminder_offset_value >= 1,
      'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
      'renewal_reminder_offset_value must be at least 1.',
      '22023'
    );

    PERFORM public.api_assert(
      v_offset_unit IN ('day', 'week', 'month'),
      'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
      'renewal_reminder_offset_unit must be day, week, or month.',
      '22023'
    );

    PERFORM public.api_assert(
      p_term_start_date IS NOT NULL AND p_term_end_date IS NOT NULL,
      'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
      'A reminder offset requires both term_start_date and term_end_date.',
      '22023'
    );

    PERFORM public._house_directory_assert_valid_reminder_offset(
      p_term_start_date,
      p_term_end_date,
      p_renewal_reminder_offset_value,
      v_offset_unit
    );
  END IF;

  PERFORM public.api_assert(
    v_notes IS NULL OR char_length(v_notes) <= 2000,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'notes must be 2000 characters or fewer.',
    '22023'
  );

  IF p_service_id IS NULL THEN
    INSERT INTO public.home_directory_services (
      home_id,
      service_type,
      custom_label,
      provider_name,
      account_reference,
      link_url,
      term_start_date,
      term_end_date,
      renewal_reminder_offset_value,
      renewal_reminder_offset_unit,
      notes,
      archived_at,
      created_by_user_id,
      updated_by_user_id
    )
    VALUES (
      p_home_id,
      v_service_type,
      v_custom_label,
      v_provider_name,
      v_account_reference,
      v_link_url,
      p_term_start_date,
      p_term_end_date,
      p_renewal_reminder_offset_value,
      v_offset_unit,
      v_notes,
      NULL,
      v_user,
      v_user
    )
    RETURNING * INTO v_service;
  ELSE
    UPDATE public.home_directory_services s
       SET service_type = v_service_type,
           custom_label = v_custom_label,
           provider_name = v_provider_name,
           account_reference = v_account_reference,
           link_url = v_link_url,
           term_start_date = p_term_start_date,
           term_end_date = p_term_end_date,
           renewal_reminder_offset_value = p_renewal_reminder_offset_value,
           renewal_reminder_offset_unit = v_offset_unit,
           notes = v_notes,
           updated_by_user_id = v_user
     WHERE s.id = p_service_id
       AND s.home_id = p_home_id
       AND s.archived_at IS NULL
    RETURNING * INTO v_service;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_SERVICE_NOT_FOUND',
        'The service was not found for this home, or it has been archived.',
        'P0002',
        jsonb_build_object('home_id', p_home_id, 'service_id', p_service_id)
      );
    END IF;
  END IF;

  PERFORM public._house_directory_reconcile_service_reminder(v_service.id);

  SELECT jsonb_build_object(
           'id', r.id,
           'service_id', r.service_id,
           'reminder_kind', r.reminder_kind,
           'status', r.status,
           'term_start_date', r.term_start_date,
           'term_end_date', r.term_end_date,
           'due_at', r.due_at,
           'dismissed_at', r.dismissed_at,
           'created_at', r.created_at,
           'updated_at', r.updated_at
         )
    INTO v_reminder
  FROM public.home_directory_service_reminders r
  WHERE r.service_id = v_service.id
    AND r.reminder_kind = 'renewal'
    AND r.term_start_date = v_service.term_start_date
    AND r.term_end_date = v_service.term_end_date
    AND r.status <> 'retired';

  RETURN jsonb_build_object(
    'ok', true,
    'service', jsonb_build_object(
      'id', v_service.id,
      'home_id', v_service.home_id,
      'service_type', v_service.service_type,
      'custom_label', v_service.custom_label,
      'provider_name', v_service.provider_name,
      'account_reference', v_service.account_reference,
      'link_url', v_service.link_url,
      'term_start_date', v_service.term_start_date,
      'term_end_date', v_service.term_end_date,
      'renewal_reminder_offset_value', v_service.renewal_reminder_offset_value,
      'renewal_reminder_offset_unit', v_service.renewal_reminder_offset_unit,
      'notes', v_service.notes,
      'archived_at', v_service.archived_at,
      'created_at', v_service.created_at,
      'updated_at', v_service.updated_at
    ),
    'reminder', v_reminder
  );

EXCEPTION
  WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;

    IF v_constraint_name = 'uq_home_directory_services_one_active_rent_per_home' THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_ACTIVE_SERVICE_CONFLICT',
        'Only one active rent service is allowed per home.',
        '23505',
        jsonb_build_object('home_id', p_home_id, 'service_type', 'rent')
      );
    ELSIF v_constraint_name = 'uq_home_directory_services_one_active_internet_per_home' THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_ACTIVE_SERVICE_CONFLICT',
        'Only one active internet service is allowed per home.',
        '23505',
        jsonb_build_object('home_id', p_home_id, 'service_type', 'internet')
      );
    ELSIF v_constraint_name = 'uq_home_directory_services_one_active_electricity_per_home' THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_ACTIVE_SERVICE_CONFLICT',
        'Only one active electricity service is allowed per home.',
        '23505',
        jsonb_build_object('home_id', p_home_id, 'service_type', 'electricity')
      );
    ELSE
      RAISE;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_home_directory_service(
  p_home_id uuid,
  p_service_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_service public.home_directory_services%ROWTYPE;
  v_existing public.home_directory_services%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  UPDATE public.home_directory_services s
     SET archived_at = now(),
         updated_by_user_id = v_user
   WHERE s.id = p_service_id
     AND s.home_id = p_home_id
     AND s.archived_at IS NULL
  RETURNING * INTO v_service;

  IF FOUND THEN
    PERFORM public._house_directory_reconcile_service_reminder(v_service.id);

    RETURN jsonb_build_object(
      'ok', true,
      'already_archived', false,
      'service', jsonb_build_object(
        'id', v_service.id,
        'home_id', v_service.home_id,
        'service_type', v_service.service_type,
        'custom_label', v_service.custom_label,
        'provider_name', v_service.provider_name,
        'account_reference', v_service.account_reference,
        'link_url', v_service.link_url,
        'term_start_date', v_service.term_start_date,
        'term_end_date', v_service.term_end_date,
        'renewal_reminder_offset_value', v_service.renewal_reminder_offset_value,
        'renewal_reminder_offset_unit', v_service.renewal_reminder_offset_unit,
        'notes', v_service.notes,
        'archived_at', v_service.archived_at,
        'created_at', v_service.created_at,
        'updated_at', v_service.updated_at
      )
    );
  END IF;

  SELECT *
    INTO v_existing
  FROM public.home_directory_services s
  WHERE s.id = p_service_id
    AND s.home_id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_SERVICE_NOT_FOUND',
      'The service was not found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id, 'service_id', p_service_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_archived', true,
    'service', jsonb_build_object(
      'id', v_existing.id,
      'home_id', v_existing.home_id,
      'service_type', v_existing.service_type,
      'custom_label', v_existing.custom_label,
      'provider_name', v_existing.provider_name,
      'account_reference', v_existing.account_reference,
      'link_url', v_existing.link_url,
      'term_start_date', v_existing.term_start_date,
      'term_end_date', v_existing.term_end_date,
      'renewal_reminder_offset_value', v_existing.renewal_reminder_offset_value,
      'renewal_reminder_offset_unit', v_existing.renewal_reminder_offset_unit,
      'notes', v_existing.notes,
      'archived_at', v_existing.archived_at,
      'created_at', v_existing.created_at,
      'updated_at', v_existing.updated_at
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- LINK RPCS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.upsert_home_directory_link(
  p_home_id uuid,
  p_link_id uuid DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_url text DEFAULT NULL,
  p_tag text DEFAULT NULL,
  p_custom_tag text DEFAULT NULL,
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_link public.home_directory_links%ROWTYPE;
  v_title text := nullif(btrim(p_title), '');
  v_url text := nullif(btrim(p_url), '');
  v_tag text := lower(nullif(btrim(p_tag), ''));
  v_custom_tag text := nullif(btrim(p_custom_tag), '');
BEGIN
  -- Replace semantics: callers should send the full intended current state.
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  PERFORM public.api_assert(
    v_title IS NOT NULL,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'title is required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_title) BETWEEN 1 AND 120,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'title must be between 1 and 120 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    v_url IS NOT NULL,
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'url is required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_url) <= 2048 AND v_url ~* '^https?://',
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'url must be an http or https URL.',
    '22023'
  );

  PERFORM public.api_assert(
    v_tag IN ('rent', 'bond', 'utilities', 'other'),
    'HOUSE_DIRECTORY_INVALID_ENUM',
    'tag must be one of rent, bond, utilities, other.',
    '22023'
  );

  IF v_tag = 'other' THEN
    PERFORM public.api_assert(
      v_custom_tag IS NOT NULL,
      'HOUSE_DIRECTORY_OTHER_TAG_REQUIRED',
      'custom_tag is required when tag is other.',
      '22023'
    );
    PERFORM public.api_assert(
      char_length(v_custom_tag) BETWEEN 1 AND 24,
      'HOUSE_DIRECTORY_OTHER_TAG_REQUIRED',
      'custom_tag must be between 1 and 24 characters.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_custom_tag IS NULL,
      'HOUSE_DIRECTORY_OTHER_TAG_FORBIDDEN',
      'custom_tag must be null unless tag is other.',
      '22023'
    );
  END IF;

  IF p_end_date IS NOT NULL AND p_start_date IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_INVALID_DATE_RANGE',
      'start_date is required when end_date is provided.',
      '22023'
    );
  END IF;

  IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_start_date > p_end_date THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_INVALID_DATE_RANGE',
      'start_date must be on or before end_date.',
      '22023'
    );
  END IF;

  IF p_link_id IS NULL THEN
    INSERT INTO public.home_directory_links (
      home_id,
      title,
      url,
      tag,
      custom_tag,
      start_date,
      end_date,
      archived_at,
      created_by_user_id,
      updated_by_user_id
    )
    VALUES (
      p_home_id,
      v_title,
      v_url,
      v_tag,
      v_custom_tag,
      p_start_date,
      p_end_date,
      NULL,
      v_user,
      v_user
    )
    RETURNING * INTO v_link;
  ELSE
    UPDATE public.home_directory_links l
       SET title = v_title,
           url = v_url,
           tag = v_tag,
           custom_tag = v_custom_tag,
           start_date = p_start_date,
           end_date = p_end_date,
           updated_by_user_id = v_user
     WHERE l.id = p_link_id
       AND l.home_id = p_home_id
       AND l.archived_at IS NULL
    RETURNING * INTO v_link;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_LINK_NOT_FOUND',
        'The link was not found for this home, or it has been archived.',
        'P0002',
        jsonb_build_object('home_id', p_home_id, 'link_id', p_link_id)
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'link', jsonb_build_object(
      'id', v_link.id,
      'home_id', v_link.home_id,
      'title', v_link.title,
      'url', v_link.url,
      'tag', v_link.tag,
      'custom_tag', v_link.custom_tag,
      'start_date', v_link.start_date,
      'end_date', v_link.end_date,
      'archived_at', v_link.archived_at,
      'created_at', v_link.created_at,
      'updated_at', v_link.updated_at
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_home_directory_link(
  p_home_id uuid,
  p_link_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_link public.home_directory_links%ROWTYPE;
  v_existing public.home_directory_links%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  UPDATE public.home_directory_links l
     SET archived_at = now(),
         updated_by_user_id = v_user
   WHERE l.id = p_link_id
     AND l.home_id = p_home_id
     AND l.archived_at IS NULL
  RETURNING * INTO v_link;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_archived', false,
      'link', jsonb_build_object(
        'id', v_link.id,
        'home_id', v_link.home_id,
        'title', v_link.title,
        'url', v_link.url,
        'tag', v_link.tag,
        'custom_tag', v_link.custom_tag,
        'start_date', v_link.start_date,
        'end_date', v_link.end_date,
        'archived_at', v_link.archived_at,
        'created_at', v_link.created_at,
        'updated_at', v_link.updated_at
      )
    );
  END IF;

  SELECT *
    INTO v_existing
  FROM public.home_directory_links l
  WHERE l.id = p_link_id
    AND l.home_id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_LINK_NOT_FOUND',
      'The link was not found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id, 'link_id', p_link_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_archived', true,
    'link', jsonb_build_object(
      'id', v_existing.id,
      'home_id', v_existing.home_id,
      'title', v_existing.title,
      'url', v_existing.url,
      'tag', v_existing.tag,
      'custom_tag', v_existing.custom_tag,
      'start_date', v_existing.start_date,
      'end_date', v_existing.end_date,
      'archived_at', v_existing.archived_at,
      'created_at', v_existing.created_at,
      'updated_at', v_existing.updated_at
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- REMINDER RPCS (TODAY PAGE)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_due_home_directory_reminders(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_today_utc date := public._house_directory_today_utc();
  v_user uuid := auth.uid();
  v_due_reminders jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  v_due_reminders := public._house_directory_due_reminders_json(p_home_id, v_user);

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'today_utc_date', v_today_utc,
    'due_reminders', v_due_reminders
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.acknowledge_home_directory_reminder(
  p_home_id uuid,
  p_reminder_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_today_utc date := public._house_directory_today_utc();
  v_row public.home_directory_service_reminders%ROWTYPE;
  v_acknowledged_at timestamptz;
  v_exists_for_home boolean := false;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT true
    INTO v_exists_for_home
  FROM public.home_directory_service_reminders r
  JOIN public.home_directory_services s
    ON s.id = r.service_id
  WHERE r.id = p_reminder_id
    AND s.home_id = p_home_id
  LIMIT 1;

  IF NOT COALESCE(v_exists_for_home, false) THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_REMINDER_NOT_FOUND',
      'The reminder was not found for this home.',
      'P0002',
      jsonb_build_object(
        'home_id', p_home_id,
        'reminder_id', p_reminder_id
      )
    );
  END IF;

  SELECT r.*
    INTO v_row
  FROM public.home_directory_service_reminders r
  JOIN public.home_directory_services s
    ON s.id = r.service_id
  WHERE r.id = p_reminder_id
    AND s.home_id = p_home_id
    AND r.reminder_kind = 'renewal'
    AND r.status = 'active'
    AND s.archived_at IS NULL
    AND s.term_start_date = r.term_start_date
    AND s.term_end_date = r.term_end_date
    AND v_today_utc >= r.due_at;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_REMINDER_NOT_ACTIONABLE',
      'Reminder cannot be acknowledged because it is not currently actionable for this home.',
      '22023',
      jsonb_build_object(
        'home_id', p_home_id,
        'reminder_id', p_reminder_id
      )
    );
  END IF;

  INSERT INTO public.home_directory_service_reminder_acknowledgements (
    reminder_id,
    user_id
  )
  VALUES (
    v_row.id,
    v_user
  )
  ON CONFLICT (reminder_id, user_id) DO NOTHING;

  SELECT ra.acknowledged_at
    INTO v_acknowledged_at
  FROM public.home_directory_service_reminder_acknowledgements ra
  WHERE ra.reminder_id = v_row.id
    AND ra.user_id = v_user;

  RETURN jsonb_build_object(
    'ok', true,
    'reminder_id', v_row.id,
    'acknowledged_by_user_id', v_user,
    'acknowledged_at', v_acknowledged_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.dismiss_home_directory_reminder(
  p_home_id uuid,
  p_reminder_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_today_utc date := public._house_directory_today_utc();
  v_row public.home_directory_service_reminders%ROWTYPE;
  v_existing public.home_directory_service_reminders%ROWTYPE;
  v_exists_for_home boolean := false;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  SELECT true
    INTO v_exists_for_home
  FROM public.home_directory_service_reminders r
  JOIN public.home_directory_services s
    ON s.id = r.service_id
  WHERE r.id = p_reminder_id
    AND s.home_id = p_home_id
  LIMIT 1;

  IF NOT COALESCE(v_exists_for_home, false) THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_REMINDER_NOT_FOUND',
      'The reminder was not found for this home.',
      'P0002',
      jsonb_build_object(
        'home_id', p_home_id,
        'reminder_id', p_reminder_id
      )
    );
  END IF;

  UPDATE public.home_directory_service_reminders r
     SET status = 'dismissed',
         dismissed_at = now(),
         dismissed_by_user_id = v_user
  FROM public.home_directory_services s
  WHERE r.service_id = s.id
    AND r.id = p_reminder_id
    AND s.home_id = p_home_id
    AND r.reminder_kind = 'renewal'
    AND r.status = 'active'
    AND s.archived_at IS NULL
    AND s.term_start_date = r.term_start_date
    AND s.term_end_date = r.term_end_date
    AND v_today_utc >= r.due_at
  RETURNING r.* INTO v_row;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_dismissed', false,
      'reminder', jsonb_build_object(
        'id', v_row.id,
        'service_id', v_row.service_id,
        'reminder_kind', v_row.reminder_kind,
        'status', v_row.status,
        'term_start_date', v_row.term_start_date,
        'term_end_date', v_row.term_end_date,
        'due_at', v_row.due_at,
        'dismissed_at', v_row.dismissed_at,
        'dismissed_by_user_id', v_row.dismissed_by_user_id,
        'created_at', v_row.created_at,
        'updated_at', v_row.updated_at
      )
    );
  END IF;

  SELECT r.*
    INTO v_existing
  FROM public.home_directory_service_reminders r
  JOIN public.home_directory_services s
    ON s.id = r.service_id
  WHERE r.id = p_reminder_id
    AND s.home_id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_REMINDER_NOT_FOUND',
      'The reminder was not found for this home.',
      'P0002',
      jsonb_build_object(
        'home_id', p_home_id,
        'reminder_id', p_reminder_id
      )
    );
  END IF;

  IF v_existing.status = 'dismissed' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_dismissed', true,
      'reminder', jsonb_build_object(
        'id', v_existing.id,
        'service_id', v_existing.service_id,
        'reminder_kind', v_existing.reminder_kind,
        'status', v_existing.status,
        'term_start_date', v_existing.term_start_date,
        'term_end_date', v_existing.term_end_date,
        'due_at', v_existing.due_at,
        'dismissed_at', v_existing.dismissed_at,
        'dismissed_by_user_id', v_existing.dismissed_by_user_id,
        'created_at', v_existing.created_at,
        'updated_at', v_existing.updated_at
      )
    );
  END IF;

  PERFORM public.api_error(
    'HOUSE_DIRECTORY_REMINDER_NOT_ACTIONABLE',
    'Reminder cannot be dismissed because it is not currently actionable for this home.',
    '22023',
    jsonb_build_object(
      'home_id', p_home_id,
      'reminder_id', p_reminder_id,
      'status', v_existing.status
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- FUNCTION PERMISSIONS
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._house_directory_assert_owner(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_escape_qr_part(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_build_wifi_qr(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_today_utc() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_compute_renewal_due_at(date, date, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_assert_valid_reminder_offset(date, date, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_reconcile_service_reminder(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_directory_due_reminders_json(uuid, uuid) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_home_directory_wifi(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_home_directory_wifi(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.upsert_home_directory_wifi(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_home_directory_wifi(uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.get_home_directory_content(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_home_directory_content(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.upsert_home_directory_service(uuid, uuid, text, text, text, text, text, date, date, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_home_directory_service(uuid, uuid, text, text, text, text, text, date, date, integer, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.archive_home_directory_service(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_home_directory_service(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.upsert_home_directory_link(uuid, uuid, text, text, text, text, date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_home_directory_link(uuid, uuid, text, text, text, text, date, date) TO authenticated;

REVOKE ALL ON FUNCTION public.archive_home_directory_link(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_home_directory_link(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.list_due_home_directory_reminders(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_due_home_directory_reminders(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.acknowledge_home_directory_reminder(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_home_directory_reminder(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_home_directory_reminder(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_home_directory_reminder(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- House Vibes Invalidation Helper
-- ---------------------------------------------------------------------------
-- Purpose:
-- - Centralize house_vibes invalidation logic
-- - Called whenever active membership changes in a way that can stale coverage
--
-- Notes:
-- - Marks existing rows as out_of_date
-- - Sets invalidated_at only when transitioning from fresh -> stale
-- - No-op if no house_vibes row exists yet for the home
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._house_vibes_invalidate(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.house_vibes hv
     SET out_of_date   = true,
         invalidated_at = now()
   WHERE hv.home_id = p_home_id
     AND hv.out_of_date = false;
END;
$$;


-- ---------------------------------------------------------------------------
-- Leave Home
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.homes_leave(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user            uuid := auth.uid();
  v_is_owner        boolean;
  v_other_members   integer;
  v_left_rows       integer;
  v_deactivated     boolean := false;
  v_role_before     text;
  v_members_left    integer;

  v_current_members integer;
  v_delta_members   integer;
BEGIN
  PERFORM public._assert_authenticated();

  -- Serialize with transfers/joins
  PERFORM 1
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  -- Must be a current member
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
        FROM public.memberships m
       WHERE m.user_id = v_user
         AND m.home_id = p_home_id
         AND m.is_current
    ),
    'NOT_MEMBER',
    'You are not a current member of this home.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  -- Capture role (for response)
  SELECT m.role
    INTO v_role_before
    FROM public.memberships m
   WHERE m.user_id = v_user
     AND m.home_id = p_home_id
     AND m.is_current
   LIMIT 1;

  -- If owner, only leave if last member
  SELECT EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.home_id = p_home_id
       AND m.is_current
       AND m.role = 'owner'
  ) INTO v_is_owner;

  IF v_is_owner THEN
    SELECT COUNT(*) INTO v_other_members
      FROM public.memberships m
     WHERE m.home_id = p_home_id
       AND m.is_current
       AND m.user_id <> v_user;

    IF v_other_members > 0 THEN
      PERFORM public.api_error(
        'OWNER_MUST_TRANSFER_FIRST',
        'Owner must transfer ownership before leaving.',
        '42501',
        jsonb_build_object(
          'home_id',       p_home_id,
          'other_members', v_other_members
        )
      );
    END IF;
  END IF;

  -- End the stint
  UPDATE public.memberships m
     SET valid_to = now(),
         updated_at = now()
   WHERE m.user_id = v_user
     AND m.home_id = p_home_id
     AND m.is_current
  RETURNING 1 INTO v_left_rows;

  IF v_left_rows IS NULL THEN
    PERFORM public.api_error(
      'STATE_CHANGED_RETRY',
      'Membership state changed; retry.',
      '40001'
    );
  END IF;

  -- Membership change can stale house vibe coverage
  PERFORM public._house_vibes_invalidate(p_home_id);

  -- Terminate impacted recurring plans for this member
  PERFORM public._expense_plans_terminate_for_member_change(p_home_id, v_user);

  -- Check remaining members (ground truth)
  SELECT COUNT(*) INTO v_members_left
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current;

  -- Keep usage counter in sync with ground truth
  SELECT COALESCE(active_members, 0)
    INTO v_current_members
    FROM public.home_usage_counters
   WHERE home_id = p_home_id;

  v_delta_members := v_members_left - v_current_members;

  IF v_delta_members <> 0 THEN
    PERFORM public._home_usage_apply_delta(
      p_home_id,
      jsonb_build_object('active_members', v_delta_members)
    );
  END IF;

  -- Deactivate home if no members remain
  IF v_members_left = 0 THEN
    UPDATE public.homes
       SET is_active      = FALSE,
           deactivated_at = now(),
           updated_at     = now()
     WHERE id = p_home_id;

    v_deactivated := true;
  END IF;

  -- Detach any existing live subscription from the home
  PERFORM public._home_detach_subscription_to_home(p_home_id, v_user);

  -- Reassign chores to owner if home still has members
  IF NOT v_deactivated THEN
    PERFORM public.chores_reassign_on_member_leave(p_home_id, v_user);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', CASE WHEN v_deactivated THEN 'HOME_DEACTIVATED' ELSE 'LEFT_OK' END,
    'message', CASE
                 WHEN v_deactivated THEN 'Left home; no members remain, home deactivated.'
                 ELSE 'Left home.'
               END,
    'data', jsonb_build_object(
      'home_id',           p_home_id,
      'role_before',       v_role_before,
      'members_remaining', v_members_left,
      'home_deactivated',  v_deactivated
    )
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- Kick Member
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.members_kick(
  p_home_id uuid,
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_target_role        text;
  v_rows_updated       integer;
  v_members_remaining  integer;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);

  --------------------------------------------------------------------
  -- 1) Verify caller is the current owner of the active home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
        FROM public.memberships m
        JOIN public.homes h ON h.id = m.home_id
       WHERE m.user_id    = v_user
         AND m.home_id    = p_home_id
         AND m.role       = 'owner'
         AND m.is_current = TRUE
         AND h.is_active  = TRUE
    ),
    'FORBIDDEN',
    'Only the current owner can remove members.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  --------------------------------------------------------------------
  -- 2) Validate target is a current (non-owner) member
  --------------------------------------------------------------------
  SELECT m.role
    INTO v_target_role
    FROM public.memberships m
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
   LIMIT 1;

  PERFORM public.api_assert(
    v_target_role IS NOT NULL,
    'TARGET_NOT_MEMBER',
    'The selected user is not an active member of this home.',
    'P0002',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  PERFORM public.api_assert(
    v_target_role <> 'owner',
    'CANNOT_KICK_OWNER',
    'Owners cannot be removed.',
    '42501',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 3) Serialize with other membership mutations and close the stint
  --------------------------------------------------------------------
  PERFORM 1
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
  RETURNING 1 INTO v_rows_updated;

  PERFORM public.api_assert(
    v_rows_updated = 1,
    'STATE_CHANGED_RETRY',
    'Membership state changed; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  -- Membership change can stale house vibe coverage
  PERFORM public._house_vibes_invalidate(p_home_id);

  -- Terminate impacted recurring plans for the kicked member
  PERFORM public._expense_plans_terminate_for_member_change(p_home_id, p_target_user_id);

  --------------------------------------------------------------------
  -- 4) Return success payload
  --------------------------------------------------------------------
  SELECT COUNT(*) INTO v_members_remaining
    FROM public.memberships m
   WHERE m.home_id    = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'member_removed',
    'message', 'Member removed successfully.',
    'data', jsonb_build_object(
      'home_id',           p_home_id,
      'user_id',           p_target_user_id,
      'members_remaining', v_members_remaining
    )
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- Join Home
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.homes_join(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user    uuid := auth.uid();
  v_home_id uuid;
  v_revoked boolean;
  v_active  boolean;

  v_plan    text;
  v_cap     integer;
  v_current_members integer := 0;

  v_req public.member_cap_join_requests;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- Combined lookup: home_id + invite state
  SELECT
    i.home_id,
    (i.revoked_at IS NOT NULL) AS revoked,
    h.is_active
  INTO
    v_home_id,
    v_revoked,
    v_active
  FROM public.invites i
  JOIN public.homes h ON h.id = i.home_id
  WHERE i.code = p_code::public.citext
  LIMIT 1;

  -- Code not found at all
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_CODE',
      'Invite code not found. Please check and try again.',
      '22023',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'code_not_found'
      )
    );
  END IF;

  -- Invite revoked or home inactive
  IF v_revoked OR NOT v_active THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'revoked_or_home_inactive'
      )
    );
  END IF;

  -- Ensure caller has a unique avatar within this home (plan-gated)
  PERFORM public._ensure_unique_avatar_for_home(v_home_id, v_user);

  -- Already current member of this same home
  IF EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.home_id = v_home_id
       AND m.is_current = TRUE
  ) THEN
    RETURN jsonb_build_object(
      'status',  'success',
      'code',    'already_member',
      'message', 'You are already part of this household.',
      'home_id', v_home_id
    );
  END IF;

  -- Already in another active home (only one allowed)
  IF EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.is_current = TRUE
       AND m.home_id <> v_home_id
  ) THEN
    PERFORM public.api_error(
      'ALREADY_IN_OTHER_HOME',
      'You are already a member of another household. Leave it first before joining a new one.',
      '42501',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'single_home_rule'
      )
    );
  END IF;

  -- Member-cap precheck (free-only): block + enqueue instead of raising paywall
  v_plan := public._home_effective_plan(v_home_id);

  IF v_plan = 'free' THEN
    -- Align lock order explicitly (homes -> home_usage_counters ...)
    PERFORM 1
      FROM public.homes h
     WHERE h.id = v_home_id
     FOR UPDATE;

    -- Ensure counters row exists and lock it
    PERFORM public._home_usage_apply_delta(v_home_id, '{}'::jsonb);

    SELECT COALESCE(active_members, 0)
      INTO v_current_members
      FROM public.home_usage_counters
     WHERE home_id = v_home_id
     FOR UPDATE;

    SELECT max_value
      INTO v_cap
      FROM public.home_plan_limits
     WHERE plan = v_plan
       AND metric = 'active_members';

    IF v_cap IS NOT NULL AND (v_current_members + 1) > v_cap THEN
      v_req := public._member_cap_enqueue_request(v_home_id, v_user);

      RETURN jsonb_build_object(
        'status',     'blocked',
        'code',       'member_cap',
        'message',    'Home is not accepting new members right now. We notified the owner.',
        'home_id',    v_home_id,
        'request_id', v_req.id
      );
    END IF;
  END IF;

  -- Paywall: enforce active_members limit on this home (raises on free over-limit)
  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Create new membership (race-safe)
  BEGIN
    INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
    VALUES (v_user, v_home_id, 'member', now(), NULL);
  EXCEPTION
    WHEN unique_violation THEN
      PERFORM public.api_error(
        'ALREADY_IN_OTHER_HOME',
        'You are already a member of another household. Leave it first before joining a new one.',
        '42501',
        jsonb_build_object(
          'context', 'homes_join',
          'reason', 'unique_violation_memberships'
        )
      );
  END;

  -- Membership change can stale house vibe coverage
  PERFORM public._house_vibes_invalidate(v_home_id);

  -- Increment cached active_members
  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::public.citext;

  -- Attach Subscription to home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home_id);

  -- Success response
  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;