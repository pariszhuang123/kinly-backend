ALTER TABLE public.member_directory_notes
  ADD COLUMN IF NOT EXISTS reference_url text NULL;

ALTER TABLE public.member_directory_notes
  DROP CONSTRAINT IF EXISTS member_directory_notes_reference_url_check;

ALTER TABLE public.member_directory_notes
  ADD CONSTRAINT member_directory_notes_reference_url_check
  CHECK (
    reference_url IS NULL
    OR (
      char_length(reference_url) <= 2048
      AND reference_url ~* '^https?://'
    )
  );

COMMENT ON COLUMN public.member_directory_notes.reference_url IS
'Optional http/https URL attached to a member-directory note for supporting context or follow-up.';

CREATE OR REPLACE FUNCTION public.get_member_directory_notes(
  p_target_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_target_user_id uuid := COALESCE(p_target_user_id, v_user);
  v_notes jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._member_directory_assert_same_active_home(v_target_user_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', n.id,
               'note_type', n.note_type,
               'label', n.label,
               'custom_title', n.custom_title,
               'contact_name', n.contact_name,
               'phone_number', n.phone_number,
               'details', n.details,
               'reference_url', n.reference_url,
               'photo_path', n.photo_path,
               'created_at', n.created_at,
               'updated_at', n.updated_at
             )
             ORDER BY
               CASE n.note_type
                 WHEN 'emergency_contact' THEN 0
                 WHEN 'allergy' THEN 1
                 ELSE 2
               END,
               CASE
                 WHEN n.note_type = 'allergy' THEN lower(n.label)
                 ELSE NULL
               END,
               CASE
                 WHEN n.note_type = 'other' THEN n.created_at
                 ELSE NULL
               END DESC,
               n.id
           ),
           '[]'::jsonb
         )
    INTO v_notes
  FROM public.member_directory_notes n
  WHERE n.user_id = v_target_user_id
    AND n.archived_at IS NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', v_target_user_id,
    'notes', v_notes
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.create_member_directory_note_v2(
  p_note_type text,
  p_label text DEFAULT NULL,
  p_custom_title text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_phone_number text DEFAULT NULL,
  p_details text DEFAULT NULL,
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
  v_note_type text := lower(COALESCE(nullif(btrim(p_note_type), ''), ''));
  v_label text := nullif(btrim(p_label), '');
  v_custom_title text := nullif(btrim(p_custom_title), '');
  v_contact_name text := nullif(btrim(p_contact_name), '');
  v_phone_number text := nullif(btrim(p_phone_number), '');
  v_details text := nullif(btrim(p_details), '');
  v_reference_url text := nullif(btrim(p_reference_url), '');
  v_photo_path text := nullif(btrim(p_photo_path), '');
  v_active_other_count integer;
  v_row public.member_directory_notes%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    v_note_type IN ('emergency_contact', 'allergy', 'other'),
    'MEMBER_DIRECTORY_INVALID_ENUM',
    'note_type must be emergency_contact, allergy, or other.',
    '22023'
  );

  PERFORM public.api_assert(
    v_reference_url IS NULL
    OR (
      char_length(v_reference_url) <= 2048
      AND v_reference_url ~* '^https?://'
    ),
    'MEMBER_DIRECTORY_INVALID_REFERENCE_URL',
    'reference_url must be null or an http/https URL.',
    '22023'
  );

  PERFORM public._member_directory_assert_valid_photo_path(v_user, v_photo_path);

  IF v_note_type = 'allergy' THEN
    PERFORM public.api_assert(
      v_label IS NOT NULL,
      'MEMBER_DIRECTORY_ALLERGY_LABEL_REQUIRED',
      'label is required for allergy notes.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_label IS NULL,
      'MEMBER_DIRECTORY_ALLERGY_LABEL_FORBIDDEN',
      'label is only allowed for allergy notes.',
      '22023'
    );
  END IF;

  IF v_note_type = 'other' THEN
    PERFORM public.api_assert(
      v_custom_title IS NOT NULL,
      'MEMBER_DIRECTORY_OTHER_TITLE_REQUIRED',
      'custom_title is required for other notes.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_custom_title IS NULL,
      'MEMBER_DIRECTORY_OTHER_TITLE_FORBIDDEN',
      'custom_title is only allowed for other notes.',
      '22023'
    );
  END IF;

  IF v_note_type = 'emergency_contact' THEN
    PERFORM public.api_assert(
      v_contact_name IS NOT NULL AND v_phone_number IS NOT NULL,
      'MEMBER_DIRECTORY_EMERGENCY_CONTACT_REQUIRED_FIELDS',
      'contact_name and phone_number are required for emergency_contact notes.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_contact_name IS NULL AND v_phone_number IS NULL,
      'MEMBER_DIRECTORY_CONTACT_FIELDS_FORBIDDEN',
      'contact_name and phone_number are only allowed for emergency_contact notes.',
      '22023'
    );
  END IF;

  PERFORM public.api_assert(
    v_phone_number IS NULL
    OR (
      v_phone_number ~ '^[0-9+()\- ]{1,30}$'
      AND v_phone_number ~ '[0-9]'
    ),
    'MEMBER_DIRECTORY_INVALID_PHONE_NUMBER',
    'phone_number must use digits, spaces, plus, parentheses, or hyphen and contain at least one digit.',
    '22023'
  );

  IF v_note_type = 'allergy' THEN
    PERFORM public.api_assert(
      v_details IS NULL,
      'MEMBER_DIRECTORY_DETAILS_FORBIDDEN',
      'details is not allowed for allergy notes.',
      '22023'
    );
  END IF;

  IF v_note_type = 'other' THEN
    SELECT count(*)
      INTO v_active_other_count
    FROM public.member_directory_notes n
    WHERE n.user_id = v_user
      AND n.note_type = 'other'
      AND n.archived_at IS NULL;

    PERFORM public.api_assert(
      v_active_other_count < 20,
      'MEMBER_DIRECTORY_OTHER_NOTE_LIMIT_REACHED',
      'At most 20 active other notes are allowed.',
      '22023'
    );
  END IF;

  INSERT INTO public.member_directory_notes (
    user_id,
    note_type,
    label,
    custom_title,
    contact_name,
    phone_number,
    details,
    reference_url,
    photo_path
  )
  VALUES (
    v_user,
    v_note_type,
    v_label,
    v_custom_title,
    v_contact_name,
    v_phone_number,
    v_details,
    v_reference_url,
    v_photo_path
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'note', jsonb_build_object(
      'id', v_row.id,
      'note_type', v_row.note_type,
      'label', v_row.label,
      'custom_title', v_row.custom_title,
      'contact_name', v_row.contact_name,
      'phone_number', v_row.phone_number,
      'details', v_row.details,
      'reference_url', v_row.reference_url,
      'photo_path', v_row.photo_path,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at
    )
  );

EXCEPTION
  WHEN unique_violation THEN
    IF v_note_type = 'emergency_contact' THEN
      PERFORM public.api_error(
        'MEMBER_DIRECTORY_NOTE_TYPE_CONFLICT',
        'An active emergency_contact note already exists.',
        '23505'
      );
    END IF;
    RAISE;
END;
$$;


CREATE OR REPLACE FUNCTION public.update_member_directory_note_v2(
  p_note_id uuid,
  p_label text DEFAULT NULL,
  p_custom_title text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_phone_number text DEFAULT NULL,
  p_details text DEFAULT NULL,
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
  v_label text := nullif(btrim(p_label), '');
  v_custom_title text := nullif(btrim(p_custom_title), '');
  v_contact_name text := nullif(btrim(p_contact_name), '');
  v_phone_number text := nullif(btrim(p_phone_number), '');
  v_details text := nullif(btrim(p_details), '');
  v_reference_url text := nullif(btrim(p_reference_url), '');
  v_photo_path text := nullif(btrim(p_photo_path), '');
  v_existing public.member_directory_notes%ROWTYPE;
  v_row public.member_directory_notes%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_note_id IS NOT NULL,
    'MEMBER_DIRECTORY_INVALID_INPUT',
    'note_id is required.',
    '22023'
  );

  SELECT *
    INTO v_existing
  FROM public.member_directory_notes n
  WHERE n.id = p_note_id
    AND n.user_id = v_user
    AND n.archived_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'MEMBER_DIRECTORY_NOTE_NOT_FOUND',
      'Member directory note was not found.',
      'P0002',
      jsonb_build_object('note_id', p_note_id)
    );
  END IF;

  PERFORM public.api_assert(
    v_reference_url IS NULL
    OR (
      char_length(v_reference_url) <= 2048
      AND v_reference_url ~* '^https?://'
    ),
    'MEMBER_DIRECTORY_INVALID_REFERENCE_URL',
    'reference_url must be null or an http/https URL.',
    '22023'
  );

  PERFORM public._member_directory_assert_valid_photo_path(v_user, v_photo_path);

  IF v_existing.note_type = 'allergy' THEN
    PERFORM public.api_assert(
      v_label IS NOT NULL,
      'MEMBER_DIRECTORY_ALLERGY_LABEL_REQUIRED',
      'label is required for allergy notes.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_label IS NULL,
      'MEMBER_DIRECTORY_ALLERGY_LABEL_FORBIDDEN',
      'label is only allowed for allergy notes.',
      '22023'
    );
  END IF;

  IF v_existing.note_type = 'other' THEN
    PERFORM public.api_assert(
      v_custom_title IS NOT NULL,
      'MEMBER_DIRECTORY_OTHER_TITLE_REQUIRED',
      'custom_title is required for other notes.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_custom_title IS NULL,
      'MEMBER_DIRECTORY_OTHER_TITLE_FORBIDDEN',
      'custom_title is only allowed for other notes.',
      '22023'
    );
  END IF;

  IF v_existing.note_type = 'emergency_contact' THEN
    PERFORM public.api_assert(
      v_contact_name IS NOT NULL AND v_phone_number IS NOT NULL,
      'MEMBER_DIRECTORY_EMERGENCY_CONTACT_REQUIRED_FIELDS',
      'contact_name and phone_number are required for emergency_contact notes.',
      '22023'
    );
  ELSE
    PERFORM public.api_assert(
      v_contact_name IS NULL AND v_phone_number IS NULL,
      'MEMBER_DIRECTORY_CONTACT_FIELDS_FORBIDDEN',
      'contact_name and phone_number are only allowed for emergency_contact notes.',
      '22023'
    );
  END IF;

  PERFORM public.api_assert(
    v_phone_number IS NULL
    OR (
      v_phone_number ~ '^[0-9+()\- ]{1,30}$'
      AND v_phone_number ~ '[0-9]'
    ),
    'MEMBER_DIRECTORY_INVALID_PHONE_NUMBER',
    'phone_number must use digits, spaces, plus, parentheses, or hyphen and contain at least one digit.',
    '22023'
  );

  IF v_existing.note_type = 'allergy' THEN
    PERFORM public.api_assert(
      v_details IS NULL,
      'MEMBER_DIRECTORY_DETAILS_FORBIDDEN',
      'details is not allowed for allergy notes.',
      '22023'
    );
  END IF;

  UPDATE public.member_directory_notes n
     SET label = v_label,
         custom_title = v_custom_title,
         contact_name = v_contact_name,
         phone_number = v_phone_number,
         details = v_details,
         reference_url = v_reference_url,
         photo_path = v_photo_path
   WHERE n.id = p_note_id
     AND n.user_id = v_user
     AND n.archived_at IS NULL
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'note', jsonb_build_object(
      'id', v_row.id,
      'note_type', v_row.note_type,
      'label', v_row.label,
      'custom_title', v_row.custom_title,
      'contact_name', v_row.contact_name,
      'phone_number', v_row.phone_number,
      'details', v_row.details,
      'reference_url', v_row.reference_url,
      'photo_path', v_row.photo_path,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at
    )
  );
END;
$$;


COMMENT ON FUNCTION public.get_member_directory_notes(uuid) IS
'Returns active member-directory notes for the target user when the caller is the same user or shares the same active home. Includes reference_url and photo_path when present. Client owns localization for note_type labels.';

COMMENT ON FUNCTION public.create_member_directory_note_v2(text, text, text, text, text, text, text, text) IS
'Creates a new member-directory note for the authenticated user. v2 adds optional reference_url support while preserving v1 validation and note-type semantics.';

COMMENT ON FUNCTION public.update_member_directory_note_v2(uuid, text, text, text, text, text, text, text) IS
'Updates an existing active member-directory note owned by the authenticated user. v2 adds optional reference_url support while preserving v1 validation and immutable note_type semantics.';

REVOKE ALL ON FUNCTION public.create_member_directory_note_v2(text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_member_directory_note_v2(text, text, text, text, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.update_member_directory_note_v2(uuid, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_member_directory_note_v2(uuid, text, text, text, text, text, text, text) TO authenticated;
