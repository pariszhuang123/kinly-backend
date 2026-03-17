-- House Directory v1.2
-- Align note storage/RPC behavior with the updated House Directory contracts.

-- ---------------------------------------------------------------------------
-- NOTES TABLE ALIGNMENT
-- ---------------------------------------------------------------------------

ALTER TABLE public.home_directory_notes
  ALTER COLUMN details DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS note_type text NOT NULL DEFAULT 'general';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'home_directory_notes_details_check'
      AND conrelid = 'public.home_directory_notes'::regclass
  ) THEN
    ALTER TABLE public.home_directory_notes
      DROP CONSTRAINT home_directory_notes_details_check;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'home_directory_notes_details_check'
      AND conrelid = 'public.home_directory_notes'::regclass
  ) THEN
    ALTER TABLE public.home_directory_notes
      ADD CONSTRAINT home_directory_notes_details_check
      CHECK (details IS NULL OR char_length(details) <= 4000);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'home_directory_notes_note_type_check'
      AND conrelid = 'public.home_directory_notes'::regclass
  ) THEN
    ALTER TABLE public.home_directory_notes
      ADD CONSTRAINT home_directory_notes_note_type_check
      CHECK (note_type IN ('general', 'tutorial'));
  END IF;
END $$;

COMMENT ON TABLE public.home_directory_notes IS
  'Shared home directory notes and tutorials for operational home context. Optional reference_url and photo_path support lightweight annotations.';

-- ---------------------------------------------------------------------------
-- CONTENT READ RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_home_directory_content(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_services jsonb := '[]'::jsonb;
  v_notes jsonb := '[]'::jsonb;
  v_tutorials jsonb := '[]'::jsonb;
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
               'id', n.id,
               'home_id', n.home_id,
               'title', n.title,
               'details', n.details,
               'note_type', n.note_type,
               'reference_url', n.reference_url,
               'photo_path', n.photo_path,
               'created_at', n.created_at,
               'updated_at', n.updated_at
             )
             ORDER BY lower(n.title), n.created_at DESC, n.id
           ),
           '[]'::jsonb
         )
    INTO v_notes
  FROM public.home_directory_notes n
  WHERE n.home_id = p_home_id
    AND n.archived_at IS NULL
    AND n.note_type = 'general';

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', n.id,
               'home_id', n.home_id,
               'title', n.title,
               'details', n.details,
               'note_type', n.note_type,
               'reference_url', n.reference_url,
               'photo_path', n.photo_path,
               'created_at', n.created_at,
               'updated_at', n.updated_at
             )
             ORDER BY lower(n.title), n.created_at DESC, n.id
           ),
           '[]'::jsonb
         )
    INTO v_tutorials
  FROM public.home_directory_notes n
  WHERE n.home_id = p_home_id
    AND n.archived_at IS NULL
    AND n.note_type = 'tutorial';

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'services', v_services,
    'notes', v_notes,
    'tutorials', v_tutorials
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- NOTE RPCS
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.upsert_home_directory_note(uuid, uuid, text, text, text, text);

CREATE OR REPLACE FUNCTION public.upsert_home_directory_note(
  p_home_id uuid,
  p_note_id uuid DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_note_type text DEFAULT 'general',
  p_reference_url text DEFAULT NULL,
  p_photo_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_note public.home_directory_notes%ROWTYPE;
  v_existing public.home_directory_notes%ROWTYPE;
  v_title text := nullif(btrim(p_title), '');
  v_details text := nullif(btrim(p_details), '');
  v_note_type text := lower(COALESCE(nullif(btrim(p_note_type), ''), 'general'));
  v_reference_url text := nullif(btrim(p_reference_url), '');
  v_photo_path text := nullif(btrim(p_photo_path), '');
  v_photo_delta integer := 0;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  PERFORM public.api_assert(
    v_title IS NOT NULL,
    'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
    'title is required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_title) BETWEEN 1 AND 120,
    'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
    'title must be between 1 and 120 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    v_details IS NULL OR char_length(v_details) <= 4000,
    'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
    'details must be 4000 characters or fewer.',
    '22023'
  );

  PERFORM public.api_assert(
    v_note_type IN ('general', 'tutorial'),
    'HOUSE_DIRECTORY_NOTE_INVALID_TYPE',
    'note_type must be one of general or tutorial.',
    '22023'
  );

  PERFORM public.api_assert(
    v_reference_url IS NULL OR (char_length(v_reference_url) <= 2048 AND v_reference_url ~* '^https?://'),
    'HOUSE_DIRECTORY_NOTE_INVALID_URL',
    'reference_url must be null or an http/https URL.',
    '22023'
  );

  PERFORM public.api_assert(
    v_photo_path IS NULL
    OR (
      char_length(v_photo_path) <= 512
      AND v_photo_path LIKE 'households/%'
    ),
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'photo_path must be a storage object path under households/.',
    '22023'
  );

  IF p_note_id IS NULL THEN
    v_photo_delta := CASE WHEN v_photo_path IS NOT NULL THEN 1 ELSE 0 END;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_assert_quota(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;

    INSERT INTO public.home_directory_notes (
      home_id,
      title,
      details,
      note_type,
      reference_url,
      photo_path,
      archived_at,
      created_by_user_id,
      updated_by_user_id
    )
    VALUES (
      p_home_id,
      v_title,
      v_details,
      v_note_type,
      v_reference_url,
      v_photo_path,
      NULL,
      v_user,
      v_user
    )
    RETURNING * INTO v_note;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_usage_apply_delta(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;
  ELSE
    SELECT *
      INTO v_existing
    FROM public.home_directory_notes n
    WHERE n.id = p_note_id
      AND n.home_id = p_home_id
      AND n.archived_at IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_NOTE_NOT_FOUND',
        'The note was not found for this home, or it has been archived.',
        'P0002',
        jsonb_build_object('home_id', p_home_id, 'note_id', p_note_id)
      );
    END IF;

    v_photo_delta := CASE
      WHEN v_existing.photo_path IS NULL AND v_photo_path IS NOT NULL THEN 1
      ELSE 0
    END;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_assert_quota(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;

    UPDATE public.home_directory_notes n
       SET title = v_title,
           details = v_details,
           note_type = v_note_type,
           reference_url = v_reference_url,
           photo_path = v_photo_path,
           updated_by_user_id = v_user
     WHERE n.id = p_note_id
       AND n.home_id = p_home_id
       AND n.archived_at IS NULL
    RETURNING * INTO v_note;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_usage_apply_delta(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'note', jsonb_build_object(
      'id', v_note.id,
      'home_id', v_note.home_id,
      'title', v_note.title,
      'details', v_note.details,
      'note_type', v_note.note_type,
      'reference_url', v_note.reference_url,
      'photo_path', v_note.photo_path,
      'archived_at', v_note.archived_at,
      'created_at', v_note.created_at,
      'updated_at', v_note.updated_at
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_home_directory_note(
  p_home_id uuid,
  p_note_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_note public.home_directory_notes%ROWTYPE;
  v_existing public.home_directory_notes%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  UPDATE public.home_directory_notes n
     SET archived_at = now(),
         updated_by_user_id = v_user
   WHERE n.id = p_note_id
     AND n.home_id = p_home_id
     AND n.archived_at IS NULL
  RETURNING * INTO v_note;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_archived', false,
      'note', jsonb_build_object(
        'id', v_note.id,
        'home_id', v_note.home_id,
        'title', v_note.title,
        'details', v_note.details,
        'note_type', v_note.note_type,
        'reference_url', v_note.reference_url,
        'photo_path', v_note.photo_path,
        'archived_at', v_note.archived_at,
        'created_at', v_note.created_at,
        'updated_at', v_note.updated_at
      )
    );
  END IF;

  SELECT *
    INTO v_existing
  FROM public.home_directory_notes n
  WHERE n.id = p_note_id
    AND n.home_id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_NOTE_NOT_FOUND',
      'The note was not found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id, 'note_id', p_note_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_archived', true,
    'note', jsonb_build_object(
      'id', v_existing.id,
      'home_id', v_existing.home_id,
      'title', v_existing.title,
      'details', v_existing.details,
      'note_type', v_existing.note_type,
      'reference_url', v_existing.reference_url,
      'photo_path', v_existing.photo_path,
      'archived_at', v_existing.archived_at,
      'created_at', v_existing.created_at,
      'updated_at', v_existing.updated_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_home_directory_content(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_home_directory_content(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.upsert_home_directory_note(uuid, uuid, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_home_directory_note(uuid, uuid, text, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.archive_home_directory_note(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_home_directory_note(uuid, uuid) TO authenticated;
