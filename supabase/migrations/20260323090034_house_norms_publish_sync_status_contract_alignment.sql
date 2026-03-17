-- Align house_norms_get_for_home publish_sync_status fallback with the v1.1 contract.

CREATE OR REPLACE FUNCTION public.house_norms_get_for_home(
  p_home_id uuid,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms%ROWTYPE;
  v_requested_locale_base text;
  v_is_owner boolean := false;
  v_show_publish_button boolean := false;
  v_show_republish_button boolean := false;
  v_show_public_url boolean := false;
  v_owner_meta jsonb := '{}'::jsonb;
  v_publish_job_id uuid := NULL;
  v_publish_job_stage text := NULL;
  v_publish_job_attempt_count integer := NULL;
  v_publish_job_status text := NULL;
  v_publish_job_last_error_code text := NULL;
  v_publish_job_last_error text := NULL;
  v_publish_job_last_error_at timestamptz := NULL;
  v_publish_sync_status text := NULL;
  v_publish_sync_error jsonb := NULL;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  v_is_owner := public.is_home_owner(p_home_id, auth.uid());

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  v_requested_locale_base := lower(COALESCE(public.locale_base(p_locale), 'en'));

  PERFORM public.api_assert(
    v_requested_locale_base ~ '^[a-z]{2}$',
    'INVALID_LOCALE',
    'Locale base must be ISO 639-1 lowercase (e.g. en).',
    '22023',
    jsonb_build_object('locale_base', v_requested_locale_base)
  );

  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id;

  IF v_row.home_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'home_id', p_home_id,
      'requested_locale_base', v_requested_locale_base,
      'house_norms', NULL
    );
  END IF;

  IF v_is_owner THEN
    IF v_row.published_content IS NULL THEN
      v_show_publish_button := true;
      v_show_republish_button := false;
      v_show_public_url := false;
    ELSIF v_row.generated_content IS DISTINCT FROM v_row.published_content THEN
      v_show_publish_button := false;
      v_show_republish_button := true;
      v_show_public_url := true;
    ELSE
      v_show_publish_button := false;
      v_show_republish_button := false;
      v_show_public_url := true;
    END IF;

    IF v_row.published_version IS NOT NULL THEN
      SELECT j.job_id,
             j.current_stage,
             j.attempt_count,
             j.status,
             j.last_error_code,
             j.last_error,
             j.last_error_at
        INTO v_publish_job_id,
             v_publish_job_stage,
             v_publish_job_attempt_count,
             v_publish_job_status,
             v_publish_job_last_error_code,
             v_publish_job_last_error,
             v_publish_job_last_error_at
      FROM public.house_norms_publish_jobs j
      WHERE j.home_id = p_home_id
        AND j.published_version = v_row.published_version
      ORDER BY j.created_at DESC
      LIMIT 1;

      v_publish_sync_status := COALESCE(v_publish_job_status, 'succeeded');

      IF v_publish_sync_status = 'failed' THEN
        v_publish_sync_error := jsonb_strip_nulls(jsonb_build_object(
          'code', v_publish_job_last_error_code,
          'message', v_publish_job_last_error,
          'stage', v_publish_job_stage,
          'at', v_publish_job_last_error_at
        ));
      END IF;
    END IF;

    v_owner_meta := jsonb_strip_nulls(jsonb_build_object(
      'home_public_id', v_row.home_public_id,
      'public_url',
        CASE
          WHEN v_row.home_public_id IS NULL THEN NULL
          ELSE public._house_norms_build_public_url(v_row.home_public_id::text)
        END,
      'published_version', v_row.published_version,
      'show_publish_button', v_show_publish_button,
      'show_republish_button', v_show_republish_button,
      'show_public_url', v_show_public_url,
      'publish_sync_status', v_publish_sync_status,
      'publish_sync_error', v_publish_sync_error,
      'publish_job_id', v_publish_job_id,
      'publish_job_stage', v_publish_job_stage,
      'publish_attempt_count', v_publish_job_attempt_count
    ));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'house_norms',
      jsonb_strip_nulls(
        jsonb_build_object(
          'template_key', v_row.template_key,
          'status', v_row.status,
          'inputs', v_row.inputs,
          'draft_content', v_row.generated_content,
          'draft_updated_at', v_row.generated_at,
          'published_content', v_row.published_content,
          'published_at', v_row.published_at,
          'published_version', v_row.published_version,
          'is_published', (v_row.published_content IS NOT NULL),
          'has_unpublished_changes',
            (v_row.published_content IS NULL OR v_row.generated_content IS DISTINCT FROM v_row.published_content),
          'last_edited_at', v_row.last_edited_at,
          'last_edited_by', v_row.last_edited_by
        )
        || CASE
             WHEN v_is_owner THEN v_owner_meta
             ELSE jsonb_build_object(
               'member_viewed_at',
                 (
                   SELECT v.viewed_at
                   FROM public.house_norms_member_views v
                   WHERE v.home_id = p_home_id
                     AND v.user_id = auth.uid()
                 ),
               'show_member_review_card',
                 public.house_norms_should_show_member_review(p_home_id)
             )
           END
      )
  );
END;
$$;
