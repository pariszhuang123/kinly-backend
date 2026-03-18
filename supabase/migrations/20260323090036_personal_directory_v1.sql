-- ---------------------------------------------------------------------------
-- Member Directory v1.0
--
-- User-owned reference data that can be read by active members of the same
-- active home. Tables are RPC-only. SECURITY DEFINER RPCs enforce access
-- and business rules. Internal helper functions use SET search_path = ''.
--
-- Product decisions:
-- - one active bank account per user
-- - bank account is optional
-- - bank account is visible to active members of the same active home
--   for payment purposes
-- - emergency_contact is optional and singleton
-- - allergy is optional and repeatable (one allergy per row)
-- - allergy uses a dedicated label field for chip display and search/filtering
-- - other is optional and repeatable (best-effort soft limited)
-- - for other notes, custom_title is required and details is optional
-- - completeness nudge checks only whether bank account is missing
-- - nudge is optional and dismissible; it does not force completion
-- - client owns localization for note_type labels
--
-- Assumes these helpers already exist:
-- - public._assert_authenticated()
-- - public._touch_updated_at()
-- - public.api_assert(boolean, text, text, text)
-- - public.api_error(text, text, text, jsonb default NULL)
--
-- Assumes memberships/home invariants already exist:
-- - one current membership per user via uq_memberships_user_one_current
-- - current membership implies the user's active home context
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.member_directory_bank_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  account_holder_name text NOT NULL,
  account_number text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT member_directory_bank_accounts_user_unique
    UNIQUE (user_id),

  CONSTRAINT member_directory_bank_accounts_holder_name_check
    CHECK (char_length(btrim(account_holder_name)) BETWEEN 1 AND 120),

  CONSTRAINT member_directory_bank_accounts_account_number_check
    CHECK (char_length(btrim(account_number)) BETWEEN 1 AND 50)
);

COMMENT ON TABLE public.member_directory_bank_accounts IS
'RPC-only table for a user-owned member-directory bank account. One active record per user, updated in place. Bank account is optional. When present, it is visible to active members of the same active home for payment purposes. No direct client table access.';

COMMENT ON COLUMN public.member_directory_bank_accounts.user_id IS
'Owner of the bank account record. Product intentionally supports one active bank account per user.';

COMMENT ON COLUMN public.member_directory_bank_accounts.account_holder_name IS
'Display name used by other home members when making payments.';

COMMENT ON COLUMN public.member_directory_bank_accounts.account_number IS
'Bank account number shared with active members of the same active home for payment purposes.';


CREATE TABLE IF NOT EXISTS public.member_directory_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  note_type text NOT NULL,
  label text NULL,
  custom_title text NULL,
  contact_name text NULL,
  phone_number text NULL,
  details text NULL,
  photo_path text NULL,
  archived_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT member_directory_notes_note_type_check
    CHECK (note_type IN ('emergency_contact', 'allergy', 'other')),

  CONSTRAINT member_directory_notes_label_check
    CHECK (
      (note_type = 'allergy' AND char_length(btrim(COALESCE(label, ''))) BETWEEN 1 AND 120)
      OR
      (note_type <> 'allergy' AND label IS NULL)
    ),

  CONSTRAINT member_directory_notes_other_title_check
    CHECK (
      (note_type = 'other' AND char_length(btrim(COALESCE(custom_title, ''))) BETWEEN 1 AND 80)
      OR
      (note_type <> 'other' AND custom_title IS NULL)
    ),

  CONSTRAINT member_directory_notes_emergency_fields_check
    CHECK (
      (note_type = 'emergency_contact'
        AND char_length(btrim(COALESCE(contact_name, ''))) BETWEEN 1 AND 120
        AND char_length(btrim(COALESCE(phone_number, ''))) BETWEEN 1 AND 30)
      OR
      (note_type <> 'emergency_contact' AND contact_name IS NULL AND phone_number IS NULL)
    ),

  CONSTRAINT member_directory_notes_phone_number_format_check
    CHECK (
      phone_number IS NULL
      OR (
        phone_number ~ '^[0-9+()\- ]{1,30}$'
        AND phone_number ~ '[0-9]'
      )
    ),

  CONSTRAINT member_directory_notes_details_check
    CHECK (
      (note_type = 'emergency_contact' AND (details IS NULL OR char_length(btrim(details)) <= 2000))
      OR
      (note_type = 'allergy' AND details IS NULL)
      OR
      (note_type = 'other' AND (
        details IS NULL
        OR char_length(btrim(details)) BETWEEN 1 AND 2000
      ))
    ),

  CONSTRAINT member_directory_notes_photo_path_check
    CHECK (
      photo_path IS NULL
      OR char_length(photo_path) <= 512
    )
);

COMMENT ON TABLE public.member_directory_notes IS
'RPC-only table for user-owned member-directory notes visible to active members of the same active home. Supports optional singleton emergency contact and repeatable allergy/other notes. Allergy uses label for chip display and search/filtering. Other notes are best-effort soft limited. No direct client table access.';

COMMENT ON COLUMN public.member_directory_notes.note_type IS
'Client-localized category key. Valid values: emergency_contact, allergy, other.';

COMMENT ON COLUMN public.member_directory_notes.label IS
'Dedicated allergy label. Required only for allergy rows. Intended for chip-style display and search/filtering.';

COMMENT ON COLUMN public.member_directory_notes.custom_title IS
'Required only for other notes. Client should display this directly.';

COMMENT ON COLUMN public.member_directory_notes.contact_name IS
'Required only for emergency_contact notes.';

COMMENT ON COLUMN public.member_directory_notes.phone_number IS
'Required only for emergency_contact notes. Accepts international-style free-text phone formats using digits, spaces, plus, parentheses, and hyphen.';

COMMENT ON COLUMN public.member_directory_notes.details IS
'Optional supporting details for emergency_contact notes. Forbidden for allergy rows in v1.0. Optional supporting details for other notes.';

COMMENT ON COLUMN public.member_directory_notes.photo_path IS
'Optional anonymous households-bucket object key. RPC validates only expected key structure under the user current active home path; knowledge of the key may allow retrieval depending on bucket policy.';

COMMENT ON COLUMN public.member_directory_notes.archived_at IS
'Soft-delete timestamp. Active reads exclude archived rows. Hard delete is forbidden by trigger.';


CREATE TABLE IF NOT EXISTS public.member_directory_nudge_dismissals (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  dismissed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, home_id)
);

COMMENT ON TABLE public.member_directory_nudge_dismissals IS
'RPC-only table for per-home dismissal state of the optional member-directory completeness nudge. In v1.0, the nudge checks only whether bank account information is missing. No direct client table access.';

-- ---------------------------------------------------------------------------
-- INDEXES
-- ---------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_member_directory_notes_active_emergency_contact
  ON public.member_directory_notes (user_id)
  WHERE archived_at IS NULL AND note_type = 'emergency_contact';

CREATE INDEX IF NOT EXISTS idx_member_directory_notes_user_active
  ON public.member_directory_notes (user_id, created_at DESC, id)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_member_directory_notes_user_type_active
  ON public.member_directory_notes (user_id, note_type, created_at DESC, id)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_member_directory_notes_user_allergy_label_active
  ON public.member_directory_notes (user_id, lower(label), id)
  WHERE archived_at IS NULL AND note_type = 'allergy';

-- ---------------------------------------------------------------------------
-- RLS / PERMISSIONS
-- ---------------------------------------------------------------------------

ALTER TABLE public.member_directory_bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_directory_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_directory_nudge_dismissals ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.member_directory_bank_accounts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.member_directory_notes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.member_directory_nudge_dismissals FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- TRIGGERS / INTERNAL HELPERS
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_member_directory_bank_accounts_updated_at
  ON public.member_directory_bank_accounts;

CREATE TRIGGER trg_member_directory_bank_accounts_updated_at
BEFORE UPDATE ON public.member_directory_bank_accounts
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

DROP TRIGGER IF EXISTS trg_member_directory_notes_updated_at
  ON public.member_directory_notes;

CREATE TRIGGER trg_member_directory_notes_updated_at
BEFORE UPDATE ON public.member_directory_notes
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();


CREATE OR REPLACE FUNCTION public._member_directory_prevent_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION '% rows cannot be deleted', TG_TABLE_NAME
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_member_directory_bank_accounts_prevent_delete
  ON public.member_directory_bank_accounts;

CREATE TRIGGER trg_member_directory_bank_accounts_prevent_delete
BEFORE DELETE ON public.member_directory_bank_accounts
FOR EACH ROW EXECUTE FUNCTION public._member_directory_prevent_delete();

DROP TRIGGER IF EXISTS trg_member_directory_notes_prevent_delete
  ON public.member_directory_notes;

CREATE TRIGGER trg_member_directory_notes_prevent_delete
BEFORE DELETE ON public.member_directory_notes
FOR EACH ROW EXECUTE FUNCTION public._member_directory_prevent_delete();

DROP TRIGGER IF EXISTS trg_member_directory_nudge_dismissals_prevent_delete
  ON public.member_directory_nudge_dismissals;

CREATE TRIGGER trg_member_directory_nudge_dismissals_prevent_delete
BEFORE DELETE ON public.member_directory_nudge_dismissals
FOR EACH ROW EXECUTE FUNCTION public._member_directory_prevent_delete();


CREATE OR REPLACE FUNCTION public._member_directory_enforce_other_note_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_other_count integer;
BEGIN
  IF NEW.note_type <> 'other' OR NEW.archived_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT count(*)
    INTO v_other_count
  FROM public.member_directory_notes n
  WHERE n.user_id = NEW.user_id
    AND n.note_type = 'other'
    AND n.archived_at IS NULL
    AND n.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

  IF v_other_count >= 20 THEN
    PERFORM public.api_error(
      'MEMBER_DIRECTORY_OTHER_NOTE_LIMIT_REACHED',
      'At most 20 active other notes are allowed.',
      '22023'
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_member_directory_notes_other_limit
  ON public.member_directory_notes;

CREATE TRIGGER trg_member_directory_notes_other_limit
BEFORE INSERT OR UPDATE ON public.member_directory_notes
FOR EACH ROW EXECUTE FUNCTION public._member_directory_enforce_other_note_limit();


CREATE OR REPLACE FUNCTION public._member_directory_get_current_active_home_id(
  p_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
BEGIN
  IF p_user_id IS NULL THEN
    PERFORM public.api_error(
      'MEMBER_DIRECTORY_INVALID_INPUT',
      'user_id is required.',
      '22023'
    );
  END IF;

  SELECT m.home_id
    INTO v_home_id
  FROM public.memberships m
  JOIN public.homes h
    ON h.id = m.home_id
  WHERE m.user_id = p_user_id
    AND m.is_current = TRUE
    AND h.is_active = TRUE;

  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'User does not belong to an active home.',
      '42501',
      jsonb_build_object('user_id', p_user_id)
    );
  END IF;

  RETURN v_home_id;
END;
$$;


CREATE OR REPLACE FUNCTION public._member_directory_assert_same_active_home(
  p_target_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_my_home_id uuid;
  v_target_home_id uuid;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_target_user_id IS NULL THEN
    PERFORM public.api_error(
      'MEMBER_DIRECTORY_INVALID_INPUT',
      'target_user_id is required.',
      '22023'
    );
  END IF;

  IF p_target_user_id = v_user THEN
    RETURN;
  END IF;

  v_my_home_id := public._member_directory_get_current_active_home_id(v_user);
  v_target_home_id := public._member_directory_get_current_active_home_id(p_target_user_id);

  IF v_my_home_id IS DISTINCT FROM v_target_home_id THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You do not share an active home with this member.',
      '42501',
      jsonb_build_object('target_user_id', p_target_user_id)
    );
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION public._member_directory_assert_valid_photo_path(
  p_user_id uuid,
  p_photo_path text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
  v_expected_prefix text;
BEGIN
  IF p_photo_path IS NULL THEN
    RETURN;
  END IF;

  v_home_id := public._member_directory_get_current_active_home_id(p_user_id);

  -- Assumes photo_path stores the object key inside the households bucket.
  -- Expected shape:
  --   house_directory/{home_id}/member_directory/{user_id}/...
  v_expected_prefix :=
    'house_directory/' || v_home_id::text || '/member_directory/' || p_user_id::text || '/';

  PERFORM public.api_assert(
    p_photo_path LIKE v_expected_prefix || '%',
    'MEMBER_DIRECTORY_NOTE_INVALID_PHOTO_PATH',
    'photo_path must be under house_directory/{home_id}/member_directory/{user_id}/ in the households bucket.',
    '22023'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- RPCS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_member_directory_bank_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row public.member_directory_bank_accounts%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT *
    INTO v_row
  FROM public.member_directory_bank_accounts b
  WHERE b.user_id = v_user;

  RETURN jsonb_build_object(
    'ok', true,
    'has_bank_account', FOUND,
    'bank_account',
      CASE
        WHEN FOUND THEN jsonb_build_object(
          'id', v_row.id,
          'account_holder_name', v_row.account_holder_name,
          'account_number', v_row.account_number,
          'created_at', v_row.created_at,
          'updated_at', v_row.updated_at
        )
        ELSE NULL
      END
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.upsert_member_directory_bank_account(
  p_account_holder_name text,
  p_account_number text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_account_holder_name text := nullif(btrim(p_account_holder_name), '');
  v_account_number text := nullif(btrim(p_account_number), '');
  v_row public.member_directory_bank_accounts%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    v_account_holder_name IS NOT NULL,
    'MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS',
    'account_holder_name is required.',
    '22023'
  );

  PERFORM public.api_assert(
    v_account_number IS NOT NULL,
    'MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS',
    'account_number is required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_account_holder_name) <= 120,
    'MEMBER_DIRECTORY_INVALID_INPUT',
    'account_holder_name must be between 1 and 120 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_account_number) <= 50,
    'MEMBER_DIRECTORY_INVALID_INPUT',
    'account_number must be between 1 and 50 characters.',
    '22023'
  );

  INSERT INTO public.member_directory_bank_accounts (
    user_id,
    account_holder_name,
    account_number
  )
  VALUES (
    v_user,
    v_account_holder_name,
    v_account_number
  )
  ON CONFLICT (user_id)
  DO UPDATE SET
    account_holder_name = EXCLUDED.account_holder_name,
    account_number = EXCLUDED.account_number
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'has_bank_account', true,
    'bank_account', jsonb_build_object(
      'id', v_row.id,
      'account_holder_name', v_row.account_holder_name,
      'account_number', v_row.account_number,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at
    )
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.get_member_bank_account(
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.member_directory_bank_accounts%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._member_directory_assert_same_active_home(p_target_user_id);

  SELECT *
    INTO v_row
  FROM public.member_directory_bank_accounts b
  WHERE b.user_id = p_target_user_id;

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', p_target_user_id,
    'has_bank_account', FOUND,
    'bank_account',
      CASE
        WHEN FOUND THEN jsonb_build_object(
          'id', v_row.id,
          'account_holder_name', v_row.account_holder_name,
          'account_number', v_row.account_number
        )
        ELSE NULL
      END
  );
END;
$$;


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


CREATE OR REPLACE FUNCTION public.create_member_directory_note(
  p_note_type text,
  p_label text DEFAULT NULL,
  p_custom_title text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_phone_number text DEFAULT NULL,
  p_details text DEFAULT NULL,
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


CREATE OR REPLACE FUNCTION public.update_member_directory_note(
  p_note_id uuid,
  p_label text DEFAULT NULL,
  p_custom_title text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_phone_number text DEFAULT NULL,
  p_details text DEFAULT NULL,
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
      'photo_path', v_row.photo_path,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at
    )
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.archive_member_directory_note(
  p_note_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
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
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'MEMBER_DIRECTORY_NOTE_NOT_FOUND',
      'Member directory note was not found.',
      'P0002',
      jsonb_build_object('note_id', p_note_id)
    );
  END IF;

  IF v_existing.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'note_id', v_existing.id,
      'already_archived', true,
      'archived_at', v_existing.archived_at
    );
  END IF;

  UPDATE public.member_directory_notes n
     SET archived_at = now()
   WHERE n.id = p_note_id
     AND n.user_id = v_user
     AND n.archived_at IS NULL
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'note_id', v_row.id,
    'already_archived', false,
    'archived_at', v_row.archived_at
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.get_member_directory_nudge()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home_id uuid;
  v_missing text[] := ARRAY[]::text[];
  v_show boolean := false;
BEGIN
  PERFORM public._assert_authenticated();

  v_home_id := public._member_directory_get_current_active_home_id(v_user);

  IF NOT EXISTS (
    SELECT 1
    FROM public.member_directory_bank_accounts b
    WHERE b.user_id = v_user
  ) THEN
    v_missing := array_append(v_missing, 'bank_account');
  END IF;

  v_show := array_length(v_missing, 1) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.member_directory_nudge_dismissals d
      WHERE d.user_id = v_user
        AND d.home_id = v_home_id
    );

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', v_home_id,
    'show', v_show,
    'missing', to_jsonb(CASE WHEN v_show THEN v_missing ELSE ARRAY[]::text[] END)
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.dismiss_member_directory_nudge()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home_id uuid;
  v_already_dismissed boolean := false;
  v_dismissed_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();

  v_home_id := public._member_directory_get_current_active_home_id(v_user);

  SELECT d.dismissed_at
    INTO v_dismissed_at
  FROM public.member_directory_nudge_dismissals d
  WHERE d.user_id = v_user
    AND d.home_id = v_home_id;

  IF FOUND THEN
    v_already_dismissed := true;
  ELSE
    INSERT INTO public.member_directory_nudge_dismissals (
      user_id,
      home_id
    )
    VALUES (
      v_user,
      v_home_id
    )
    RETURNING dismissed_at INTO v_dismissed_at;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', v_home_id,
    'already_dismissed', v_already_dismissed,
    'dismissed_at', v_dismissed_at
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- FUNCTION COMMENTS
-- ---------------------------------------------------------------------------

COMMENT ON FUNCTION public._member_directory_prevent_delete() IS
'Internal trigger function that forbids hard deletes from member-directory tables.';

COMMENT ON FUNCTION public._member_directory_enforce_other_note_limit() IS
'Internal trigger function that enforces the best-effort soft cap on active other notes per user.';

COMMENT ON FUNCTION public._member_directory_get_current_active_home_id(uuid) IS
'Internal helper that returns the user current active home id using the memberships table and an active home row.';

COMMENT ON FUNCTION public._member_directory_assert_same_active_home(uuid) IS
'Internal helper that allows access only when the authenticated user is the target user or shares the same active home with the target user.';

COMMENT ON FUNCTION public._member_directory_assert_valid_photo_path(uuid, text) IS
'Internal helper that validates note photo_path against the user current active home and expected households-bucket object key prefix. Validation is path-shape only.';

COMMENT ON FUNCTION public.get_member_directory_bank_account() IS
'Returns the authenticated user current member-directory bank account, if any, plus has_bank_account for explicit client handling. RPC-only.';

COMMENT ON FUNCTION public.upsert_member_directory_bank_account(text, text) IS
'Creates or updates the authenticated user single active member-directory bank account. Bank account is optional overall, but required when this RPC is called.';

COMMENT ON FUNCTION public.get_member_bank_account(uuid) IS
'Returns the target member bank account only when the authenticated caller and target member share the same active home. Intended for household payment flows. Includes has_bank_account for explicit client handling.';

COMMENT ON FUNCTION public.get_member_directory_notes(uuid) IS
'Returns active member-directory notes for the target user when the caller is the same user or shares the same active home. Client owns localization for note_type labels.';

COMMENT ON FUNCTION public.create_member_directory_note(text, text, text, text, text, text, text) IS
'Creates a new member-directory note for the authenticated user. emergency_contact is singleton; allergy and other are repeatable. Allergy uses label. For other notes, custom_title is required and details is optional.';

COMMENT ON FUNCTION public.update_member_directory_note(uuid, text, text, text, text, text, text) IS
'Updates an existing active member-directory note owned by the authenticated user. Note type is immutable after creation. Allergy uses label. For other notes, custom_title is required and details is optional.';

COMMENT ON FUNCTION public.archive_member_directory_note(uuid) IS
'Soft-archives an active member-directory note owned by the authenticated user. Archived notes are excluded from active reads.';

COMMENT ON FUNCTION public.get_member_directory_nudge() IS
'Returns whether the authenticated user should be shown the optional member-directory completeness nudge for their current active home. In v1.0, the nudge checks only whether bank account information is missing.';

COMMENT ON FUNCTION public.dismiss_member_directory_nudge() IS
'Dismisses the optional member-directory completeness nudge for the authenticated user in their current active home.';

-- ---------------------------------------------------------------------------
-- FUNCTION PERMISSIONS
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._member_directory_prevent_delete() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._member_directory_enforce_other_note_limit() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._member_directory_get_current_active_home_id(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._member_directory_assert_same_active_home(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._member_directory_assert_valid_photo_path(uuid, text) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_member_directory_bank_account() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_member_directory_bank_account() TO authenticated;

REVOKE ALL ON FUNCTION public.upsert_member_directory_bank_account(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_member_directory_bank_account(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.get_member_bank_account(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_member_bank_account(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_member_directory_notes(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_member_directory_notes(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.create_member_directory_note(text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_member_directory_note(text, text, text, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.update_member_directory_note(uuid, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_member_directory_note(uuid, text, text, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.archive_member_directory_note(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_member_directory_note(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_member_directory_nudge() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_member_directory_nudge() TO authenticated;

REVOKE ALL ON FUNCTION public.dismiss_member_directory_nudge() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_member_directory_nudge() TO authenticated;