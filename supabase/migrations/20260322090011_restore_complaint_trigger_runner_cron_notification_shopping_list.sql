-- ============================================================
-- Restore complaint trigger runner cron job
-- - Uses direct pg_cron -> net.http_post call (no wrapper function)
-- - Keeps watchdog/terminalizer DB-only jobs unchanged
-- ============================================================

do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_trigger_runner_every_5m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_trigger_runner_every_5m',
      '*/5 * * * *',
      $cmd$
      select net.http_post(
        url := (
          select s.decrypted_secret
          from vault.decrypted_secrets s
          where s.name = 'SUPABASE_URL'
          limit 1
        ) || '/functions/v1/complaint_trigger_cron_runner',
        headers := jsonb_strip_nulls(
          jsonb_build_object(
            'Content-Type', 'application/json',
            'x-internal-secret',
            (
              select s.decrypted_secret
              from vault.decrypted_secrets s
              where s.name = 'RUNNER_SHARED_SECRET'
              limit 1
            )
          )
        ),
        body := '{}'::jsonb
      );
      $cmd$
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping schedule ensure for complaint_trigger_runner_every_5m.';
  end;
end
$$;


-- ============================================================
-- Restore complaint batch cron jobs (vault-backed)
-- - Recreates submitter/collector pg_cron jobs removed by prior cleanup
-- - Uses Vault secrets directly (no GUC fallback)
-- ============================================================

-- 1) Ensure complaint_rewrite_batch_submitter_15m exists
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_rewrite_batch_submitter_15m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_rewrite_batch_submitter_15m',
      '*/15 * * * *',
      $cmd$
      select net.http_post(
        url := (
          select s.decrypted_secret
          from vault.decrypted_secrets s
          where s.name = 'SUPABASE_URL'
          limit 1
        ) || '/functions/v1/rewrite_batch_submitter',
        headers := jsonb_strip_nulls(
          jsonb_build_object(
            'Content-Type', 'application/json',
            'x-internal-secret', (
              select s.decrypted_secret
              from vault.decrypted_secrets s
              where s.name = 'WORKER_SHARED_SECRET'
              limit 1
            ),
            'x-worker-id', 'cron_batch_submitter'
          )
        ),
        body := '{}'::jsonb
      );
      $cmd$
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping schedule ensure for complaint_rewrite_batch_submitter_15m.';
  end;
end
$$;

-- 2) Ensure complaint_rewrite_batch_collector_30m exists
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_rewrite_batch_collector_30m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_rewrite_batch_collector_30m',
      '*/30 * * * *',
      $cmd$
      select net.http_post(
        url := (
          select s.decrypted_secret
          from vault.decrypted_secrets s
          where s.name = 'SUPABASE_URL'
          limit 1
        ) || '/functions/v1/rewrite_batch_collector',
        headers := jsonb_strip_nulls(
          jsonb_build_object(
            'Content-Type', 'application/json',
            'x-internal-secret', (
              select s.decrypted_secret
              from vault.decrypted_secrets s
              where s.name = 'WORKER_SHARED_SECRET'
              limit 1
            ),
            'x-worker-id', 'cron_batch_collector'
          )
        ),
        body := '{}'::jsonb
      );
      $cmd$
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping schedule ensure for complaint_rewrite_batch_collector_30m.';
  end;
end
$$;

-- --------------------------------------------------------------------
-- notifications_sync_client_state: cap active tokens per platform
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_sync_client_state(
  p_token            text,
  p_platform         text,
  p_locale           text,
  p_timezone         text,
  p_os_permission    text,          -- 'allowed' | 'blocked' | 'unknown'
  p_wants_daily      boolean DEFAULT NULL,
  p_preferred_hour   integer DEFAULT NULL,
  p_preferred_minute integer DEFAULT NULL
)
RETURNS public.notification_preferences
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_current     public.notification_preferences;
  v_effective_wants_daily      boolean;
  v_effective_preferred_hour   integer;
  v_effective_preferred_minute integer;
  v_should_upsert boolean;
  v_max_active_per_platform integer := 2;

  v_prev_os_permission text := 'unknown';
  v_permission_became_allowed boolean := FALSE;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT *
  INTO v_current
  FROM public.notification_preferences
  WHERE user_id = v_user_id;

  v_prev_os_permission := COALESCE(v_current.os_permission, 'unknown');
  v_permission_became_allowed :=
    p_os_permission = 'allowed'
    AND v_prev_os_permission IS DISTINCT FROM 'allowed';

  -- wants_daily resolution:
  -- 1) explicit client value wins
  -- 2) blocked/unknown always forced false
  -- 3) first allowed (new row) or transition to allowed auto-enables true
  -- 4) otherwise preserve existing choice while allowed
  IF p_wants_daily IS NOT NULL THEN
    v_effective_wants_daily := p_wants_daily;
  ELSIF p_os_permission IS DISTINCT FROM 'allowed' THEN
    v_effective_wants_daily := FALSE;
  ELSIF v_current.user_id IS NULL OR v_permission_became_allowed THEN
    v_effective_wants_daily := TRUE;
  ELSE
    v_effective_wants_daily := COALESCE(v_current.wants_daily, TRUE);
  END IF;

  v_effective_preferred_hour :=
    COALESCE(
      p_preferred_hour,
      v_current.preferred_hour,
      9
    );

  v_effective_preferred_minute :=
    COALESCE(
      p_preferred_minute,
      v_current.preferred_minute,
      0
    );

  -- Upsert only when we have an explicit change, an existing row, or OS is allowed.
  -- Do NOT upsert just because a token is present if permission is blocked/unknown.
  v_should_upsert :=
       v_current.user_id IS NOT NULL
    OR p_wants_daily IS NOT NULL
    OR p_preferred_hour IS NOT NULL
    OR p_preferred_minute IS NOT NULL
    OR p_os_permission = 'allowed';

  IF NOT v_should_upsert THEN
    RETURN (
      v_user_id,
      v_effective_wants_daily,
      v_effective_preferred_hour,
      COALESCE(p_timezone, 'UTC'),
      COALESCE(p_locale, 'en'),
      p_os_permission,
      now(),
      v_current.last_sent_local_date,
      COALESCE(v_current.created_at, now()),
      now(),
      v_effective_preferred_minute
    )::public.notification_preferences;
  END IF;

  INSERT INTO public.notification_preferences (
    user_id,
    wants_daily,
    preferred_hour,
    preferred_minute,
    timezone,
    locale,
    os_permission,
    last_os_sync_at,
    last_sent_local_date,
    created_at,
    updated_at
  )
  VALUES (
    v_user_id,
    v_effective_wants_daily,
    v_effective_preferred_hour,
    v_effective_preferred_minute,
    p_timezone,
    p_locale,
    p_os_permission,
    now(),
    COALESCE(v_current.last_sent_local_date, NULL),
    COALESCE(v_current.created_at, now()),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET wants_daily      = EXCLUDED.wants_daily,
        preferred_hour   = EXCLUDED.preferred_hour,
        preferred_minute = EXCLUDED.preferred_minute,
        timezone         = EXCLUDED.timezone,
        locale           = EXCLUDED.locale,
        os_permission    = EXCLUDED.os_permission,
        last_os_sync_at  = EXCLUDED.last_os_sync_at,
        updated_at       = EXCLUDED.updated_at
  RETURNING * INTO v_current;

  IF p_token IS NOT NULL THEN
    INSERT INTO public.device_tokens (
      user_id, token, provider, platform, status,
      last_seen_at, created_at, updated_at
    )
    VALUES (
      v_user_id, p_token, 'fcm', p_platform, 'active',
      now(), now(), now()
    )
    ON CONFLICT (token) DO UPDATE
      SET user_id      = EXCLUDED.user_id,
          platform     = EXCLUDED.platform,
          provider     = EXCLUDED.provider,
          status       = 'active',
          last_seen_at = now(),
          updated_at   = now();

    -- Cap active tokens per platform by expiring the oldest seen tokens.
    IF p_platform IS NOT NULL THEN
      WITH ranked AS (
        SELECT
          id,
          ROW_NUMBER() OVER (
            ORDER BY last_seen_at DESC, updated_at DESC
          ) AS rn
        FROM public.device_tokens
        WHERE user_id = v_user_id
          AND platform = p_platform
          AND provider = 'fcm'
          AND status = 'active'
      )
      UPDATE public.device_tokens
      SET status = 'expired',
          updated_at = now()
      WHERE id IN (
        SELECT id FROM ranked WHERE rn > v_max_active_per_platform
      );
    END IF;
  END IF;

  RETURN v_current;
END;
$$;

CREATE OR REPLACE FUNCTION public.home_assignees_list_v2(
  p_home_id uuid
)
RETURNS TABLE (
  user_id              uuid,
  username             text,
  full_name            text,
  email                text,
  avatar_storage_path  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Require auth
  PERFORM public._assert_authenticated();

  -- Ensure caller belongs to this home
  PERFORM public._assert_home_member(p_home_id);

  -- Return all active members as potential assignees
  RETURN QUERY
  SELECT
    m.user_id,
    p.username,
    p.full_name,
    p.email,
    a.storage_path
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
  ORDER BY
    COALESCE(NULLIF(p.full_name, ''), NULLIF(p.username, ''), p.email);
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
  v_user uuid := auth.uid();
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
          'is_completed', (i.is_completed = TRUE AND i.completed_by_user_id = v_user),
          'completed_by_user_id', CASE WHEN i.completed_by_user_id = v_user THEN i.completed_by_user_id ELSE NULL END,
          'completed_by_avatar_id', CASE WHEN i.completed_by_user_id = v_user THEN p.avatar_id ELSE NULL END,
          'completed_at', CASE WHEN i.completed_by_user_id = v_user THEN i.completed_at ELSE NULL END,
          'reference_photo_path', i.reference_photo_path,
          'reference_added_by_user_id', i.reference_added_by_user_id,
          'linked_expense_id', i.linked_expense_id,
          'archived_at', i.archived_at,
          'archived_by_user_id', i.archived_by_user_id,
          'created_at', i.created_at,
          'updated_at', i.updated_at
        )
        ORDER BY
          (i.is_completed = TRUE AND i.completed_by_user_id = v_user) ASC,
          CASE WHEN i.completed_by_user_id = v_user THEN i.completed_at ELSE NULL END DESC NULLS LAST,
          i.created_at DESC
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
    AND NOT (i.is_completed = TRUE AND i.completed_by_user_id = v_user);

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
   6) RPC: Update item (first-completer wins)
       - A completion made by another member cannot be overridden.
       - Same-user re-complete is idempotent.
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
    IF v_existing.is_completed = TRUE
       AND v_existing.completed_by_user_id IS DISTINCT FROM v_user THEN
      PERFORM public.api_error(
        'item_already_completed_by_other',
        'Item was already completed by another member.',
        'P0001',
        jsonb_build_object(
          'item_id', p_item_id,
          'completed_by_user_id', v_existing.completed_by_user_id
        )
      );
    ELSIF v_existing.is_completed = TRUE
       AND v_existing.completed_by_user_id = v_user THEN
      -- Idempotent re-complete by same user: keep original completion metadata.
      v_next_is_completed := TRUE;
      v_next_completed_by := v_existing.completed_by_user_id;
      v_next_completed_at := v_existing.completed_at;
    ELSE
      v_next_is_completed := TRUE;
      v_next_completed_by := v_user;
      v_next_completed_at := now();
    END IF;
  ELSE
    IF v_existing.is_completed = TRUE
       AND v_existing.completed_by_user_id IS DISTINCT FROM v_user THEN
      PERFORM public.api_error(
        'item_already_completed_by_other',
        'Item was already completed by another member.',
        'P0001',
        jsonb_build_object(
          'item_id', p_item_id,
          'completed_by_user_id', v_existing.completed_by_user_id
        )
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
