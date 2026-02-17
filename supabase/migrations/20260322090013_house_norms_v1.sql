-- House Norms v1 (web publish explicit): schema + RPCs
-- Key semantics:
-- - generated_content = realtime draft (in-app)
-- - published_content = last web/share snapshot (explicit publish)
-- - edit updates generated_content only (never published)
-- - publish copies generated -> published
-- - status out_of_date when generated differs from published OR published is NULL
--
-- Option A: DB publish update occurs BEFORE edge sync call, but failures
-- MUST raise exceptions so the whole transaction rolls back.
--
-- Adjustment included: send canonical ISO UTC string (matches JS toISOString())
-- to the edge function (published_at).

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

-- If table exists with old "locale" column, migrate to locale_base.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='house_norms' AND column_name='locale'
  )
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='house_norms' AND column_name='locale_base'
  )
  THEN
    ALTER TABLE public.house_norms RENAME COLUMN locale TO locale_base;
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.house_norms (
  home_id uuid PRIMARY KEY REFERENCES public.homes(id) ON DELETE CASCADE,
  template_key text NOT NULL,
  locale_base text NOT NULL,
  status text NOT NULL DEFAULT 'out_of_date', -- out_of_date until explicitly published
  inputs jsonb NOT NULL,

  -- Draft (realtime in-app)
  generated_content jsonb NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),

  -- Web/share snapshot (explicit publish)
  published_content jsonb NULL,
  published_at timestamptz NULL,
  home_public_id public.citext NULL,
  published_version text NULL,

  last_edited_at timestamptz NULL,
  last_edited_by uuid NULL REFERENCES public.profiles(id) ON DELETE SET NULL,

  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT house_norms_status_check
    CHECK (status IN ('published', 'out_of_date')),

  CONSTRAINT house_norms_template_key_check
    CHECK (template_key ~ '^[a-z0-9_]{1,64}$'),

  -- Table-level locale_base check (ISO 639-1, lowercase)
  CONSTRAINT house_norms_locale_base_check
    CHECK (locale_base ~ '^[a-z]{2}$'),

  CONSTRAINT house_norms_inputs_object_check
    CHECK (jsonb_typeof(inputs) = 'object'),

  CONSTRAINT house_norms_generated_content_object_check
    CHECK (jsonb_typeof(generated_content) = 'object'),

  CONSTRAINT house_norms_published_content_object_check
    CHECK (published_content IS NULL OR jsonb_typeof(published_content) = 'object')
);

-- Ensure defaults / nullability in case table already existed with older shape
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='house_norms'
      AND column_name='published_content' AND is_nullable='NO'
  ) THEN
    ALTER TABLE public.house_norms ALTER COLUMN published_content DROP NOT NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='house_norms'
      AND column_name='published_at' AND is_nullable='NO'
  ) THEN
    ALTER TABLE public.house_norms ALTER COLUMN published_at DROP NOT NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='house_norms'
      AND column_name='home_public_id'
  ) THEN
    ALTER TABLE public.house_norms
      ADD COLUMN home_public_id public.citext NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='house_norms'
      AND column_name='published_version'
  ) THEN
    ALTER TABLE public.house_norms
      ADD COLUMN published_version text NULL;
  END IF;

  BEGIN
    ALTER TABLE public.house_norms ALTER COLUMN status SET DEFAULT 'out_of_date';
  EXCEPTION WHEN others THEN
    -- ignore if column missing/locked/etc.
  END;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'house_norms_published_version_check'
      AND conrelid = 'public.house_norms'::regclass
  ) THEN
    ALTER TABLE public.house_norms
      ADD CONSTRAINT house_norms_published_version_check
      CHECK (
        published_version IS NULL
        OR published_version ~ '^v[0-9]{6}$'
      );
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS house_norms_home_public_id_unique_idx
  ON public.house_norms (home_public_id)
  WHERE home_public_id IS NOT NULL;

-- Template key exact constraint (hardens data integrity)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'house_norms_template_key_exact_check'
      AND conrelid = 'public.house_norms'::regclass
  ) THEN
    ALTER TABLE public.house_norms
      ADD CONSTRAINT house_norms_template_key_exact_check
      CHECK (template_key = 'house_norms_v1');
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.house_norms_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.house_norms(home_id) ON DELETE CASCADE,
  editor_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  edited_at timestamptz NOT NULL DEFAULT now(),
  content jsonb NOT NULL, -- stores draft snapshot after each edit
  change_summary text NULL,
  CONSTRAINT house_norms_revisions_content_object_check CHECK (jsonb_typeof(content) = 'object')
);

-- Index supports:
-- - listing latest revisions per home
-- - retention deletes with ORDER BY edited_at DESC, id DESC OFFSET ...
CREATE INDEX IF NOT EXISTS house_norms_revisions_home_edited_id_idx
  ON public.house_norms_revisions (home_id, edited_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS public.house_norm_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_key text NOT NULL,
  locale_base text NOT NULL,
  body jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT house_norm_templates_template_key_check
    CHECK (template_key ~ '^[a-z0-9_]{1,64}$'),
  CONSTRAINT house_norm_templates_locale_base_check
    CHECK (locale_base ~ '^[a-z]{2}$'),
  CONSTRAINT house_norm_templates_body_object_check
    CHECK (jsonb_typeof(body) = 'object'),
  CONSTRAINT house_norm_templates_unique_key_locale
    UNIQUE (template_key, locale_base)
);

CREATE INDEX IF NOT EXISTS house_norm_templates_lookup_idx
  ON public.house_norm_templates (template_key, locale_base);

DROP TRIGGER IF EXISTS trg_house_norm_templates_touch_updated_at ON public.house_norm_templates;
CREATE TRIGGER trg_house_norm_templates_touch_updated_at
BEFORE UPDATE ON public.house_norm_templates
FOR EACH ROW
EXECUTE FUNCTION public._touch_updated_at();

CREATE OR REPLACE FUNCTION public._house_norm_templates_validate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_section_keys constant text[] := ARRAY[
    'norms_rhythm_quiet',
    'norms_shared_spaces',
    'norms_guests_social',
    'norms_responsibility_flow',
    'norms_repair_style',
    'norms_home_identity'
  ];
  v_section_key text;
  v_option_key text;
BEGIN
  PERFORM public.api_assert(
    jsonb_typeof(NEW.body) = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body must be a JSON object.',
    '22023'
  );

  PERFORM public.api_assert(
    jsonb_typeof(NEW.body->'summary') = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.summary must be an object.',
    '22023'
  );

  PERFORM public.api_assert(
    nullif(btrim(NEW.body->'summary'->>'title_key'), '') IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.summary.title_key is required.',
    '22023'
  );

  PERFORM public.api_assert(
    nullif(btrim(NEW.body->'summary'->>'subtitle_key'), '') IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.summary.subtitle_key is required.',
    '22023'
  );

  PERFORM public.api_assert(
    nullif(btrim(NEW.body->'summary'->>'framing_default'), '') IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.summary.framing_default is required.',
    '22023'
  );

  PERFORM public.api_assert(
    jsonb_typeof(NEW.body->'context') = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.context must be an object.',
    '22023'
  );

  PERFORM public.api_assert(
    nullif(btrim(NEW.body->'context'->>'line_template'), '') IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.context.line_template is required.',
    '22023'
  );

  PERFORM public.api_assert(
    jsonb_typeof(NEW.body->'context'->'property_context') = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.context.property_context must be an object.',
    '22023'
  );

  PERFORM public.api_assert(
    jsonb_typeof(NEW.body->'context'->'relationship_model') = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.context.relationship_model must be an object.',
    '22023'
  );

  FOREACH v_option_key IN ARRAY ARRAY['0', '1', '2'] LOOP
    PERFORM public.api_assert(
      nullif(btrim(NEW.body->'context'->'property_context'->>v_option_key), '') IS NOT NULL,
      'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
      'Template context.property_context must include options 0,1,2.',
      '22023',
      jsonb_build_object('option_key', v_option_key)
    );

    PERFORM public.api_assert(
      nullif(btrim(NEW.body->'context'->'relationship_model'->>v_option_key), '') IS NOT NULL,
      'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
      'Template context.relationship_model must include options 0,1,2.',
      '22023',
      jsonb_build_object('option_key', v_option_key)
    );
  END LOOP;

  PERFORM public.api_assert(
    jsonb_typeof(NEW.body->'sections') = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.sections must be an object.',
    '22023'
  );

  PERFORM public.api_assert(
    NOT EXISTS (
      SELECT 1
      FROM jsonb_object_keys(NEW.body->'sections') AS k
      WHERE NOT (k = ANY(v_section_keys))
    ),
    'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
    'Template body.sections contains unknown section keys.',
    '22023'
  );

  FOREACH v_section_key IN ARRAY v_section_keys LOOP
    PERFORM public.api_assert(
      jsonb_typeof(NEW.body->'sections'->v_section_key) = 'object',
      'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
      'Template section must be an object.',
      '22023',
      jsonb_build_object('section_key', v_section_key)
    );

    PERFORM public.api_assert(
      nullif(btrim(NEW.body->'sections'->v_section_key->>'title_key'), '') IS NOT NULL,
      'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
      'Template section title_key is required.',
      '22023',
      jsonb_build_object('section_key', v_section_key)
    );

    PERFORM public.api_assert(
      jsonb_typeof(NEW.body->'sections'->v_section_key->'options') = 'object',
      'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
      'Template section options must be an object.',
      '22023',
      jsonb_build_object('section_key', v_section_key)
    );

    FOREACH v_option_key IN ARRAY ARRAY['0', '1', '2'] LOOP
      PERFORM public.api_assert(
        nullif(btrim(NEW.body->'sections'->v_section_key->'options'->>v_option_key), '') IS NOT NULL,
        'HOUSE_NORMS_INVALID_TEMPLATE_SCHEMA',
        'Template section options must include 0,1,2.',
        '22023',
        jsonb_build_object('section_key', v_section_key, 'option_key', v_option_key)
      );
    END LOOP;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_house_norm_templates_validate ON public.house_norm_templates;
CREATE TRIGGER trg_house_norm_templates_validate
BEFORE INSERT OR UPDATE ON public.house_norm_templates
FOR EACH ROW
EXECUTE FUNCTION public._house_norm_templates_validate();

INSERT INTO public.house_norm_templates (template_key, locale_base, body)
VALUES (
  'house_norms_v1',
  'en',
  $${
    "summary": {
      "title_key": "house_norms_title",
      "subtitle_key": "house_norms_subtitle",
      "framing_default": "We aim for a home where people can stay calm, understand each other, and keep everyday life workable together."
    },
    "context": {
      "line_template": "This is a {{property_context}} shared by {{relationship_model}}, and these norms are a gentle starting point.",
      "property_context": {
        "0": "owner-occupied home",
        "1": "rented whole home",
        "2": "shared-room rental home"
      },
      "relationship_model": {
        "0": "housemates",
        "1": "family",
        "2": "family and housemates"
      }
    },
    "sections": {
      "norms_rhythm_quiet": {
        "title_key": "house_norms_section_rhythm_quiet_title",
        "options": {
          "0": "We usually wind down later in the day so the home can rest.",
          "1": "We adapt night to night, with quieter and livelier evenings depending on context.",
          "2": "We make room for different schedules and keep things considerate when others are resting."
        }
      },
      "norms_shared_spaces": {
        "title_key": "house_norms_section_shared_spaces_title",
        "options": {
          "0": "We try to keep shared spaces clear and ready for the next person.",
          "1": "We are okay with lived-in spaces and usually reset them a bit later.",
          "2": "We accept some mess as part of shared life and reset when it makes sense."
        }
      },
      "norms_guests_social": {
        "title_key": "house_norms_section_guests_social_title",
        "options": {
          "0": "We plan and discuss guests in advance when possible.",
          "1": "A quick heads-up is usually enough before people come by.",
          "2": "Guests are part of daily life here, with basic awareness for everyone sharing the home."
        }
      },
      "norms_responsibility_flow": {
        "title_key": "house_norms_section_responsibility_flow_title",
        "options": {
          "0": "We prefer clear agreements about who handles what.",
          "1": "We tend to handle things when someone notices and can take care of them.",
          "2": "People mainly handle their own areas while still being mindful of shared needs."
        }
      },
      "norms_repair_style": {
        "title_key": "house_norms_section_repair_style_title",
        "options": {
          "0": "When tension appears, we try to talk sooner rather than later.",
          "1": "We check in gently when the moment feels right.",
          "2": "We often let smaller things pass unless they begin to build up."
        }
      },
      "norms_home_identity": {
        "title_key": "house_norms_section_home_identity_title",
        "options": {
          "0": "We aim for a calm home that helps people recharge.",
          "1": "We value a balance of quiet time and shared moments.",
          "2": "We enjoy a lively home where people come and go with mutual awareness."
        }
      }
    }
  }$$::jsonb
)
ON CONFLICT (template_key, locale_base) DO UPDATE
SET body = EXCLUDED.body,
    updated_at = now();

INSERT INTO public.house_norm_templates (template_key, locale_base, body)
VALUES (
  'house_norms_v1',
  'es',
  $${
    "summary": {
      "title_key": "house_norms_title",
      "subtitle_key": "house_norms_subtitle",
      "framing_default": "Buscamos un hogar donde las personas puedan mantenerse en calma, comprenderse y hacer que la vida diaria funcione en conjunto."
    },
    "context": {
      "line_template": "Este es un {{property_context}} compartido por {{relationship_model}}, y estas normas son un punto de partida amable.",
      "property_context": {
        "0": "hogar en propiedad",
        "1": "hogar alquilado completo",
        "2": "hogar de alquiler con habitacion compartida"
      },
      "relationship_model": {
        "0": "companeros de casa",
        "1": "familia",
        "2": "familia y companeros de casa"
      }
    },
    "sections": {
      "norms_rhythm_quiet": {
        "title_key": "house_norms_section_rhythm_quiet_title",
        "options": {
          "0": "Solemos bajar el ritmo mas tarde para que el hogar pueda descansar.",
          "1": "Nos adaptamos cada noche, con veladas mas tranquilas o mas activas segun el contexto.",
          "2": "Damos espacio a horarios distintos y procuramos ser considerados cuando otras personas estan descansando."
        }
      },
      "norms_shared_spaces": {
        "title_key": "house_norms_section_shared_spaces_title",
        "options": {
          "0": "Intentamos mantener los espacios compartidos despejados y listos para la siguiente persona.",
          "1": "Nos parece bien que haya senales de uso y solemos ordenar un poco mas tarde.",
          "2": "Aceptamos algo de desorden como parte de la vida compartida y ordenamos cuando tiene sentido."
        }
      },
      "norms_guests_social": {
        "title_key": "house_norms_section_guests_social_title",
        "options": {
          "0": "Cuando es posible, planificamos y conversamos sobre visitas con antelacion.",
          "1": "Un aviso breve suele ser suficiente antes de que alguien venga.",
          "2": "Las visitas forman parte de la vida diaria aqui, con una conciencia basica de quienes comparten el hogar."
        }
      },
      "norms_responsibility_flow": {
        "title_key": "house_norms_section_responsibility_flow_title",
        "options": {
          "0": "Preferimos acuerdos claros sobre quien se encarga de cada cosa.",
          "1": "Solemos resolver las cosas cuando alguien lo nota y puede hacerse cargo.",
          "2": "Cada persona atiende sobre todo sus areas, sin perder de vista las necesidades compartidas."
        }
      },
      "norms_repair_style": {
        "title_key": "house_norms_section_repair_style_title",
        "options": {
          "0": "Cuando aparece tension, intentamos hablarlo mas pronto que tarde.",
          "1": "Hacemos una comprobacion suave cuando el momento se siente adecuado.",
          "2": "Solemos dejar pasar lo pequeno salvo que empiece a acumularse."
        }
      },
      "norms_home_identity": {
        "title_key": "house_norms_section_home_identity_title",
        "options": {
          "0": "Buscamos un hogar tranquilo que ayude a recargar energia.",
          "1": "Valoramos un equilibrio entre momentos de calma y tiempo compartido.",
          "2": "Disfrutamos de un hogar activo donde las personas entran y salen con consideracion mutua."
        }
      }
    }
  }$$::jsonb
)
ON CONFLICT (template_key, locale_base) DO UPDATE
SET body = EXCLUDED.body,
    updated_at = now();

INSERT INTO public.house_norm_templates (template_key, locale_base, body)
VALUES (
  'house_norms_v1',
  'ar',
  $${
    "summary": {
      "title_key": "house_norms_title",
      "subtitle_key": "house_norms_subtitle",
      "framing_default": "نهدف إلى منزل يحافظ فيه الجميع على الهدوء ويفهم بعضهم بعضا وتبقى الحياة اليومية قابلة للتعايش."
    },
    "context": {
      "line_template": "هذا {{property_context}} يشاركه {{relationship_model}}، وهذه المعايير نقطة بداية لطيفة.",
      "property_context": {
        "0": "منزل مملوك",
        "1": "منزل مستاجر بالكامل",
        "2": "منزل بايجار غرفة مشتركة"
      },
      "relationship_model": {
        "0": "رفقاء السكن",
        "1": "عائلة",
        "2": "عائلة ورفقاء السكن"
      }
    },
    "sections": {
      "norms_rhythm_quiet": {
        "title_key": "house_norms_section_rhythm_quiet_title",
        "options": {
          "0": "عادة نخفف الايقاع في وقت متاخر ليحصل المنزل على الراحة.",
          "1": "نتكيف من ليلة لاخرى بين امسيات اكثر هدوءا واخرى اكثر نشاطا حسب الظرف.",
          "2": "نراعي اختلاف الجداول ونحافظ على الاعتبار عندما يكون الآخرون في وقت راحة."
        }
      },
      "norms_shared_spaces": {
        "title_key": "house_norms_section_shared_spaces_title",
        "options": {
          "0": "نحاول ابقاء المساحات المشتركة مرتبة وجاهزة للشخص التالي.",
          "1": "لا مانع لدينا من اثر الاستخدام في المساحات ونرتبها غالبا لاحقا.",
          "2": "نتقبل بعض الفوضى كجزء من الحياة المشتركة ونعيد الترتيب عندما يكون ذلك مناسبا."
        }
      },
      "norms_guests_social": {
        "title_key": "house_norms_section_guests_social_title",
        "options": {
          "0": "كلما امكن نخطط للضيوف ونتحدث عنهم مسبقا.",
          "1": "تنبيه سريع يكفي عادة قبل حضور اي شخص.",
          "2": "الضيوف جزء من الحياة اليومية هنا مع وعي اساسي بمن يشارك المنزل."
        }
      },
      "norms_responsibility_flow": {
        "title_key": "house_norms_section_responsibility_flow_title",
        "options": {
          "0": "نفضل اتفاقات واضحة حول من يتولى ماذا.",
          "1": "غالبا نتعامل مع الامور عندما يلاحظها احد ويمكنه القيام بها.",
          "2": "كل شخص يهتم اساسا بمساحته مع مراعاة الاحتياجات المشتركة."
        }
      },
      "norms_repair_style": {
        "title_key": "house_norms_section_repair_style_title",
        "options": {
          "0": "عند ظهور التوتر نحاول التحدث في وقت مبكر بدلا من التأخير.",
          "1": "نقوم بمراجعة لطيفة عندما يكون الوقت مناسبا.",
          "2": "غالبا نتجاوز الامور الصغيرة ما لم تبدأ بالتراكم."
        }
      },
      "norms_home_identity": {
        "title_key": "house_norms_section_home_identity_title",
        "options": {
          "0": "نسعى الى منزل هادئ يساعد الناس على استعادة طاقتهم.",
          "1": "نقدّر التوازن بين وقت الهدوء واللحظات المشتركة.",
          "2": "نستمتع بمنزل حيوي يدخل فيه الناس ويخرجون مع مراعاة متبادلة."
        }
      }
    }
  }$$::jsonb
)
ON CONFLICT (template_key, locale_base) DO UPDATE
SET body = EXCLUDED.body,
    updated_at = now();

-- ---------------------------------------------------------------------
-- Security posture: RPC-only
-- ---------------------------------------------------------------------
ALTER TABLE public.house_norms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.house_norms_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.house_norm_templates ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.house_norms, public.house_norms_revisions, public.house_norm_templates
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Triggers: updated_at
-- Assumes shared trigger function exists: public._touch_updated_at()
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_house_norms_touch_updated_at ON public.house_norms;
CREATE TRIGGER trg_house_norms_touch_updated_at
BEFORE UPDATE ON public.house_norms
FOR EACH ROW
EXECUTE FUNCTION public._touch_updated_at();

CREATE OR REPLACE FUNCTION public._house_norms_enforce_public_id_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.home_public_id IS NOT NULL
     AND NEW.home_public_id IS DISTINCT FROM OLD.home_public_id THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLIC_ID_IMMUTABLE',
      'home_public_id cannot be changed once assigned.',
      '22023',
      jsonb_build_object(
        'home_id', NEW.home_id,
        'home_public_id', OLD.home_public_id
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_house_norms_public_id_immutable ON public.house_norms;
CREATE TRIGGER trg_house_norms_public_id_immutable
BEFORE UPDATE ON public.house_norms
FOR EACH ROW
EXECUTE FUNCTION public._house_norms_enforce_public_id_immutable();

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._house_norms_assert_owner(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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

CREATE OR REPLACE FUNCTION public._house_norms_next_published_version(
  p_prev text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_next int;
BEGIN
  IF p_prev IS NULL OR btrim(p_prev) = '' THEN
    RETURN 'v000001';
  END IF;

  IF p_prev !~ '^v[0-9]{6}$' THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_INVALID_PUBLISHED_VERSION',
      'Invalid published version format.',
      '22023',
      jsonb_build_object('published_version', p_prev)
    );
  END IF;

  v_next := substring(p_prev from 2)::int + 1;
  RETURN 'v' || lpad(v_next::text, 6, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public._house_norms_build_public_url(
  p_home_public_id text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT 'https://go.makinglifeeasie.com/kinly/norms/' || p_home_public_id;
$$;

CREATE OR REPLACE FUNCTION public._house_norms_generate_public_id()
RETURNS public.citext
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  v_candidate text;
  v_try int := 0;
BEGIN
  LOOP
    v_try := v_try + 1;
    v_candidate := lower(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 12));

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.house_norms hn
      WHERE hn.home_public_id = v_candidate::public.citext
    );

    IF v_try >= 50 THEN
      PERFORM public.api_error(
        'HOUSE_NORMS_PUBLIC_ID_GENERATION_FAILED',
        'Failed to allocate a unique public id.',
        'P0001'
      );
    END IF;
  END LOOP;

  RETURN v_candidate::public.citext;
END;
$$;

-- ---------------------------------------------------------------------
-- Canonical ISO UTC formatter (matches JS Date(...).toISOString())
-- Example: 2026-02-17T01:03:12.345Z
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._to_iso_utc_ms(p_ts timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT to_char(p_ts AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;

REVOKE ALL ON FUNCTION public._to_iso_utc_ms(timestamptz) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Publish sync call (adjusted): send canonical published_at string
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._house_norms_publish_sync_call(
  p_home_public_id text,
  p_published_at timestamptz,
  p_published_version text,
  p_template_key text,
  p_locale_base text,
  p_published_content jsonb,
  p_public_url_path text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url text := nullif(current_setting('app.settings.supabase_url', true), '');
  v_secret text := nullif(current_setting('app.settings.worker_shared_secret', true), '');
  v_published_at_iso text := public._to_iso_utc_ms(p_published_at);

  v_req_id bigint;
  v_started timestamptz := clock_timestamp();
  v_deadline interval := interval '12 seconds';
  v_status_code int;
  v_content text;
  v_error_msg text;
  v_body jsonb;
BEGIN
  PERFORM public.api_assert(
    v_supabase_url IS NOT NULL,
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Missing app.settings.supabase_url.',
    'P0001'
  );

  -- Harden: ensure secret exists; otherwise edge will 401 and it’s confusing.
  PERFORM public.api_assert(
    v_secret IS NOT NULL,
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Missing app.settings.worker_shared_secret.',
    'P0001'
  );

  v_req_id := net.http_post(
    url := v_supabase_url || '/functions/v1/house_norms_publish_sync',
    headers := jsonb_strip_nulls(jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', v_secret
    )),
    body := jsonb_build_object(
      'home_public_id', p_home_public_id,
      -- IMPORTANT: canonical ISO string expected by edge strict toISOString check
      'published_at', v_published_at_iso,
      'published_version', p_published_version,
      'template_key', p_template_key,
      'locale_base', p_locale_base,
      'published_content', p_published_content,
      'public_url_path', p_public_url_path
    )
  );

  LOOP
    SELECT r.status_code, r.content, r.error_msg
      INTO v_status_code, v_content, v_error_msg
    FROM net._http_response r
    WHERE r.id = v_req_id
    ORDER BY r.created DESC
    LIMIT 1;

    EXIT WHEN v_status_code IS NOT NULL
           OR v_error_msg IS NOT NULL
           OR clock_timestamp() - v_started > v_deadline;

    PERFORM pg_sleep(0.10);
  END LOOP;

  IF v_error_msg IS NOT NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish sync request failed.',
      'P0001',
      jsonb_build_object('error', v_error_msg, 'request_id', v_req_id)
    );
  END IF;

  PERFORM public.api_assert(
    v_status_code IS NOT NULL,
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Publish sync request timed out.',
    'P0001',
    jsonb_build_object('request_id', v_req_id)
  );

  PERFORM public.api_assert(
    v_status_code BETWEEN 200 AND 299,
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Publish sync returned non-success status.',
    'P0001',
    jsonb_build_object('status_code', v_status_code, 'body', v_content)
  );

  BEGIN
    v_body := COALESCE(v_content, '{}')::jsonb;
  EXCEPTION WHEN others THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish sync returned invalid JSON.',
      'P0001',
      jsonb_build_object('body', v_content)
    );
  END;

  PERFORM public.api_assert(
    COALESCE((v_body ->> 'artifact_ok')::boolean, false),
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Publish artifact write failed.',
    'P0001',
    v_body
  );

  PERFORM public.api_assert(
    COALESCE((v_body ->> 'revalidate_ok')::boolean, false),
    'HOUSE_NORMS_PUBLISH_REVALIDATE_FAILED',
    'Publish revalidation failed.',
    'P0001',
    v_body
  );
END;
$$;

-- Pure helper: no SECURITY DEFINER needed
CREATE OR REPLACE FUNCTION public._house_norms_section_key_valid(
  p_section_key text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_section_key = ANY(
    ARRAY[
      'summary_framing',
      'norms_rhythm_quiet',
      'norms_shared_spaces',
      'norms_guests_social',
      'norms_responsibility_flow',
      'norms_repair_style',
      'norms_home_identity'
    ]
  );
$$;

-- English-only enforcement/threat language check.
-- Applied ONLY when locale_base='en'. For all other locales, skip regex.
CREATE OR REPLACE FUNCTION public._house_norms_text_safe_en(
  p_text text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT NOT (
    p_text ~* '(^|[^a-z])(must|always|never)([^a-z]|$)'
    OR p_text ~* '(punish|penalt|consequence|or else|if you don''t)'
    OR p_text ~* '(^|[^a-z])(allowed|forbidden|permission|required)([^a-z]|$)'
    OR p_text ~* '(track|monitor|watchlist)'
  );
$$;

-- Inputs validation: required keys only; strict enum 0..2 only; max object size guard.
-- (Adjusted) Remove unnecessary cast after regex check.
CREATE OR REPLACE FUNCTION public._house_norms_inputs_valid(
  p_inputs jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_required_keys constant text[] := ARRAY[
    'norms_property_context',
    'norms_relationship_model',
    'norms_rhythm_quiet',
    'norms_shared_spaces',
    'norms_guests_social',
    'norms_responsibility_flow',
    'norms_repair_style',
    'norms_home_identity'
  ];
  v_key text;
  v_val_text text;
  v_max_bytes constant int := 2048;
BEGIN
  IF p_inputs IS NULL OR jsonb_typeof(p_inputs) <> 'object' THEN
    RETURN false;
  END IF;

  IF octet_length(p_inputs::text) > v_max_bytes THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_required_keys) AS k
    WHERE NOT (p_inputs ? k)
  ) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(p_inputs) AS k
    WHERE NOT (k = ANY(v_required_keys))
  ) THEN
    RETURN false;
  END IF;

  FOREACH v_key IN ARRAY v_required_keys LOOP
    v_val_text := p_inputs ->> v_key;
    IF v_val_text IS NULL OR v_val_text !~ '^[0-2]$' THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

-- Generates content with UI chrome as *_key fields (Option B).
-- NOTE: STABLE (safer than IMMUTABLE)
CREATE OR REPLACE FUNCTION public._house_norms_generate_content(
  p_inputs jsonb,
  p_template_body jsonb,
  p_locale_base text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_section_keys constant text[] := ARRAY[
    'norms_rhythm_quiet',
    'norms_shared_spaces',
    'norms_guests_social',
    'norms_responsibility_flow',
    'norms_repair_style',
    'norms_home_identity'
  ];
  v_section_key text;
  v_section_option text;
  v_section_title_key text;
  v_section_text text;
  v_sections jsonb := '{}'::jsonb;

  v_prop_i text;
  v_rel_i text;
  v_property text;
  v_relation text;
  v_context_template text;
  v_context_line text;

  v_summary_title_key text;
  v_summary_subtitle_key text;
  v_summary_framing text;
BEGIN
  PERFORM public.api_assert(
    jsonb_typeof(p_template_body) = 'object',
    'HOUSE_NORMS_INVALID_TEMPLATE',
    'Template body must be a JSON object.',
    '22023'
  );

  v_summary_title_key := nullif(btrim(p_template_body #>> '{summary,title_key}'), '');
  v_summary_subtitle_key := nullif(btrim(p_template_body #>> '{summary,subtitle_key}'), '');
  v_summary_framing := nullif(btrim(p_template_body #>> '{summary,framing_default}'), '');

  PERFORM public.api_assert(
    v_summary_title_key IS NOT NULL
    AND v_summary_subtitle_key IS NOT NULL
    AND v_summary_framing IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE',
    'Template summary fields are required.',
    '22023'
  );

  v_prop_i := p_inputs ->> 'norms_property_context';
  v_rel_i := p_inputs ->> 'norms_relationship_model';

  v_property := nullif(
    btrim(p_template_body #>> ARRAY['context', 'property_context', v_prop_i]),
    ''
  );
  v_relation := nullif(
    btrim(p_template_body #>> ARRAY['context', 'relationship_model', v_rel_i]),
    ''
  );

  PERFORM public.api_assert(
    v_property IS NOT NULL
    AND v_relation IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE',
    'Template context options are missing.',
    '22023',
    jsonb_build_object(
      'norms_property_context', v_prop_i,
      'norms_relationship_model', v_rel_i
    )
  );

  v_context_template := nullif(btrim(p_template_body #>> '{context,line_template}'), '');
  PERFORM public.api_assert(
    v_context_template IS NOT NULL,
    'HOUSE_NORMS_INVALID_TEMPLATE',
    'Template context line_template is required.',
    '22023'
  );

  v_context_line := replace(
    replace(v_context_template, '{{property_context}}', v_property),
    '{{relationship_model}}',
    v_relation
  );

  FOREACH v_section_key IN ARRAY v_section_keys LOOP
    v_section_option := p_inputs ->> v_section_key;
    v_section_title_key := nullif(
      btrim(p_template_body #>> ARRAY['sections', v_section_key, 'title_key']),
      ''
    );
    v_section_text := nullif(
      btrim(p_template_body #>> ARRAY['sections', v_section_key, 'options', v_section_option]),
      ''
    );

    PERFORM public.api_assert(
      v_section_title_key IS NOT NULL
      AND v_section_text IS NOT NULL,
      'HOUSE_NORMS_INVALID_TEMPLATE',
      'Template section data is missing.',
      '22023',
      jsonb_build_object(
        'section_key', v_section_key,
        'option', v_section_option
      )
    );

    v_sections := v_sections || jsonb_build_object(
      v_section_key,
      jsonb_build_object(
        'title_key', v_section_title_key,
        'text', v_section_text
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'locale_base', p_locale_base,
    'summary', jsonb_build_object(
      'title_key', v_summary_title_key,
      'subtitle_key', v_summary_subtitle_key,
      'framing', v_summary_framing
    ),
    'context', jsonb_build_object(
      'line', v_context_line
    ),
    'sections', v_sections
  );
END;
$$;

-- ---------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------

-- Get returns BOTH draft and published.
-- UI can show draft in-app; web uses published only.
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

    v_owner_meta := jsonb_build_object(
      'home_public_id', v_row.home_public_id,
      'public_url',
        CASE
          WHEN v_row.home_public_id IS NULL THEN NULL
          ELSE public._house_norms_build_public_url(v_row.home_public_id::text)
        END,
      'show_publish_button', v_show_publish_button,
      'show_republish_button', v_show_republish_button,
      'show_public_url', v_show_public_url
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'house_norms', jsonb_build_object(
      'template_key', v_row.template_key,
      'status', v_row.status,
      'inputs', v_row.inputs,
      -- Draft
      'draft_content', v_row.generated_content,
      'draft_updated_at', v_row.generated_at,
      -- Published snapshot (web/share)
      'published_content', v_row.published_content,
      'published_at', v_row.published_at,
      'published_version', v_row.published_version,
      'is_published', (v_row.published_content IS NOT NULL),
      'has_unpublished_changes',
        (v_row.published_content IS NULL OR v_row.generated_content IS DISTINCT FROM v_row.published_content),
      'last_edited_at', v_row.last_edited_at,
      'last_edited_by', v_row.last_edited_by
    ) || v_owner_meta
  );
END;
$$;

-- Generate creates/updates ONLY the draft (generated_*).
-- Never touches published_*.
CREATE OR REPLACE FUNCTION public.house_norms_generate_for_home(
  p_home_id uuid,
  p_template_key text,
  p_locale text,
  p_inputs jsonb,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := now();
  v_requested_locale_base text;
  v_doc_locale_base text;
  v_template_body jsonb;
  v_generated jsonb;
  v_existing public.house_norms%ROWTYPE;
  v_user uuid := auth.uid();
  v_status text;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_norms_assert_owner(p_home_id);

  PERFORM public.api_assert(
    p_template_key = 'house_norms_v1',
    'HOUSE_NORMS_INVALID_TEMPLATE',
    'Unsupported house norms template.',
    '22023',
    jsonb_build_object('template_key', p_template_key)
  );

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

  PERFORM public.api_assert(
    public._house_norms_inputs_valid(p_inputs),
    'HOUSE_NORMS_INVALID_INPUTS',
    'House norms inputs are invalid.',
    '22023'
  );

  SELECT *
    INTO v_existing
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id;

  SELECT
    t.locale_base,
    t.body
  INTO
    v_doc_locale_base,
    v_template_body
  FROM public.house_norm_templates t
  WHERE t.template_key = p_template_key
    AND t.locale_base = v_requested_locale_base
  LIMIT 1;

  IF v_template_body IS NULL THEN
    SELECT
      t.locale_base,
      t.body
    INTO
      v_doc_locale_base,
      v_template_body
    FROM public.house_norm_templates t
    WHERE t.template_key = p_template_key
      AND t.locale_base = 'en'
    LIMIT 1;
  END IF;

  PERFORM public.api_assert(
    v_template_body IS NOT NULL,
    'HOUSE_NORMS_TEMPLATE_NOT_FOUND',
    'No house norms template found for requested locale or fallback en.',
    'P0001',
    jsonb_build_object(
      'template_key', p_template_key,
      'requested_locale_base', v_requested_locale_base
    )
  );

  IF v_existing.home_id IS NOT NULL
     AND COALESCE(p_force, false) = false
     AND v_existing.template_key = p_template_key
     AND v_existing.locale_base = v_doc_locale_base
     AND v_existing.inputs = p_inputs THEN
    RETURN jsonb_build_object(
      'ok', true,
      'home_id', p_home_id,
      'template_key', v_existing.template_key,
      'locale_base', v_existing.locale_base,
      'status', v_existing.status,
      'draft_content', v_existing.generated_content,
      'draft_updated_at', v_existing.generated_at,
      'published_content', v_existing.published_content,
      'published_at', v_existing.published_at,
      'has_unpublished_changes',
        (v_existing.published_content IS NULL OR v_existing.generated_content IS DISTINCT FROM v_existing.published_content),
      'short_circuited', true
    );
  END IF;

  v_generated := public._house_norms_generate_content(
    p_inputs,
    v_template_body,
    v_doc_locale_base
  );

  v_status := CASE
    WHEN v_existing.home_id IS NULL THEN 'out_of_date'
    WHEN v_existing.published_content IS NULL THEN 'out_of_date'
    WHEN v_generated IS DISTINCT FROM v_existing.published_content THEN 'out_of_date'
    ELSE 'published'
  END;

  INSERT INTO public.house_norms (
    home_id,
    template_key,
    locale_base,
    status,
    inputs,
    generated_content,
    generated_at,
    last_edited_at,
    last_edited_by
  )
  VALUES (
    p_home_id,
    p_template_key,
    v_doc_locale_base,
    v_status,
    p_inputs,
    v_generated,
    v_now,
    v_now,
    v_user
  )
  ON CONFLICT (home_id) DO UPDATE
  SET template_key      = EXCLUDED.template_key,
      locale_base       = EXCLUDED.locale_base,
      status            = EXCLUDED.status,
      inputs            = EXCLUDED.inputs,
      generated_content = EXCLUDED.generated_content,
      generated_at      = EXCLUDED.generated_at,
      last_edited_at    = EXCLUDED.last_edited_at,
      last_edited_by    = EXCLUDED.last_edited_by;

  SELECT *
    INTO v_existing
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'template_key', v_existing.template_key,
    'locale_base', v_existing.locale_base,
    'status', v_existing.status,
    'draft_content', v_existing.generated_content,
    'draft_updated_at', v_existing.generated_at,
    'published_content', v_existing.published_content,
    'published_at', v_existing.published_at,
    'has_unpublished_changes',
      (v_existing.published_content IS NULL OR v_existing.generated_content IS DISTINCT FROM v_existing.published_content),
    'short_circuited', false
  );
END;
$$;

-- Publish flow: locks row; copies draft -> published; marks published.
-- Option A preserved: update DB first, then call sync (rollback on exception).
CREATE OR REPLACE FUNCTION public.house_norms_publish_for_home(
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
  v_now timestamptz := now();
  v_requested_locale_base text;
  v_home_public_id public.citext;
  v_next_published_version text;
  v_public_url text;
  v_public_url_path text;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_norms_assert_owner(p_home_id);

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

  -- Concurrency: lock row to ensure publish copies a consistent draft snapshot
  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id
  FOR UPDATE;

  IF v_row.home_id IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_NOT_FOUND',
      'No house norms document found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  v_home_public_id := COALESCE(v_row.home_public_id, public._house_norms_generate_public_id());
  v_next_published_version := public._house_norms_next_published_version(v_row.published_version);
  v_public_url_path := '/kinly/norms/' || v_home_public_id::text;

  UPDATE public.house_norms
  SET published_content = v_row.generated_content,
      published_at = v_now,
      status = 'published',
      published_version = v_next_published_version,
      home_public_id = v_home_public_id
  WHERE home_id = p_home_id
  RETURNING *
  INTO v_row;

  v_public_url := public._house_norms_build_public_url(v_row.home_public_id::text);

  PERFORM public._house_norms_publish_sync_call(
    p_home_public_id => v_row.home_public_id::text,
    p_published_at => v_row.published_at,
    p_published_version => v_row.published_version,
    p_template_key => v_row.template_key,
    p_locale_base => v_row.locale_base,
    p_published_content => v_row.published_content,
    p_public_url_path => v_public_url_path
  );

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'status', v_row.status,
    'published_content', v_row.published_content,
    'published_at', v_row.published_at,
    'published_version', v_row.published_version,
    'home_public_id', v_row.home_public_id,
    'public_url', v_public_url,
    'has_unpublished_changes', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.house_norms_get_public_by_home_public_id(
  p_home_public_id text,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_requested_locale_base text;
  v_row record;
BEGIN
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

  SELECT
    hn.home_public_id::text AS home_public_id,
    hn.locale_base,
    hn.status,
    hn.published_content,
    hn.published_at,
    hn.published_version
  INTO v_row
  FROM public.house_norms hn
  JOIN public.homes h
    ON h.id = hn.home_id
  WHERE hn.home_public_id = p_home_public_id::public.citext
    AND h.is_active = TRUE
    AND hn.published_content IS NOT NULL
    AND hn.published_at IS NOT NULL
    AND hn.published_version IS NOT NULL
  LIMIT 1;

  IF v_row.home_public_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'available', false,
      'home_public_id', p_home_public_id,
      'requested_locale_base', v_requested_locale_base,
      'house_norms_public', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'available', true,
    'home_public_id', v_row.home_public_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'house_norms_public', jsonb_build_object(
      'status', v_row.status,
      'published_content', v_row.published_content,
      'published_at', v_row.published_at,
      'published_version', v_row.published_version
    )
  );
END;
$$;

-- Draft edit: updates generated_content only.
-- Never touches published_*; web link stays stable until publish.
CREATE OR REPLACE FUNCTION public.house_norms_edit_section_text(
  p_home_id uuid,
  p_locale text,
  p_section_key text,
  p_new_text text,
  p_change_summary text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row public.house_norms%ROWTYPE;
  v_content jsonb;
  v_now timestamptz := now();
  v_trimmed text := regexp_replace(btrim(COALESCE(p_new_text, '')), '\s+', ' ', 'g');
  v_summary text := NULLIF(regexp_replace(btrim(COALESCE(p_change_summary, '')), '\s+', ' ', 'g'), '');
  v_requested_locale_base text;
  v_general_max constant int := 2000;
  v_keep_revisions constant int := 100;
  v_status text;
  v_mentions_username boolean := false;
  v_mentions_member_name boolean := false;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_norms_assert_owner(p_home_id);

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

  PERFORM public.api_assert(
    public._house_norms_section_key_valid(p_section_key),
    'HOUSE_NORMS_INVALID_SECTION',
    'Unknown section key for house norms edit.',
    '22023',
    jsonb_build_object('section_key', p_section_key)
  );

  PERFORM public.api_assert(
    v_trimmed <> '',
    'HOUSE_NORMS_INVALID_INPUTS',
    'Edited text cannot be empty.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_trimmed) <= v_general_max,
    'HOUSE_NORMS_INVALID_INPUTS',
    format('Edited text must be %s characters or fewer.', v_general_max),
    '22023',
    jsonb_build_object('max_length', v_general_max)
  );

  IF p_section_key = 'summary_framing' THEN
    PERFORM public.api_assert(
      char_length(v_trimmed) <= 500,
      'HOUSE_NORMS_INVALID_INPUTS',
      'Summary framing must be 500 characters or fewer.',
      '22023',
      jsonb_build_object('max_length', 500)
    );
  END IF;

  IF v_summary IS NOT NULL THEN
    PERFORM public.api_assert(
      char_length(v_summary) <= 280,
      'HOUSE_NORMS_INVALID_INPUTS',
      'Change summary must be 280 characters or fewer.',
      '22023',
      jsonb_build_object('max_length', 280)
    );
  END IF;

  -- Concurrency: lock row to prevent lost updates
  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id
  FOR UPDATE;

  IF v_row.home_id IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_NOT_FOUND',
      'No house norms document found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  -- English-only strict checks. For all other locales, skip regex.
  IF v_row.locale_base = 'en' THEN
    v_mentions_username := (v_trimmed ~* '(^|\\s)@[a-z0-9._]{3,30}\\b');

    SELECT EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.profiles p
        ON p.id = m.user_id
      WHERE m.home_id = p_home_id
        AND m.is_current = TRUE
        AND p.deactivated_at IS NULL
        AND (
          position(lower(p.username::text) in lower(v_trimmed)) > 0
          OR (
            p.full_name IS NOT NULL
            AND btrim(p.full_name) <> ''
            AND position(lower(btrim(p.full_name)) in lower(v_trimmed)) > 0
          )
        )
    )
    INTO v_mentions_member_name;

    PERFORM public.api_assert(
      public._house_norms_text_safe_en(v_trimmed),
      'HOUSE_NORMS_UNSAFE_TEXT',
      'Edited text contains disallowed enforcement or threat language.',
      '22023'
    );

    PERFORM public.api_assert(
      NOT v_mentions_username
      AND NOT v_mentions_member_name,
      'HOUSE_NORMS_UNSAFE_TEXT',
      'Edited text must not name individuals.',
      '22023'
    );
  END IF;

  -- Edit DRAFT (generated_content)
  v_content := v_row.generated_content;

  IF p_section_key = 'summary_framing' THEN
    v_content := jsonb_set(v_content, '{summary,framing}', to_jsonb(v_trimmed), true);
  ELSE
    v_content := jsonb_set(v_content, ARRAY['sections', p_section_key, 'text'], to_jsonb(v_trimmed), true);
  END IF;

  v_status := CASE
    WHEN v_row.published_content IS NULL THEN 'out_of_date'
    WHEN v_content IS DISTINCT FROM v_row.published_content THEN 'out_of_date'
    ELSE 'published'
  END;

  UPDATE public.house_norms
  SET generated_content = v_content,
      generated_at = v_now,
      status = v_status,
      last_edited_at = v_now,
      last_edited_by = v_user
  WHERE home_id = p_home_id
  RETURNING *
  INTO v_row;

  -- Revision snapshot stores draft after edit
  INSERT INTO public.house_norms_revisions (
    home_id,
    editor_user_id,
    edited_at,
    content,
    change_summary
  )
  VALUES (
    p_home_id,
    v_user,
    v_now,
    v_content,
    v_summary
  );

  -- Revisions retention: keep last N per home (default 100)
  DELETE FROM public.house_norms_revisions r
  WHERE r.home_id = p_home_id
    AND r.id IN (
      SELECT id
      FROM public.house_norms_revisions
      WHERE home_id = p_home_id
      ORDER BY edited_at DESC, id DESC
      OFFSET v_keep_revisions
    );

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'section_key', p_section_key,
    'draft_content', v_content,
    'draft_updated_at', v_row.generated_at,
    'published_at', v_row.published_at,
    'status', v_row.status,
    'has_unpublished_changes',
      (v_row.published_content IS NULL OR v_content IS DISTINCT FROM v_row.published_content),
    'last_edited_at', v_row.last_edited_at,
    'last_edited_by', v_row.last_edited_by
  );
END;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._house_norms_assert_owner(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_enforce_public_id_immutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_section_key_valid(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_text_safe_en(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norm_templates_validate() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_inputs_valid(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_generate_content(jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_next_published_version(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_build_public_url(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_generate_public_id() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._to_iso_utc_ms(timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._house_norms_publish_sync_call(text, timestamptz, text, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.house_norms_get_for_home(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.house_norms_generate_for_home(uuid, text, text, jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.house_norms_publish_for_home(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.house_norms_edit_section_text(uuid, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.house_norms_get_public_by_home_public_id(text, text) TO anon, authenticated;
