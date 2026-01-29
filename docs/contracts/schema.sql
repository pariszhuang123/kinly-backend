


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






CREATE SCHEMA IF NOT EXISTS "pgtap";


ALTER SCHEMA "pgtap" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "citext" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgtap" WITH SCHEMA "pgtap";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."chore_event_type" AS ENUM (
    'create',
    'activate',
    'update',
    'complete',
    'cancel'
);


ALTER TYPE "public"."chore_event_type" OWNER TO "postgres";


CREATE TYPE "public"."chore_state" AS ENUM (
    'draft',
    'active',
    'completed',
    'cancelled'
);


ALTER TYPE "public"."chore_state" OWNER TO "postgres";


CREATE TYPE "public"."expense_plan_status" AS ENUM (
    'active',
    'terminated'
);


ALTER TYPE "public"."expense_plan_status" OWNER TO "postgres";


CREATE TYPE "public"."expense_share_status" AS ENUM (
    'unpaid',
    'paid'
);


ALTER TYPE "public"."expense_share_status" OWNER TO "postgres";


CREATE TYPE "public"."expense_split_type" AS ENUM (
    'equal',
    'custom'
);


ALTER TYPE "public"."expense_split_type" OWNER TO "postgres";


CREATE TYPE "public"."expense_status" AS ENUM (
    'draft',
    'active',
    'cancelled',
    'converted'
);


ALTER TYPE "public"."expense_status" OWNER TO "postgres";


CREATE TYPE "public"."home_usage_metric" AS ENUM (
    'active_chores',
    'chore_photos',
    'active_members',
    'active_expenses'
);


ALTER TYPE "public"."home_usage_metric" OWNER TO "postgres";


CREATE TYPE "public"."house_pulse_state" AS ENUM (
    'forming',
    'sunny_calm',
    'sunny_bumpy',
    'partly_supported',
    'cloudy_steady',
    'cloudy_tense',
    'rainy_supported',
    'rainy_unsupported',
    'thunderstorm'
);


ALTER TYPE "public"."house_pulse_state" OWNER TO "postgres";


COMMENT ON TYPE "public"."house_pulse_state" IS 'Canonical weekly house pulse states (contract v1).';



CREATE TYPE "public"."mood_scale" AS ENUM (
    'sunny',
    'partially_sunny',
    'cloudy',
    'rainy',
    'thunderstorm'
);


ALTER TYPE "public"."mood_scale" OWNER TO "postgres";


COMMENT ON TYPE "public"."mood_scale" IS 'Scale for household mood: sunny, partially_sunny, cloudy, rainy, thunderstorm.';



CREATE TYPE "public"."recurrence_interval" AS ENUM (
    'none',
    'daily',
    'weekly',
    'every_2_weeks',
    'monthly',
    'every_2_months',
    'annual'
);


ALTER TYPE "public"."recurrence_interval" OWNER TO "postgres";


CREATE TYPE "public"."revenuecat_processing_status" AS ENUM (
    'processing',
    'succeeded',
    'failed'
);


ALTER TYPE "public"."revenuecat_processing_status" OWNER TO "postgres";


CREATE TYPE "public"."subscription_status" AS ENUM (
    'active',
    'cancelled',
    'expired',
    'inactive'
);


ALTER TYPE "public"."subscription_status" OWNER TO "postgres";


CREATE TYPE "public"."subscription_store" AS ENUM (
    'app_store',
    'play_store',
    'stripe',
    'promotional'
);


ALTER TYPE "public"."subscription_store" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_active_profile"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.deactivated_at IS NULL
    ),
    'PROFILE_DEACTIVATED',
    'Your profile is deactivated. Reactivate it to continue.',
    '42501'
  );
END;
$$;


ALTER FUNCTION "public"."_assert_active_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_authenticated"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM public.api_error('UNAUTHORIZED', 'Authentication required', '28000');
  END IF;
END;
$$;


ALTER FUNCTION "public"."_assert_authenticated"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_home_active"("p_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_is_active boolean;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  SELECT h.is_active
  INTO v_is_active
  FROM public.homes h
  WHERE h.id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOME_NOT_FOUND',
      'Home does not exist.',
      'P0002',
      jsonb_build_object('homeId', p_home_id)
    );
  ELSIF v_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;
END;
$$;


ALTER FUNCTION "public"."_assert_home_active"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_home_member"("p_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  -- Require authentication
  PERFORM public._assert_authenticated();

  -- Check whether this user is an active/current member of the home
  PERFORM 1
  FROM public.memberships hm
  WHERE hm.home_id   = p_home_id
    AND hm.user_id   = v_user
    AND hm.is_current = TRUE       -- 👈 replace hm.left_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  RETURN;
END;
$$;


ALTER FUNCTION "public"."_assert_home_member"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_home_owner"("p_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM public._assert_authenticated();

  IF NOT public.is_home_owner(p_home_id, auth.uid()) THEN
    PERFORM public.api_error(
      'NOT_HOME_OWNER',
      'Only the home owner can perform this action.',
      '42501',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;
END;
$$;


ALTER FUNCTION "public"."_assert_home_owner"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_chore_recurrence_to_every_unit"("p_recurrence" "public"."recurrence_interval") RETURNS TABLE("recurrence_every" integer, "recurrence_unit" "text")
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
BEGIN
  CASE p_recurrence
    WHEN 'daily' THEN
      recurrence_every := 1;
      recurrence_unit := 'day';
    WHEN 'weekly' THEN
      recurrence_every := 1;
      recurrence_unit := 'week';
    WHEN 'every_2_weeks' THEN
      recurrence_every := 2;
      recurrence_unit := 'week';
    WHEN 'monthly' THEN
      recurrence_every := 1;
      recurrence_unit := 'month';
    WHEN 'every_2_months' THEN
      recurrence_every := 2;
      recurrence_unit := 'month';
    WHEN 'annual' THEN
      recurrence_every := 1;
      recurrence_unit := 'year';
    ELSE
      recurrence_every := NULL;
      recurrence_unit := NULL;
  END CASE;

  RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."_chore_recurrence_to_every_unit"("p_recurrence" "public"."recurrence_interval") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_chores_base_for_home"("p_home_id" "uuid") RETURNS TABLE("id" "uuid", "home_id" "uuid", "assignee_user_id" "uuid", "created_by_user_id" "uuid", "name" "text", "state" "public"."chore_state", "current_due_on" "date", "created_at" timestamp with time zone, "assignee_full_name" "text", "assignee_avatar_storage_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.assignee_user_id,
    c.created_by_user_id,
    c.name,
    c.state,
    CASE
      WHEN c.completed_at IS NULL THEN c.start_date
      ELSE c.recurrence_cursor
    END AS current_due_on,
    c.created_at,
    pa.full_name AS assignee_full_name,
    a.storage_path AS assignee_avatar_storage_path
  FROM public.chores c
  LEFT JOIN public.profiles pa ON pa.id = c.assignee_user_id
  LEFT JOIN public.avatars a ON a.id = pa.avatar_id
  WHERE c.home_id = p_home_id;
END;
$$;


ALTER FUNCTION "public"."_chores_base_for_home"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_current_user_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  SELECT auth.uid();
$$;


ALTER FUNCTION "public"."_current_user_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_ensure_unique_avatar_for_home"("p_home_id" "uuid", "p_user_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_avatar_before uuid;
  v_new_avatar uuid;
  v_plan text;
BEGIN
  PERFORM public._assert_authenticated();

  -- Lock profile row for this user
  SELECT p.avatar_id
    INTO v_avatar_before
  FROM public.profiles p
  WHERE p.id = p_user_id
    AND p.deactivated_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'PROFILE_NOT_FOUND',
      'Active profile not found for current user.',
      '22000',
      jsonb_build_object('user_id', p_user_id)
    );
  END IF;

  -- Default plan to free if none found
  v_plan := public._home_effective_plan(p_home_id);
  IF v_plan IS NULL THEN
    v_plan := 'free';
  END IF;

  -- If current avatar is unique in this home, keep it
  IF v_avatar_before IS NOT NULL THEN
    PERFORM 1
    FROM public.memberships m
    JOIN public.profiles pr
      ON pr.id = m.user_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE
      AND pr.deactivated_at IS NULL
      AND pr.avatar_id = v_avatar_before
      AND pr.id <> p_user_id;

    IF NOT FOUND THEN
      RETURN v_avatar_before;
    END IF;
  END IF;

  -- Pick the first available avatar respecting plan and excluding other members
  WITH used_by_others AS (
    SELECT DISTINCT pr.avatar_id
    FROM public.memberships m
    JOIN public.profiles pr
      ON pr.id = m.user_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE
      AND pr.deactivated_at IS NULL
      AND pr.id <> p_user_id
  )
  SELECT a.id
    INTO v_new_avatar
  FROM public.avatars a
  LEFT JOIN used_by_others u
    ON u.avatar_id = a.id
  WHERE u.avatar_id IS NULL
    AND (v_plan <> 'free' OR a.category = 'animal')
  ORDER BY a.created_at ASC
  LIMIT 1;

  IF v_new_avatar IS NULL THEN
    PERFORM public.api_error(
      'NO_AVAILABLE_AVATAR',
      'No available avatars for this home.',
      'P0001',
      jsonb_build_object('home_id', p_home_id, 'plan', v_plan)
    );
  END IF;

  UPDATE public.profiles
     SET avatar_id = v_new_avatar,
         updated_at = now()
   WHERE id = p_user_id
     AND deactivated_at IS NULL;

  RETURN v_new_avatar;
END;
$$;


ALTER FUNCTION "public"."_ensure_unique_avatar_for_home"("p_home_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."expenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "created_by_user_id" "uuid" NOT NULL,
    "status" "public"."expense_status" DEFAULT 'draft'::"public"."expense_status" NOT NULL,
    "split_type" "public"."expense_split_type",
    "amount_cents" bigint,
    "description" "text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fully_paid_at" timestamp with time zone,
    "plan_id" "uuid",
    "recurrence_interval" "public"."recurrence_interval",
    "start_date" "date" NOT NULL,
    "recurrence_every" integer,
    "recurrence_unit" "text",
    CONSTRAINT "chk_expenses_active_amount_required" CHECK ((("status" <> 'active'::"public"."expense_status") OR (("amount_cents" IS NOT NULL) AND ("amount_cents" > 0)))),
    CONSTRAINT "chk_expenses_active_split_required" CHECK ((("status" <> 'active'::"public"."expense_status") OR ("split_type" IS NOT NULL))),
    CONSTRAINT "chk_expenses_amount_positive" CHECK ((("amount_cents" IS NULL) OR ("amount_cents" > 0))),
    CONSTRAINT "chk_expenses_description_length" CHECK (("char_length"("btrim"("description")) <= 280)),
    CONSTRAINT "chk_expenses_notes_length" CHECK ((("notes" IS NULL) OR ("char_length"("notes") <= 2000))),
    CONSTRAINT "chk_expenses_plan_alignment" CHECK (((("recurrence_every" IS NULL) AND ("recurrence_unit" IS NULL) AND ("plan_id" IS NULL)) OR (("recurrence_every" IS NOT NULL) AND ("recurrence_unit" IS NOT NULL) AND ("plan_id" IS NOT NULL)))),
    CONSTRAINT "chk_expenses_recurrence_every_min" CHECK ((("recurrence_every" IS NULL) OR ("recurrence_every" >= 1))),
    CONSTRAINT "chk_expenses_recurrence_pair" CHECK (((("recurrence_every" IS NULL) AND ("recurrence_unit" IS NULL)) OR (("recurrence_every" IS NOT NULL) AND ("recurrence_unit" IS NOT NULL)))),
    CONSTRAINT "chk_expenses_recurrence_unit_allowed" CHECK ((("recurrence_unit" IS NULL) OR ("recurrence_unit" = ANY (ARRAY['day'::"text", 'week'::"text", 'month'::"text", 'year'::"text"]))))
);


ALTER TABLE "public"."expenses" OWNER TO "postgres";


COMMENT ON TABLE "public"."expenses" IS 'Top-level shared expense created inside a home.';



COMMENT ON COLUMN "public"."expenses"."home_id" IS 'FK to public.homes.id.';



COMMENT ON COLUMN "public"."expenses"."created_by_user_id" IS 'Expense creator / payer.';



COMMENT ON COLUMN "public"."expenses"."status" IS 'draft|active|cancelled.';



COMMENT ON COLUMN "public"."expenses"."split_type" IS 'equal|custom|null (no split).';



COMMENT ON COLUMN "public"."expenses"."amount_cents" IS 'Total amount in integer cents; null allowed for draft expenses.';



COMMENT ON COLUMN "public"."expenses"."description" IS 'Required description (<=280 chars).';



COMMENT ON COLUMN "public"."expenses"."notes" IS 'Optional notes for creator + viewers.';



COMMENT ON COLUMN "public"."expenses"."fully_paid_at" IS 'Canonical fully-paid timestamp; set once. Used as idempotency guard for usage decrements.';



COMMENT ON COLUMN "public"."expenses"."plan_id" IS 'Nullable for one-off expenses; set for cycle expenses generated from a plan.';



COMMENT ON COLUMN "public"."expenses"."recurrence_interval" IS 'none for one-off; copied from plan for recurring cycles.';



COMMENT ON COLUMN "public"."expenses"."start_date" IS 'Cycle start date (or one-off effective date).';



COMMENT ON COLUMN "public"."expenses"."recurrence_every" IS 'Recurring interval count; NULL for one-off expenses.';



COMMENT ON COLUMN "public"."expenses"."recurrence_unit" IS 'Recurring interval unit (day|week|month|year); NULL for one-off expenses.';



CREATE OR REPLACE FUNCTION "public"."_expense_plan_generate_cycle"("p_plan_id" "uuid", "p_cycle_date" "date") RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_plan_unsafe  public.expense_plans%ROWTYPE;
  v_plan         public.expense_plans%ROWTYPE;
  v_home_active  boolean;
  v_expense      public.expenses%ROWTYPE;
BEGIN
  IF p_plan_id IS NULL OR p_cycle_date IS NULL THEN
    PERFORM public.api_error('INVALID_PLAN', 'Plan id and cycle date are required.', '22023');
  END IF;

  -- Read w/o lock for faster "not found", but do not trust it
  SELECT *
    INTO v_plan_unsafe
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense plan not found.',
      'P0002',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  -- Lock home FIRST (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = v_plan_unsafe.home_id
   FOR UPDATE;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- Lock plan row
  SELECT *
    INTO v_plan
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id
   FOR UPDATE;

  IF v_plan.home_id <> v_plan_unsafe.home_id THEN
    PERFORM public.api_error(
      'CONCURRENT_MODIFICATION',
      'Plan changed while generating cycle; retry.',
      '40001',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  IF v_plan.status <> 'active' THEN
    PERFORM public.api_error(
      'PLAN_NOT_ACTIVE',
      'Cannot generate cycles for a terminated plan.',
      'P0004',
      jsonb_build_object('planId', p_plan_id, 'status', v_plan.status)
    );
  END IF;

  -- Idempotent insert (unique on (plan_id, start_date))
  BEGIN
    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      plan_id,
      recurrence_interval,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_plan.home_id,
      v_plan.created_by_user_id,
      'active',
      v_plan.split_type,
      v_plan.amount_cents,
      v_plan.description,
      v_plan.notes,
      v_plan.id,
      v_plan.recurrence_interval,
      v_plan.recurrence_every,
      v_plan.recurrence_unit,
      p_cycle_date
    )
    RETURNING * INTO v_expense;

  EXCEPTION WHEN unique_violation THEN
    SELECT *
      INTO v_expense
      FROM public.expenses e
     WHERE e.plan_id = v_plan.id
       AND e.start_date = p_cycle_date
     LIMIT 1;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'STATE_CHANGED_RETRY',
        'Cycle already exists but could not be read; retry.',
        '40001',
        jsonb_build_object('planId', v_plan.id, 'cycleDate', p_cycle_date)
      );
    END IF;

    RETURN v_expense;
  END;

  -- Create splits for this cycle.
  -- If payer included as participant, mark their share paid immediately.
  INSERT INTO public.expense_splits (
    expense_id,
    debtor_user_id,
    amount_cents,
    status,
    marked_paid_at
  )
  SELECT
    v_expense.id,
    d.debtor_user_id,
    d.share_amount_cents,
    CASE
      WHEN d.debtor_user_id = v_plan.created_by_user_id
        THEN 'paid'::public.expense_share_status
      ELSE 'unpaid'::public.expense_share_status
    END,
    CASE
      WHEN d.debtor_user_id = v_plan.created_by_user_id
        THEN now()
      ELSE NULL
    END
  FROM public.expense_plan_debtors d
  WHERE d.plan_id = v_plan.id;

  -- Usage increments happen here for recurring cycles (including first cycle)
  PERFORM public._home_usage_apply_delta(
    v_plan.home_id,
    jsonb_build_object('active_expenses', 1)
  );

  RETURN v_expense;
END;
$$;


ALTER FUNCTION "public"."_expense_plan_generate_cycle"("p_plan_id" "uuid", "p_cycle_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_expense_plan_next_cycle_date"("p_interval" "public"."recurrence_interval", "p_from" "date") RETURNS "date"
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
BEGIN
  CASE p_interval
    WHEN 'weekly' THEN
      RETURN (p_from + 7)::date;
    WHEN 'every_2_weeks' THEN
      RETURN (p_from + 14)::date;
    WHEN 'monthly' THEN
      RETURN (p_from + INTERVAL '1 month')::date;
    WHEN 'every_2_months' THEN
      RETURN (p_from + INTERVAL '2 months')::date;
    WHEN 'annual' THEN
      RETURN (p_from + INTERVAL '1 year')::date;
    ELSE
      RAISE EXCEPTION
        'Recurrence interval % not supported for expense plans.',
        p_interval
        USING ERRCODE = '22023';
  END CASE;
END;
$$;


ALTER FUNCTION "public"."_expense_plan_next_cycle_date"("p_interval" "public"."recurrence_interval", "p_from" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_expense_plan_next_cycle_date_v2"("p_every" integer, "p_unit" "text", "p_from" "date") RETURNS "date"
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
BEGIN
  IF p_every IS NULL OR p_unit IS NULL THEN
    RAISE EXCEPTION
      'Recurrence every/unit is required for expense plans.'
      USING ERRCODE = '22023';
  END IF;

  IF p_every < 1 THEN
    RAISE EXCEPTION
      'Recurrence every must be >= 1.'
      USING ERRCODE = '22023';
  END IF;

  CASE p_unit
    WHEN 'day' THEN
      RETURN (p_from + p_every)::date;
    WHEN 'week' THEN
      RETURN (p_from + (p_every * 7))::date;
    WHEN 'month' THEN
      RETURN (p_from + make_interval(months => p_every))::date;
    WHEN 'year' THEN
      RETURN (p_from + make_interval(years => p_every))::date;
    ELSE
      RAISE EXCEPTION
        'Recurrence unit % not supported for expense plans.',
        p_unit
        USING ERRCODE = '22023';
  END CASE;
END;
$$;


ALTER FUNCTION "public"."_expense_plan_next_cycle_date_v2"("p_every" integer, "p_unit" "text", "p_from" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_expense_plans_terminate_for_member_change"("p_home_id" "uuid", "p_affected_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.expense_plans ep
     SET status = 'terminated',
         terminated_at = now(),
         updated_at = now()
   WHERE ep.home_id = p_home_id
     AND ep.status = 'active'
     AND (
       ep.created_by_user_id = p_affected_user_id
       OR EXISTS (
         SELECT 1
           FROM public.expense_plan_debtors d
          WHERE d.plan_id = ep.id
            AND d.debtor_user_id = p_affected_user_id
       )
     );
END;
$$;


ALTER FUNCTION "public"."_expense_plans_terminate_for_member_change"("p_home_id" "uuid", "p_affected_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_expenses_prepare_split_buffer"("p_home_id" "uuid", "p_creator_id" "uuid", "p_amount_cents" bigint, "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_split_count         integer := 0;
  v_split_sum           bigint  := 0;
  v_distinct_count      integer := 0;
  v_non_creator_members integer := 0;
  v_member_match_count  integer := 0;

  v_total_count         integer := 0;
  v_equal_share         bigint  := 0;
  v_remainder           bigint  := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_creator_id IS NULL THEN
    PERFORM public.api_error('INVALID_CREATOR', 'Creator id is required.', '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLIT', 'Split mode is required to build splits.', '22023');
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      'Amount must be a positive integer.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents)
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expense_split_buffer (
    debtor_user_id uuid NOT NULL,
    amount_cents   bigint NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE TABLE pg_temp.expense_split_buffer;

  IF p_split_mode = 'equal' THEN
    IF p_member_ids IS NULL OR array_length(p_member_ids, 1) IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Provide at least two members for an equal split.',
        '22023'
      );
    END IF;

    WITH ordered AS (
      SELECT
        member_id,
        ROW_NUMBER() OVER (ORDER BY ord_position) AS rn,
        COUNT(*) OVER () AS total_count
      FROM (
        SELECT DISTINCT ON (raw.member_id)
               raw.member_id,
               raw.ord_position
        FROM unnest(p_member_ids)
          WITH ORDINALITY AS raw(member_id, ord_position)
        WHERE raw.member_id IS NOT NULL
        ORDER BY raw.member_id, raw.ord_position
      ) deduped
    )
    SELECT COALESCE(MAX(total_count), 0)
      INTO v_total_count
      FROM ordered;

    IF v_total_count < 2 THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Include at least two members in the split.',
        '22023'
      );
    END IF;

    v_equal_share := p_amount_cents / v_total_count;
    v_remainder   := p_amount_cents % v_total_count;

    WITH ordered AS (
      SELECT
        member_id,
        ROW_NUMBER() OVER (ORDER BY ord_position) AS rn
      FROM (
        SELECT DISTINCT ON (raw.member_id)
               raw.member_id,
               raw.ord_position
        FROM unnest(p_member_ids)
          WITH ORDINALITY AS raw(member_id, ord_position)
        WHERE raw.member_id IS NOT NULL
        ORDER BY raw.member_id, raw.ord_position
      ) deduped
    )
    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT
      member_id,
      v_equal_share + CASE WHEN rn = v_total_count THEN v_remainder ELSE 0 END
    FROM ordered
    ORDER BY rn;

  ELSIF p_split_mode = 'custom' THEN
    IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
      PERFORM public.api_error('INVALID_SPLIT', 'p_splits must be a JSON array.', '22023');
    END IF;

    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT x.user_id, x.amount_cents
    FROM jsonb_to_recordset(p_splits) AS x(user_id uuid, amount_cents bigint);

  ELSE
    PERFORM public.api_error('INVALID_SPLIT', 'Unknown split type.', '22023');
  END IF;

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COUNT(DISTINCT debtor_user_id)::int
    INTO v_split_count, v_split_sum, v_distinct_count
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 2 THEN
    PERFORM public.api_error('SPLIT_MEMBERS_REQUIRED', 'Include at least two members in the split.', '22023');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.expense_split_buffer
    WHERE debtor_user_id IS NULL
       OR amount_cents   IS NULL
       OR amount_cents  <= 0
  ) THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'Each split requires a member and a positive amount.', '22023');
  END IF;

  IF v_distinct_count <> v_split_count THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'Each debtor must appear only once.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error(
      'SPLIT_SUM_MISMATCH',
      'Split amounts must add up to the total amount.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  SELECT COUNT(*)::int
    INTO v_non_creator_members
    FROM pg_temp.expense_split_buffer
   WHERE debtor_user_id <> p_creator_id;

  IF v_non_creator_members = 0 THEN
    PERFORM public.api_error('SPLIT_MEMBERS_REQUIRED', 'Include at least one other member in the split.', '22023');
  END IF;

  SELECT COUNT(*)::int
    INTO v_member_match_count
    FROM pg_temp.expense_split_buffer s
    JOIN public.memberships m
      ON m.home_id    = p_home_id
     AND m.user_id    = s.debtor_user_id
     AND m.is_current = TRUE
     AND m.valid_to IS NULL;

  IF v_member_match_count <> v_split_count THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'All debtors must be current members of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;
END;
$$;


ALTER FUNCTION "public"."_expenses_prepare_split_buffer"("p_home_id" "uuid", "p_creator_id" "uuid", "p_amount_cents" bigint, "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_gen_invite_code"() RETURNS "public"."citext"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  out_code text := '';
  i int; idx int;
BEGIN
  FOR i IN 1..6 LOOP
    idx := 1 + floor(random() * length(alphabet))::int;
    out_code := out_code || substr(alphabet, idx, 1);
  END LOOP;
  RETURN out_code::public.citext; -- schema-qualify the type too
END;
$$;


ALTER FUNCTION "public"."_gen_invite_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_gen_unique_username"("p_email" "text", "p_id" "uuid") RETURNS "public"."citext"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $_$
DECLARE
  base       public.citext;
  candidate  public.citext;
  n          int := 0;
  max_tries  int := 100000;
  prefix_len int;
BEGIN
  -- derive from email local-part (DOT-LESS); fallback to id
  base := lower(
            coalesce(
              nullif(replace(split_part(p_email, '@', 1), '.', ''), ''),
              'user_' || substr(p_id::text, 1, 8)
            )
          );

  -- keep only [a-z0-9._], trim edges
  base := regexp_replace(base, '[^a-z0-9._]', '', 'g');
  base := regexp_replace(base, '^[._]+|[._]+$', '', 'g');

  -- (optional) collapse repeated separators: '..' or '__' -> '_'
  base := regexp_replace(base, '[._]{2,}', '_', 'g');

  -- ensure min length 3 (fallback to uuid prefix)
  IF length(base) < 3 THEN
    base := 'user' || substr(p_id::text, 1, 8);
  END IF;

  -- cap to 30 (we’ll shorten further if we add suffix)
  base := left(base, 30);

  -- serialize attempts per-base (reduces races)
  PERFORM pg_try_advisory_xact_lock(hashtextextended(base::text, 0));

  -- try base, then base_1, base_2, ... (keep total <= 30)
  LOOP
    IF n = 0 THEN
      candidate := base;
    ELSE
      -- room for '_' + n
      prefix_len := greatest(1, 30 - 1 - length(n::text));
      candidate  := left(base, prefix_len) || '_' || n::text;
    END IF;

    -- must match the CHECK regex: start/end alnum
    IF candidate ~ '^[a-z0-9](?:[a-z0-9._]{1,28})[a-z0-9]$' THEN
      -- skip if reserved
      IF NOT EXISTS (
           SELECT 1 FROM public.reserved_usernames r
           WHERE r.name = candidate
         )
      THEN
        -- unique test (case-insensitive due to citext + unique index)
        PERFORM 1 FROM public.profiles WHERE username = candidate;
        IF NOT FOUND THEN
          RETURN candidate;
        END IF;
      END IF;
    END IF;

    n := n + 1;
    IF n > max_tries THEN
      RAISE EXCEPTION 'Could not generate unique username after % attempts (base=%)', max_tries, base;
    END IF;
  END LOOP;
END
$_$;


ALTER FUNCTION "public"."_gen_unique_username"("p_email" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_home_assert_quota"("p_home_id" "uuid", "p_deltas" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_plan          text;
  v_is_premium    boolean;

  v_home_active   boolean;
  v_counters      public.home_usage_counters%ROWTYPE;

  v_metric_key    text;
  v_metric_enum   public.home_usage_metric;
  v_raw_value     jsonb;
  v_delta         integer;
  v_current       integer;
  v_new           integer;
  v_max           integer;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  -- Lock home FIRST (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Home not found.',
      'P0002',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  v_is_premium := public._home_is_premium(p_home_id);
  IF v_is_premium THEN
    RETURN;
  END IF;

  IF p_deltas IS NULL OR jsonb_typeof(p_deltas) <> 'object' THEN
    RETURN;
  END IF;

  v_plan := public._home_effective_plan(p_home_id);

  INSERT INTO public.home_usage_counters (home_id)
  VALUES (p_home_id)
  ON CONFLICT (home_id) DO NOTHING;

  SELECT *
    INTO v_counters
    FROM public.home_usage_counters
   WHERE home_id = p_home_id
   FOR UPDATE;

  FOR v_metric_key, v_raw_value IN
    SELECT key, value FROM jsonb_each(p_deltas)
  LOOP
    BEGIN
      v_metric_enum := v_metric_key::public.home_usage_metric;
    EXCEPTION WHEN invalid_text_representation THEN
      CONTINUE;
    END;

    IF jsonb_typeof(v_raw_value) <> 'number' THEN
      PERFORM public.api_error(
        'INVALID_QUOTA_DELTA',
        'Quota delta must be numeric.',
        '22023',
        jsonb_build_object('metric', v_metric_key, 'value', v_raw_value)
      );
    END IF;

    v_delta := (v_raw_value #>> '{}')::integer;
    IF COALESCE(v_delta, 0) <= 0 THEN
      CONTINUE;
    END IF;

    SELECT max_value
      INTO v_max
      FROM public.home_plan_limits
     WHERE plan = v_plan
       AND metric = v_metric_enum;

    IF v_max IS NULL THEN
      CONTINUE;
    END IF;

    v_current := CASE v_metric_enum
      WHEN 'active_chores'    THEN COALESCE(v_counters.active_chores, 0)
      WHEN 'chore_photos'     THEN COALESCE(v_counters.chore_photos, 0)
      WHEN 'active_members'   THEN COALESCE(v_counters.active_members, 0)
      WHEN 'active_expenses'  THEN COALESCE(v_counters.active_expenses, 0)
    END;

    v_new := GREATEST(0, v_current + v_delta);

    IF v_new > v_max THEN
      PERFORM public.api_error(
        'PAYWALL_LIMIT_' || upper(v_metric_key),
        format('Free plan allows up to %s %s per home.', v_max, v_metric_key),
        'P0001',
        jsonb_build_object(
          'limit_type', v_metric_key,
          'plan',       v_plan,
          'max',        v_max,
          'current',    v_current,
          'projected',  v_new
        )
      );
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."_home_assert_quota"("p_home_id" "uuid", "p_deltas" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."_home_assert_quota"("p_home_id" "uuid", "p_deltas" "jsonb") IS 'Generic quota enforcement: checks deltas against per-plan limits in home_plan_limits and raises api_error when exceeding quotas.';



CREATE OR REPLACE FUNCTION "public"."_home_attach_subscription_to_home"("_user_id" "uuid", "_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  -- Attach the user's live subscription (if any) that is currently unattached
  UPDATE public.user_subscriptions
  SET home_id    = _home_id,
      updated_at = now()
  WHERE user_id = _user_id
    AND home_id IS NULL
    AND status IN ('active', 'cancelled');

  -- We rely on the trigger to call home_entitlements_refresh(_home_id)
END;
$$;


ALTER FUNCTION "public"."_home_attach_subscription_to_home"("_user_id" "uuid", "_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_home_detach_subscription_to_home"("_home_id" "uuid", "_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.user_subscriptions
  SET home_id    = NULL,
      updated_at = now()
  WHERE user_id = _user_id
    AND home_id = _home_id
    AND status IN ('active', 'cancelled');

  -- trigger on user_subscriptions will call home_entitlements_refresh(v_home_id)
END;
$$;


ALTER FUNCTION "public"."_home_detach_subscription_to_home"("_home_id" "uuid", "_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_home_effective_plan"("p_home_id" "uuid") RETURNS "text"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE(
    (
      SELECT he.plan
      FROM public.home_entitlements he
      WHERE he.home_id = p_home_id
        AND (he.expires_at IS NULL OR he.expires_at > now())
      ORDER BY he.expires_at NULLS LAST, he.created_at DESC
      LIMIT 1
    ),
    'free'
  );
$$;


ALTER FUNCTION "public"."_home_effective_plan"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_home_is_premium"("p_home_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT COALESCE(
    (
      SELECT plan = 'premium'
             AND (expires_at IS NULL OR expires_at > now())
      FROM public.home_entitlements
      WHERE home_id = p_home_id
    ),
    FALSE
  );
$$;


ALTER FUNCTION "public"."_home_is_premium"("p_home_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."home_usage_counters" (
    "home_id" "uuid" NOT NULL,
    "active_chores" integer DEFAULT 0 NOT NULL,
    "chore_photos" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "active_members" integer DEFAULT 0 NOT NULL,
    "active_expenses" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "home_usage_counters_active_chores_check" CHECK (("active_chores" >= 0)),
    CONSTRAINT "home_usage_counters_active_expenses_check" CHECK (("active_expenses" >= 0)),
    CONSTRAINT "home_usage_counters_active_members_check" CHECK (("active_members" >= 0)),
    CONSTRAINT "home_usage_counters_chore_photos_check" CHECK (("chore_photos" >= 0))
);


ALTER TABLE "public"."home_usage_counters" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_usage_counters" IS 'Cached usage counters (active chores, expectation photos) for paywall checks.';



COMMENT ON COLUMN "public"."home_usage_counters"."active_chores" IS 'Non-cancelled chores that still count versus the free quota (e.g. completed recurring + scheduled/assigned, one-off completed removed).';



COMMENT ON COLUMN "public"."home_usage_counters"."chore_photos" IS 'Number of chores with expectation photos.';



COMMENT ON COLUMN "public"."home_usage_counters"."active_members" IS 'Number of current/active members in the home (owner + members).';



COMMENT ON COLUMN "public"."home_usage_counters"."active_expenses" IS 'Number of draft/active expenses that still count toward the plan quota (freed when cancelled or fully paid).';



CREATE OR REPLACE FUNCTION "public"."_home_usage_apply_delta"("p_home_id" "uuid", "p_deltas" "jsonb") RETURNS "public"."home_usage_counters"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_row                    public.home_usage_counters;
  v_home_active            boolean;

  v_active_chores_delta    integer := 0;
  v_chore_photos_delta     integer := 0;
  v_active_members_delta   integer := 0;
  v_active_expenses_delta  integer := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  -- Lock home FIRST to match global lock order (homes -> ...)
  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Home not found.',
      'P0002',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  INSERT INTO public.home_usage_counters (home_id)
  VALUES (p_home_id)
  ON CONFLICT (home_id) DO NOTHING;

  IF p_deltas IS NOT NULL AND jsonb_typeof(p_deltas) = 'object' THEN
    IF jsonb_typeof(p_deltas->'active_chores') = 'number' THEN
      v_active_chores_delta := (p_deltas->>'active_chores')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'chore_photos') = 'number' THEN
      v_chore_photos_delta := (p_deltas->>'chore_photos')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'active_members') = 'number' THEN
      v_active_members_delta := (p_deltas->>'active_members')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'active_expenses') = 'number' THEN
      v_active_expenses_delta := (p_deltas->>'active_expenses')::integer;
    END IF;
  END IF;

  UPDATE public.home_usage_counters h
     SET active_chores   = GREATEST(0, COALESCE(h.active_chores, 0) + v_active_chores_delta),
         chore_photos    = GREATEST(0, COALESCE(h.chore_photos, 0) + v_chore_photos_delta),
         active_members  = GREATEST(0, COALESCE(h.active_members, 0) + v_active_members_delta),
         active_expenses = GREATEST(0, COALESCE(h.active_expenses, 0) + v_active_expenses_delta),
         updated_at      = now()
   WHERE h.home_id = p_home_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."_home_usage_apply_delta"("p_home_id" "uuid", "p_deltas" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_house_vibe_confidence_kind"("p_label_id" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  SELECT CASE
    WHEN p_label_id IN ('insufficient_data', 'default_home') THEN 'coverage'
    ELSE 'label'
  END;
$$;


ALTER FUNCTION "public"."_house_vibe_confidence_kind"("p_label_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_house_vibes_mark_out_of_date"("p_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_total int;
  v_mapping_version text := 'v1';
BEGIN
  SELECT COUNT(*)
    INTO v_total
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current = true;

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
    v_mapping_version,
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
        mapping_version   = EXCLUDED.mapping_version,
        label_id          = EXCLUDED.label_id,
        confidence        = EXCLUDED.confidence,
        coverage_answered = EXCLUDED.coverage_answered,
        coverage_total    = EXCLUDED.coverage_total,
        axes              = EXCLUDED.axes,
        computed_at       = EXCLUDED.computed_at,
        invalidated_at    = EXCLUDED.invalidated_at;
END;
$$;


ALTER FUNCTION "public"."_house_vibes_mark_out_of_date"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_house_vibes_mark_out_of_date_memberships"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_old_home uuid := null;
  v_new_home uuid := null;
  v_should_invalidate boolean := false;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new_home := NEW.home_id;

    -- Only if inserted row is current.
    IF NEW.valid_to IS NULL THEN
      v_should_invalidate := true;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    v_old_home := OLD.home_id;

    -- Only if deleted row was current.
    IF OLD.valid_to IS NULL THEN
      v_should_invalidate := true;
    END IF;

  ELSE
    -- UPDATE
    v_old_home := OLD.home_id;
    v_new_home := NEW.home_id;

    -- 1) current -> not current (leave/kick): valid_to NULL -> NOT NULL
    IF OLD.valid_to IS NULL AND NEW.valid_to IS NOT NULL THEN
      v_should_invalidate := true;
    END IF;

    -- 2) valid_from changed (rare, but affects validity window)
    IF OLD.valid_from IS DISTINCT FROM NEW.valid_from THEN
      v_should_invalidate := true;
    END IF;

    -- 3) role changed (owner transfer etc.) – only matters for current row
    IF NEW.valid_to IS NULL AND OLD.role IS DISTINCT FROM NEW.role THEN
      v_should_invalidate := true;
    END IF;

    -- 4) home_id changed (rare) – invalidate both homes
    IF OLD.home_id IS DISTINCT FROM NEW.home_id THEN
      v_should_invalidate := true;
    END IF;
  END IF;

  IF v_should_invalidate THEN
    IF v_old_home IS NOT NULL THEN
      PERFORM public._house_vibes_mark_out_of_date(v_old_home);
    END IF;

    IF v_new_home IS NOT NULL AND v_new_home IS DISTINCT FROM v_old_home THEN
      PERFORM public._house_vibes_mark_out_of_date(v_new_home);
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."_house_vibes_mark_out_of_date_memberships"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_house_vibes_mark_out_of_date_preferences"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_home_id uuid;
  v_user_id uuid := null;
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    v_user_id := NEW.user_id;
  ELSIF TG_OP = 'DELETE' THEN
    v_user_id := OLD.user_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- One current home per user is enforced by uq_memberships_user_one_current (provided).
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user_id
     AND m.is_current = true
   LIMIT 1;

  IF v_home_id IS NOT NULL THEN
    PERFORM public._house_vibes_mark_out_of_date(v_home_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."_house_vibes_mark_out_of_date_preferences"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_iso_week_utc"("p_at" timestamp with time zone DEFAULT "now"()) RETURNS TABLE("iso_week_year" integer, "iso_week" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT
    to_char((p_at AT TIME ZONE 'UTC')::date, 'IYYY')::int AS iso_week_year,
    to_char((p_at AT TIME ZONE 'UTC')::date, 'IW')::int   AS iso_week;
$$;


ALTER FUNCTION "public"."_iso_week_utc"("p_at" timestamp with time zone) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."member_cap_join_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "joiner_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_reason" "text",
    "resolved_payload" "jsonb",
    "resolution_notified_at" timestamp with time zone,
    CONSTRAINT "member_cap_join_requests_resolved_reason_check" CHECK (("resolved_reason" = ANY (ARRAY['joined'::"text", 'joiner_superseded'::"text", 'home_inactive'::"text", 'invite_missing'::"text", 'owner_dismissed'::"text"])))
);


ALTER TABLE "public"."member_cap_join_requests" OWNER TO "postgres";


COMMENT ON TABLE "public"."member_cap_join_requests" IS 'Queue of join attempts blocked by member cap; resolved on owner upgrade/dismiss. Joiner names are read live from profiles.';



COMMENT ON COLUMN "public"."member_cap_join_requests"."resolution_notified_at" IS 'Set when the owner has been notified about the resolved join request.';



CREATE OR REPLACE FUNCTION "public"."_member_cap_enqueue_request"("p_home_id" "uuid", "p_joiner_user_id" "uuid") RETURNS "public"."member_cap_join_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_row public.member_cap_join_requests;
BEGIN
  IF p_home_id IS NULL OR p_joiner_user_id IS NULL THEN
    PERFORM public.api_error('INVALID_INPUT', 'home_id and joiner_user_id are required.', '22023');
  END IF;

  INSERT INTO public.member_cap_join_requests (home_id, joiner_user_id)
  VALUES (p_home_id, p_joiner_user_id)
  ON CONFLICT (home_id, joiner_user_id) WHERE resolved_at IS NULL DO UPDATE
    SET home_id = EXCLUDED.home_id  -- no-op; keeps RETURNING working
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."_member_cap_enqueue_request"("p_home_id" "uuid", "p_joiner_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_member_cap_resolve_requests"("p_home_id" "uuid", "p_reason" "text", "p_request_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_payload" "jsonb" DEFAULT NULL::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_INPUT', 'home_id is required.', '22023');
  END IF;

  IF p_reason IS NULL THEN
    PERFORM public.api_error('INVALID_REASON', 'resolved_reason is required.', '22023');
  END IF;

  UPDATE public.member_cap_join_requests
     SET resolved_at      = now(),
         resolved_reason  = p_reason,
         resolved_payload = p_payload
   WHERE home_id = p_home_id
     AND resolved_at IS NULL
     AND (p_request_ids IS NULL OR id = ANY(p_request_ids));
END;
$$;


ALTER FUNCTION "public"."_member_cap_resolve_requests"("p_home_id" "uuid", "p_reason" "text", "p_request_ids" "uuid"[], "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_preference_reports_mark_out_of_date"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := COALESCE(NEW.user_id, OLD.user_id);
BEGIN
  UPDATE public.preference_reports pr
     SET status = 'out_of_date'
   WHERE pr.subject_user_id = v_user
     AND pr.status <> 'out_of_date';

  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."_preference_reports_mark_out_of_date"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_preference_templates_validate"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_pref jsonb;

  v_template_keys text[];
  v_tax_keys text[];
  v_extra text[];
  v_missing text[];

  v_bad_shape_pref_ids jsonb;
  v_bad_option_pref_ids jsonb;

  v_mismatch_pref_ids jsonb;
  v_mismatch_details jsonb;

BEGIN
  v_pref := NEW.body->'preferences';

  PERFORM public.api_assert(
    jsonb_typeof(v_pref) = 'object',
    'INVALID_TEMPLATE_SCHEMA',
    'Template body.preferences must be a JSON object.',
    '22023',
    jsonb_build_object('path', '{preferences}')
  );

  -- preferences[pref_id] must be array length 3
  SELECT COALESCE(
    jsonb_agg(key) FILTER (WHERE NOT (
      jsonb_typeof(value) = 'array' AND jsonb_array_length(value) = 3
    )),
    '[]'::jsonb
  )
  INTO v_bad_shape_pref_ids
  FROM jsonb_each(v_pref);

  PERFORM public.api_assert(
    jsonb_array_length(v_bad_shape_pref_ids) = 0,
    'INVALID_TEMPLATE_SCHEMA',
    'Each preferences[pref_id] must be an array of length 3.',
    '22023',
    jsonb_build_object('bad_shape_pref_ids', v_bad_shape_pref_ids)
  );

  -- Collect template keys
  SELECT COALESCE(array_agg(k ORDER BY k), ARRAY[]::text[])
    INTO v_template_keys
  FROM jsonb_object_keys(v_pref) AS k;

  -- Collect active taxonomy keys that have defs
  SELECT COALESCE(array_agg(t.preference_id ORDER BY t.preference_id), ARRAY[]::text[])
    INTO v_tax_keys
  FROM public.preference_taxonomy t
  JOIN public.preference_taxonomy_defs d USING (preference_id)
  WHERE t.is_active = true;

  PERFORM public.api_assert(
    COALESCE(array_length(v_tax_keys, 1), 0) > 0,
    'INVALID_TEMPLATE_KEYS',
    'No active preference taxonomy defs exist; cannot validate template keys.',
    '22023',
    '{}'::jsonb
  );

  -- Extra keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_extra
  FROM (
    SELECT unnest(v_template_keys) AS x
    EXCEPT
    SELECT unnest(v_tax_keys) AS x
  ) s;

  -- Missing keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_missing
  FROM (
    SELECT unnest(v_tax_keys) AS x
    EXCEPT
    SELECT unnest(v_template_keys) AS x
  ) s;

  PERFORM public.api_assert(
    COALESCE(array_length(v_extra, 1), 0) = 0
    AND COALESCE(array_length(v_missing, 1), 0) = 0,
    'INVALID_TEMPLATE_KEYS',
    'Template preference keys must exactly match active preference_taxonomy_defs for active taxonomy IDs.',
    '22023',
    jsonb_build_object(
      'extra_pref_ids', COALESCE(to_jsonb(v_extra), '[]'::jsonb),
      'missing_pref_ids', COALESCE(to_jsonb(v_missing), '[]'::jsonb)
    )
  );

  -- Enforce option object schema everywhere
  WITH each_pref AS (
    SELECT e.key AS preference_id, e.value AS arr
    FROM jsonb_each(v_pref) e(key, value)
  ),
  bad AS (
    SELECT preference_id
    FROM each_pref
    WHERE
      jsonb_typeof(arr->0) <> 'object'
      OR jsonb_typeof(arr->1) <> 'object'
      OR jsonb_typeof(arr->2) <> 'object'
      OR jsonb_typeof(arr->0->'value_key') <> 'string'
      OR jsonb_typeof(arr->1->'value_key') <> 'string'
      OR jsonb_typeof(arr->2->'value_key') <> 'string'
      OR jsonb_typeof(arr->0->'title') <> 'string'
      OR jsonb_typeof(arr->1->'title') <> 'string'
      OR jsonb_typeof(arr->2->'title') <> 'string'
      OR jsonb_typeof(arr->0->'text') <> 'string'
      OR jsonb_typeof(arr->1->'text') <> 'string'
      OR jsonb_typeof(arr->2->'text') <> 'string'
  )
  SELECT COALESCE(jsonb_agg(preference_id), '[]'::jsonb)
  INTO v_bad_option_pref_ids
  FROM bad;

  PERFORM public.api_assert(
    jsonb_array_length(v_bad_option_pref_ids) = 0,
    'INVALID_TEMPLATE_OPTION_SCHEMA',
    'Each preferences[pref_id][0..2] must be an object with string keys: value_key, title, text.',
    '22023',
    jsonb_build_object('bad_option_pref_ids', v_bad_option_pref_ids)
  );

  -- Enforce value_key matches defs.value_keys by index order (0..2)
  WITH mismatches AS (
    SELECT
      t.preference_id,
      jsonb_build_object(
        'expected', jsonb_build_array(d.value_keys[1], d.value_keys[2], d.value_keys[3]),
        'got', jsonb_build_array(
          COALESCE(NEW.body->'preferences'->t.preference_id->0->>'value_key', ''),
          COALESCE(NEW.body->'preferences'->t.preference_id->1->>'value_key', ''),
          COALESCE(NEW.body->'preferences'->t.preference_id->2->>'value_key', '')
        )
      ) AS details
    FROM public.preference_taxonomy t
    JOIN public.preference_taxonomy_defs d USING (preference_id)
    WHERE t.is_active = true
      AND (
        COALESCE(NEW.body->'preferences'->t.preference_id->0->>'value_key', '') <> d.value_keys[1]
        OR COALESCE(NEW.body->'preferences'->t.preference_id->1->>'value_key', '') <> d.value_keys[2]
        OR COALESCE(NEW.body->'preferences'->t.preference_id->2->>'value_key', '') <> d.value_keys[3]
      )
  )
  SELECT
    COALESCE(jsonb_agg(preference_id), '[]'::jsonb),
    COALESCE(jsonb_object_agg(preference_id, details), '{}'::jsonb)
  INTO v_mismatch_pref_ids, v_mismatch_details
  FROM mismatches;

  PERFORM public.api_assert(
    jsonb_array_length(v_mismatch_pref_ids) = 0,
    'INVALID_TEMPLATE_VALUE_KEYS',
    'Template option value_key must match preference_taxonomy_defs.value_keys in index order (0..2).',
    '22023',
    jsonb_build_object(
      'mismatched_value_key_pref_ids', v_mismatch_pref_ids,
      'mismatches', v_mismatch_details
    )
  );

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."_preference_templates_validate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_sha256_hex"("p_input" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select encode(
    extensions.digest(
      convert_to(coalesce(p_input, ''), 'utf8'),
      'sha256'::text
    ),
    'hex'
  );
$$;


ALTER FUNCTION "public"."_sha256_hex"("p_input" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_share_log_event_internal"("p_user_id" "uuid", "p_home_id" "uuid", "p_feature" "text", "p_channel" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  insert into public.share_events (user_id, home_id, feature, channel)
  values (p_user_id, p_home_id, p_feature, p_channel);
end;
$$;


ALTER FUNCTION "public"."_share_log_event_internal"("p_user_id" "uuid", "p_home_id" "uuid", "p_feature" "text", "p_channel" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."_share_log_event_internal"("p_user_id" "uuid", "p_home_id" "uuid", "p_feature" "text", "p_channel" "text") IS 'Internal helper for writing share attempts; callers must handle auth/membership.';



CREATE OR REPLACE FUNCTION "public"."_touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."_touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_assert"("p_condition" boolean, "p_code" "text", "p_msg" "text", "p_sqlstate" "text" DEFAULT 'P0001'::"text", "p_details" "jsonb" DEFAULT NULL::"jsonb", "p_hint" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF NOT coalesce(p_condition, false) THEN
    PERFORM public.api_error(p_code, p_msg, p_sqlstate, p_details, p_hint);
  END IF;
END;
$$;


ALTER FUNCTION "public"."api_assert"("p_condition" boolean, "p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."api_error"("p_code" "text", "p_msg" "text", "p_sqlstate" "text" DEFAULT 'P0001'::"text", "p_details" "jsonb" DEFAULT NULL::"jsonb", "p_hint" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_message text;
  v_detail  text;
BEGIN
  -- Build a structured JSON error message.
  v_message := pg_catalog.json_build_object(
    'code',    p_code,
    'message', p_msg,
    'details', COALESCE(p_details, '{}'::jsonb)
  )::text;

  -- DETAIL should never be NULL in RAISE ... USING
  v_detail := COALESCE(p_details::text, '');

  RAISE EXCEPTION USING
    MESSAGE = COALESCE(v_message, 'Unknown error'),
    ERRCODE = COALESCE(p_sqlstate, 'P0001'),
    DETAIL  = v_detail,
    HINT    = COALESCE(p_hint, '');
END;
$$;


ALTER FUNCTION "public"."api_error"("p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."avatars_list_for_home"("p_home_id" "uuid") RETURNS TABLE("id" "uuid", "storage_path" "text", "category" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_plan        text;
  v_self_user   uuid;
  v_self_avatar uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  v_self_user := auth.uid();

  -- current user's avatar (so we can still show it even if "in use")
  SELECT p.avatar_id
  INTO v_self_avatar
  FROM public.profiles p
  WHERE p.id = v_self_user
    AND p.deactivated_at IS NULL;

  -- ✅ Use shared helper for effective plan
  v_plan := public._home_effective_plan(p_home_id);

  IF v_plan IS NULL THEN
    v_plan := 'free';
  END IF;

  -- Avatars already used by *other* current members in this home
  RETURN QUERY
    WITH used_by_others AS (
      SELECT DISTINCT p.avatar_id
      FROM public.memberships m
      JOIN public.profiles p
        ON p.id = m.user_id
      WHERE m.home_id = p_home_id
        AND m.is_current = TRUE
        AND p.deactivated_at IS NULL
        AND p.id <> v_self_user
    )
    SELECT
      a.id,
      a.storage_path,
      a.category
    FROM public.avatars a
    LEFT JOIN used_by_others u
      ON u.avatar_id = a.id
    WHERE
      (
        -- plan gating
        v_plan <> 'free'
        OR (v_plan = 'free' AND a.category = 'animal')
      )
      AND (
        u.avatar_id IS NULL           -- not used by others
        OR a.id = v_self_avatar       -- always allow my current avatar
      )
    ORDER BY
      a.created_at ASC;
END;
$$;


ALTER FUNCTION "public"."avatars_list_for_home"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_app_version"("client_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE STRICT SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_in text := btrim(client_version);
  cv_major int;
  cv_minor int;
  cv_patch int;

  v record;
  hard_block boolean;
BEGIN
  IF v_in !~ '^\d+\.\d+\.\d+$' THEN
    RAISE EXCEPTION 'client_version must be "x.y.z" (digits only)'
      USING ERRCODE = '22023';
  END IF;

  -- safe to parse now
  cv_major := split_part(v_in, '.', 1)::int;
  cv_minor := split_part(v_in, '.', 2)::int;
  cv_patch := split_part(v_in, '.', 3)::int;

  SELECT version_number, min_supported_version, release_date, notes
    INTO v
    FROM public.app_version
   WHERE is_current IS TRUE
   LIMIT 1;

  IF v IS NULL THEN
    RETURN jsonb_build_object(
      'hardBlocked', false,
      'updateRecommended', false,
      'message', 'No server version configured'
    );
  END IF;

  hard_block :=
    (cv_major, cv_minor, cv_patch) <
    (split_part(v.min_supported_version,'.',1)::int,
     split_part(v.min_supported_version,'.',2)::int,
     split_part(v.min_supported_version,'.',3)::int);

  RETURN jsonb_build_object(
    'clientVersion',       v_in,
    'currentVersion',      v.version_number,
    'minSupportedVersion', v.min_supported_version,
    'hardBlocked',         hard_block,
    'updateRecommended',   (NOT hard_block) AND (
      (cv_major, cv_minor, cv_patch) <
      (split_part(v.version_number,'.',1)::int,
       split_part(v.version_number,'.',2)::int,
       split_part(v.version_number,'.',3)::int)
    ),
    'notes',               v.notes,
    'releasedAt',          v.release_date
  );
END;
$_$;


ALTER FUNCTION "public"."check_app_version"("client_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chore_complete"("_chore_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_chore          public.chores%ROWTYPE;
  v_current_due    date;
  v_steps_advanced integer := 0;
  v_user           uuid := auth.uid();
  v_every          integer;
  v_unit           text;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_chore
  FROM public.chores
  WHERE id = _chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('CHORE_NOT_FOUND', 'Chore not found or not accessible.', '22023', jsonb_build_object('chore_id', _chore_id));
  END IF;

  PERFORM public._assert_home_member(v_chore.home_id);
  PERFORM public.api_assert(
    v_chore.assignee_user_id = v_user,
    'FORBIDDEN',
    'Only the current assignee can complete this chore.',
    '42501',
    jsonb_build_object('chore_id', _chore_id)
  );
  PERFORM public.api_assert(
    v_chore.state = 'active',
    'INVALID_STATE',
    'Only active chores can be completed.',
    '22023',
    jsonb_build_object('chore_id', _chore_id, 'state', v_chore.state)
  );

  v_current_due := COALESCE(v_chore.recurrence_cursor, v_chore.start_date);

  v_every := v_chore.recurrence_every;
  v_unit := v_chore.recurrence_unit;

  IF v_every IS NULL AND v_unit IS NULL THEN
    SELECT * INTO v_every, v_unit
    FROM public._chore_recurrence_to_every_unit(v_chore.recurrence);
  END IF;

  -------------------------------------------------------------------
  -- Case 1: non-recurring chore -> mark completed once and for all
  -------------------------------------------------------------------
  IF v_every IS NULL OR v_unit IS NULL THEN
    UPDATE public.chores
    SET state             = 'completed',
        completed_at      = COALESCE(v_chore.completed_at, now()),
        recurrence_cursor = NULL,
        updated_at        = now()
    WHERE id = _chore_id;

    PERFORM public._home_usage_apply_delta(
      v_chore.home_id,
      jsonb_build_object('active_chores', -1)
    );

    RETURN jsonb_build_object(
      'status',   'non_recurring_completed',
      'chore_id', _chore_id,
      'home_id',  v_chore.home_id,
      'state',    'completed'
    );
  END IF;

  -------------------------------------------------------------------
  -- Case 2: recurring chore -> advance to first date AFTER today
  -------------------------------------------------------------------
  WHILE v_current_due <= current_date LOOP
    CASE v_unit
      WHEN 'day' THEN v_current_due := v_current_due + v_every;
      WHEN 'week' THEN v_current_due := v_current_due + (v_every * 7);
      WHEN 'month' THEN v_current_due := (v_current_due + (v_every || ' months')::interval)::date;
      WHEN 'year' THEN v_current_due := (v_current_due + (v_every || ' years')::interval)::date;
      ELSE EXIT;
    END CASE;
    v_steps_advanced := v_steps_advanced + 1;
  END LOOP;

  IF v_steps_advanced = 0 THEN
    RETURN jsonb_build_object(
      'status',   'already_completed_for_cycle',
      'chore_id', _chore_id,
      'home_id',  v_chore.home_id,
      'state',    v_chore.state
    );
  END IF;

  UPDATE public.chores
  SET
    recurrence_cursor = v_current_due,
    completed_at      = now(),
    updated_at        = now()
  WHERE id = _chore_id;

  RETURN jsonb_build_object(
    'status',          'recurring_completed',
    'chore_id',        _chore_id,
    'home_id',         v_chore.home_id,
    'recurrenceEvery', v_every,
    'recurrenceUnit',  v_unit,
    'state',           v_chore.state,
    'cursor_after',    v_current_due,
    'steps_advanced',  v_steps_advanced
  );
END;
$$;


ALTER FUNCTION "public"."chore_complete"("_chore_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_cancel"("p_chore_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_chore public.chores%ROWTYPE;
  v_user  uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_chore
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Chore not found.', '22023', jsonb_build_object('chore_id', p_chore_id));
  END IF;

  PERFORM public._assert_home_member(v_chore.home_id);
  PERFORM public.api_assert(
    v_chore.created_by_user_id = v_user OR v_chore.assignee_user_id = v_user,
    'FORBIDDEN',
    'Only the chore creator or current assignee can cancel.',
    '42501',
    jsonb_build_object('choreId', p_chore_id)
  );
  PERFORM public.api_assert(
    v_chore.state IN ('draft', 'active'),
    'ALREADY_FINALIZED',
    'Only draft/active chores can be cancelled.',
    '22023'
  );

  UPDATE public.chores
  SET state             = 'cancelled',
      recurrence        = 'none',
      recurrence_cursor = NULL,
      updated_at        = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_chore;

  -- Decrement active_chores by 1 (clamped at 0 in the helper)
  PERFORM public._home_usage_apply_delta(
    v_chore.home_id,
    jsonb_build_object('active_chores', -1)
  );

  RETURN jsonb_build_object('chore', to_jsonb(v_chore));
END;
$$;


ALTER FUNCTION "public"."chores_cancel"("p_chore_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "created_by_user_id" "uuid" NOT NULL,
    "assignee_user_id" "uuid",
    "name" "text" NOT NULL,
    "start_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "recurrence" "public"."recurrence_interval" DEFAULT 'none'::"public"."recurrence_interval" NOT NULL,
    "recurrence_cursor" "date",
    "expectation_photo_path" "text",
    "how_to_video_url" "text",
    "notes" "text",
    "completed_at" timestamp with time zone,
    "state" "public"."chore_state" DEFAULT 'draft'::"public"."chore_state" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recurrence_every" integer,
    "recurrence_unit" "text",
    CONSTRAINT "chk_chore_active_has_assignee" CHECK ((("state" <> 'active'::"public"."chore_state") OR ("assignee_user_id" IS NOT NULL))),
    CONSTRAINT "chk_chore_draft_without_assignee" CHECK ((("state" <> 'draft'::"public"."chore_state") OR ("assignee_user_id" IS NULL))),
    CONSTRAINT "chk_chore_expectation_path" CHECK ((("expectation_photo_path" IS NULL) OR (("expectation_photo_path" !~ '^[A-Za-z][A-Za-z0-9+.-]*://'::"text") AND ("expectation_photo_path" ~ '^flow/[a-z0-9_-]+/[A-Za-z0-9_./-]+$'::"text")))),
    CONSTRAINT "chk_chore_name_length" CHECK ((("char_length"("btrim"("name")) >= 1) AND ("char_length"("btrim"("name")) <= 140))),
    CONSTRAINT "chk_chores_recurrence_every_min" CHECK ((("recurrence_every" IS NULL) OR ("recurrence_every" >= 1))),
    CONSTRAINT "chk_chores_recurrence_pair" CHECK (((("recurrence_every" IS NULL) AND ("recurrence_unit" IS NULL)) OR (("recurrence_every" IS NOT NULL) AND ("recurrence_unit" IS NOT NULL)))),
    CONSTRAINT "chk_chores_recurrence_unit_allowed" CHECK ((("recurrence_unit" IS NULL) OR ("recurrence_unit" = ANY (ARRAY['day'::"text", 'week'::"text", 'month'::"text", 'year'::"text"])))),
    CONSTRAINT "chores_how_to_video_url_scheme" CHECK ((("how_to_video_url" IS NULL) OR ("how_to_video_url" ~* '^https?://'::"text")))
);


ALTER TABLE "public"."chores" OWNER TO "postgres";


COMMENT ON TABLE "public"."chores" IS 'Household chores authored within a home. Single-assignee, optional recurrence.';



COMMENT ON COLUMN "public"."chores"."home_id" IS 'FK to homes.id. Chore belongs to this home.';



COMMENT ON COLUMN "public"."chores"."created_by_user_id" IS 'Author of the chore.';



COMMENT ON COLUMN "public"."chores"."assignee_user_id" IS 'Responsible user when state=active.';



COMMENT ON COLUMN "public"."chores"."start_date" IS 'Initial due date.';



COMMENT ON COLUMN "public"."chores"."recurrence" IS 'none|daily|weekly|every_2_weeks|monthly|every_2_months|annual';



COMMENT ON COLUMN "public"."chores"."recurrence_cursor" IS 'Anchor date for recurrence (next due).';



COMMENT ON COLUMN "public"."chores"."expectation_photo_path" IS 'Supabase Storage object path (no bucket/host) for chore photos.';



COMMENT ON COLUMN "public"."chores"."completed_at" IS 'Time when first marked completed.';



COMMENT ON COLUMN "public"."chores"."state" IS 'draft|active|completed|cancelled.';



COMMENT ON COLUMN "public"."chores"."recurrence_every" IS 'NULL for one-off; >=1 for recurring cadence.';



COMMENT ON COLUMN "public"."chores"."recurrence_unit" IS 'Allowed units: day|week|month|year. NULL for one-off.';



CREATE OR REPLACE FUNCTION "public"."chores_create"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid" DEFAULT NULL::"uuid", "p_start_date" "date" DEFAULT CURRENT_DATE, "p_recurrence" "public"."recurrence_interval" DEFAULT 'none'::"public"."recurrence_interval", "p_how_to_video_url" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_expectation_photo_path" "text" DEFAULT NULL::"text") RETURNS "public"."chores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_state        public.chore_state;
  v_usage_delta  integer := 1;
  v_photo_delta  integer := 0;
  v_row          public.chores;
  v_recur_every  integer;
  v_recur_unit   text;
BEGIN
  PERFORM public._assert_authenticated();

  -- Ensure caller actually belongs to this home (and is_current)
  PERFORM public._assert_home_member(p_home_id);

  -- Validate required name
  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  -- If assignee is provided, enforce they are a current member of this home
  IF p_assignee_user_id IS NOT NULL THEN
    PERFORM public.api_assert(
      EXISTS (
        SELECT 1
        FROM public.memberships m
        WHERE m.home_id = p_home_id
          AND m.user_id = p_assignee_user_id
          AND m.is_current
      ),
      'ASSIGNEE_NOT_CURRENT_MEMBER',
      'Assignee must be a current member of this home.',
      '42501',
      jsonb_build_object(
        'home_id',   p_home_id,
        'assignee',  p_assignee_user_id
      )
    );
    v_state := 'active';
  ELSE
    v_state := 'draft';
  END IF;

  SELECT * INTO v_recur_every, v_recur_unit
  FROM public._chore_recurrence_to_every_unit(COALESCE(p_recurrence, 'none'));

  -- Compute photo delta: only if we are creating with a photo
  IF p_expectation_photo_path IS NOT NULL THEN
    v_photo_delta := 1;
  END IF;

  -- Paywall check at SAVE time (quota helper)
  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,  -- +1 chore
        'chore_photos',  v_photo_delta   -- +1 photo if present
      )
    )
  );

  -- Insert chore
  INSERT INTO public.chores (
    home_id,
    created_by_user_id,
    assignee_user_id,
    name,
    start_date,
    recurrence,
    recurrence_every,
    recurrence_unit,
    how_to_video_url,
    notes,
    expectation_photo_path,
    state
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_assignee_user_id,
    p_name,
    COALESCE(p_start_date, current_date),
    COALESCE(p_recurrence, 'none'),
    v_recur_every,
    v_recur_unit,
    p_how_to_video_url,
    p_notes,
    p_expectation_photo_path,
    v_state
  )
  RETURNING * INTO v_row;

  -- Update usage counters via JSON-based helper
  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,
        'chore_photos',  v_photo_delta
      )
    )
  );

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."chores_create"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_create_v2"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid" DEFAULT NULL::"uuid", "p_start_date" "date" DEFAULT CURRENT_DATE, "p_recurrence_every" integer DEFAULT NULL::integer, "p_recurrence_unit" "text" DEFAULT NULL::"text", "p_how_to_video_url" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_expectation_photo_path" "text" DEFAULT NULL::"text") RETURNS "public"."chores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_state        public.chore_state;
  v_usage_delta  integer := 1;
  v_photo_delta  integer := 0;
  v_row          public.chores;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery and recurrenceUnit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF p_recurrence_every IS NOT NULL AND p_recurrence_every < 1 THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery must be >= 1.',
      '22023',
      jsonb_build_object('field', 'recurrenceEvery')
    );
  END IF;

  IF p_recurrence_unit IS NOT NULL
     AND p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceUnit must be one of day|week|month|year.',
      '22023',
      jsonb_build_object('field', 'recurrenceUnit')
    );
  END IF;

  -- If assignee is provided, enforce they are a current member of this home
  IF p_assignee_user_id IS NOT NULL THEN
    PERFORM public.api_assert(
      EXISTS (
        SELECT 1
        FROM public.memberships m
        WHERE m.home_id = p_home_id
          AND m.user_id = p_assignee_user_id
          AND m.is_current
      ),
      'ASSIGNEE_NOT_CURRENT_MEMBER',
      'Assignee must be a current member of this home.',
      '42501',
      jsonb_build_object(
        'home_id',   p_home_id,
        'assignee',  p_assignee_user_id
      )
    );
    v_state := 'active';
  ELSE
    v_state := 'draft';
  END IF;

  IF p_expectation_photo_path IS NOT NULL THEN
    v_photo_delta := 1;
  END IF;

  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,
        'chore_photos',  v_photo_delta
      )
    )
  );

  INSERT INTO public.chores (
    home_id,
    created_by_user_id,
    assignee_user_id,
    name,
    start_date,
    recurrence_every,
    recurrence_unit,
    how_to_video_url,
    notes,
    expectation_photo_path,
    state
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_assignee_user_id,
    p_name,
    COALESCE(p_start_date, current_date),
    p_recurrence_every,
    p_recurrence_unit,
    p_how_to_video_url,
    p_notes,
    p_expectation_photo_path,
    v_state
  )
  RETURNING * INTO v_row;

  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,
        'chore_photos',  v_photo_delta
      )
    )
  );

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."chores_create_v2"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_events_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_actor       uuid := auth.uid();
  v_event_type  public.chore_event_type;
  v_from_state  public.chore_state;
  v_to_state    public.chore_state;
  v_payload     jsonb := '{}'::jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  IF TG_OP = 'INSERT' THEN
    v_event_type := 'create';
    v_to_state   := NEW.state;
    v_payload := jsonb_build_object(
      'name',               NEW.name,
      'recurrence',         NEW.recurrence,
      'recurrence_every',   NEW.recurrence_every,
      'recurrence_unit',    NEW.recurrence_unit,
      'recurrence_cursor',  NEW.recurrence_cursor,
      'assignee_user_id',   NEW.assignee_user_id
    );
    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (NEW.id, NEW.home_id, v_actor, v_event_type, NULL, v_to_state, v_payload);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.assignee_user_id      IS NOT DISTINCT FROM NEW.assignee_user_id
       AND OLD.recurrence        IS NOT DISTINCT FROM NEW.recurrence
       AND OLD.recurrence_every  IS NOT DISTINCT FROM NEW.recurrence_every
       AND OLD.recurrence_unit   IS NOT DISTINCT FROM NEW.recurrence_unit
       AND OLD.recurrence_cursor IS NOT DISTINCT FROM NEW.recurrence_cursor
       AND OLD.state             IS NOT DISTINCT FROM NEW.state THEN
      RETURN NEW;
    END IF;

    v_from_state := OLD.state;
    v_to_state   := NEW.state;

    IF NEW.recurrence_cursor IS NOT NULL
       AND OLD.recurrence_cursor IS NOT NULL
       AND NEW.recurrence_cursor > OLD.recurrence_cursor THEN
      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'recurrence_every', NEW.recurrence_every,
        'recurrence_unit',  NEW.recurrence_unit,
        'cursor_before',    OLD.recurrence_cursor,
        'cursor_after',     NEW.recurrence_cursor
      );

    ELSIF OLD.state <> 'completed'
          AND NEW.state = 'completed' THEN
      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'completed_state_from', OLD.state,
        'completed_state_to',   NEW.state
      );

    ELSIF OLD.state IN ('draft', 'active')
          AND NEW.state = 'cancelled' THEN
      v_event_type := 'cancel';
      v_payload := jsonb_build_object(
        'state_from',        OLD.state,
        'state_to',          NEW.state,
        'recurrence_before', OLD.recurrence,
        'recurrence_every',  OLD.recurrence_every,
        'recurrence_unit',   OLD.recurrence_unit,
        'cursor_before',     OLD.recurrence_cursor,
        'assignee_user_id',  OLD.assignee_user_id
      );

    ELSIF OLD.state = 'draft'
          AND NEW.state = 'active' THEN
      v_event_type := 'activate';
      v_payload := jsonb_build_object(
        'state_from', OLD.state,
        'state_to',   NEW.state
      );

    ELSIF OLD.assignee_user_id IS DISTINCT FROM NEW.assignee_user_id THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'change_type',   'assignee',
        'assignee_event',
          CASE
            WHEN OLD.assignee_user_id IS NULL AND NEW.assignee_user_id IS NOT NULL THEN 'assign'
            WHEN OLD.assignee_user_id IS NOT NULL AND NEW.assignee_user_id IS NULL THEN 'unassign'
            ELSE 'reassign'
          END,
        'assignee_from', OLD.assignee_user_id,
        'assignee_to',   NEW.assignee_user_id
      );

    ELSIF OLD.recurrence_every IS DISTINCT FROM NEW.recurrence_every
          OR OLD.recurrence_unit IS DISTINCT FROM NEW.recurrence_unit THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'recurrence_every_from', OLD.recurrence_every,
        'recurrence_every_to',   NEW.recurrence_every,
        'recurrence_unit_from',  OLD.recurrence_unit,
        'recurrence_unit_to',    NEW.recurrence_unit
      );

    ELSIF OLD.state IS DISTINCT FROM NEW.state THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'state_from', OLD.state,
        'state_to',   NEW.state
      );

    ELSE
      RETURN NEW;
    END IF;

    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (NEW.id, NEW.home_id, v_actor, v_event_type, v_from_state, v_to_state, v_payload);
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    v_event_type := 'cancel';
    v_from_state := OLD.state;
    v_payload := jsonb_build_object('reason', 'deleted', 'state', OLD.state);
    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (OLD.id, OLD.home_id, v_actor, v_event_type, v_from_state, NULL, v_payload);
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."chores_events_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_get_for_home"("p_home_id" "uuid", "p_chore_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_chore     jsonb;
  v_assignees jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT jsonb_build_object(
           'id',                    base.id,
           'home_id',               base.home_id,
           'created_by_user_id',    base.created_by_user_id,
           'assignee_user_id',      base.assignee_user_id,
           'name',                  base.name,
           'start_date',            base.current_due_on,
           'recurrence',            c.recurrence,
           'recurrence_every',      c.recurrence_every,
           'recurrence_unit',       c.recurrence_unit,
           'recurrence_cursor',     c.recurrence_cursor,
           'expectation_photo_path',c.expectation_photo_path,
           'how_to_video_url',      c.how_to_video_url,
           'notes',                 c.notes,
           'state',                 base.state,
           'completed_at',          c.completed_at,
           'created_at',            base.created_at,
           'updated_at',            c.updated_at,
           'assignee',
             CASE
               WHEN base.assignee_user_id IS NULL THEN NULL
               ELSE jsonb_build_object(
                 'id',                 base.assignee_user_id,
                 'full_name',          base.assignee_full_name,
                 'avatar_storage_path',base.assignee_avatar_storage_path
               )
             END
         )
    INTO v_chore
    FROM public._chores_base_for_home(p_home_id) AS base
    JOIN public.chores c
      ON c.id = base.id
   WHERE base.id = p_chore_id;

  IF v_chore IS NULL THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found for this home.',
      '22023',
      jsonb_build_object('home_id', p_home_id, 'chore_id', p_chore_id)
    );
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'user_id',             m.user_id,
               'full_name',           p.full_name,
               'avatar_storage_path', a.storage_path
             )
             ORDER BY p.full_name
           ),
           '[]'::jsonb
         )
    INTO v_assignees
    FROM public.memberships m
    JOIN public.profiles p
      ON p.id = m.user_id
    JOIN public.avatars a
      ON a.id = p.avatar_id
   WHERE m.home_id   = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'chore',     v_chore,
    'assignees', v_assignees
  );
END;
$$;


ALTER FUNCTION "public"."chores_get_for_home"("p_home_id" "uuid", "p_chore_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_list_for_home"("p_home_id" "uuid") RETURNS TABLE("id" "uuid", "home_id" "uuid", "assignee_user_id" "uuid", "name" "text", "start_date" "date", "assignee_full_name" "text", "assignee_avatar_storage_path" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT
    id,
    home_id,
    assignee_user_id,
    name,
    current_due_on AS start_date,
    assignee_full_name,
    assignee_avatar_storage_path
  FROM public._chores_base_for_home(p_home_id)
  WHERE state IN ('draft', 'active')
    AND (
      state = 'active'::public.chore_state
      OR (state = 'draft'::public.chore_state AND created_by_user_id = auth.uid())
    )
  ORDER BY current_due_on DESC, created_at DESC;
$$;


ALTER FUNCTION "public"."chores_list_for_home"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_reassign_on_member_leave"("v_home_id" "uuid", "v_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_owner_user_id uuid;
BEGIN
  -- Find current owner of the home
  SELECT m.user_id
    INTO v_owner_user_id
  FROM public.memberships m
  WHERE m.home_id = v_home_id
    AND m.role = 'owner'
    AND m.is_current = TRUE
  LIMIT 1;

  -- If no owner (e.g., home deactivated), do nothing
  IF v_owner_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Reassign active chores from leaving member to owner
  UPDATE public.chores c
     SET assignee_user_id = v_owner_user_id,
         updated_at       = now()
   WHERE c.home_id = v_home_id
     AND c.assignee_user_id = v_user_id
     AND c.state IN ('draft', 'active');

END;
$$;


ALTER FUNCTION "public"."chores_reassign_on_member_leave"("v_home_id" "uuid", "v_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_update"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval" DEFAULT NULL::"public"."recurrence_interval", "p_expectation_photo_path" "text" DEFAULT NULL::"text", "p_how_to_video_url" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."chores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_existing     public.chores;
  v_new          public.chores;
  v_new_path     text;
  v_photo_delta  integer := 0;
  v_target_recur public.recurrence_interval;
  v_target_every integer;
  v_target_unit  text;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_assignee_user_id IS NOT NULL,
    'INVALID_INPUT',
    'Assignee is required when updating a chore.',
    '22023',
    jsonb_build_object('field', 'assignee_user_id')
  );
  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  SELECT * INTO v_existing
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Chore not found.', '22023', jsonb_build_object('chore_id', p_chore_id));
  END IF;

  PERFORM public._assert_home_member(v_existing.home_id);

  PERFORM public.api_assert(
    v_existing.created_by_user_id = v_user_id
    OR v_existing.assignee_user_id = v_user_id,
    'FORBIDDEN',
    'Only the chore creator or current assignee can update this chore.',
    '42501',
    jsonb_build_object('chore_id', p_chore_id, 'home_id', v_existing.home_id)
  );

  -- Assignee must be a current member of this home
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      WHERE m.home_id = v_existing.home_id
        AND m.user_id = p_assignee_user_id
        AND m.is_current
    ),
    'ASSIGNEE_NOT_CURRENT_MEMBER',
    'Assignee must be a current member of this home.',
    '42501',
    jsonb_build_object(
      'home_id',  v_existing.home_id,
      'assignee', p_assignee_user_id
    )
  );

  v_target_recur := COALESCE(p_recurrence, v_existing.recurrence);
  v_target_every := v_existing.recurrence_every;
  v_target_unit := v_existing.recurrence_unit;

  IF p_recurrence IS NOT NULL THEN
    SELECT * INTO v_target_every, v_target_unit
    FROM public._chore_recurrence_to_every_unit(p_recurrence);
  END IF;

  -- Work out what the *new* path will be after COALESCE
  v_new_path := COALESCE(p_expectation_photo_path, v_existing.expectation_photo_path);
  IF v_existing.expectation_photo_path IS NULL AND v_new_path IS NOT NULL THEN
    v_photo_delta := 1;
  ELSIF v_existing.expectation_photo_path IS NOT NULL AND v_new_path IS NULL THEN
    v_photo_delta := -1;
  ELSE
    v_photo_delta := 0;   -- no slot change
  END IF;

  -- Paywall check if we're *adding* a photo slot
  IF v_photo_delta > 0 THEN
    PERFORM public._home_assert_quota(
      v_existing.home_id,
      jsonb_build_object(
        'chore_photos', v_photo_delta
      )
    );
  END IF;

  UPDATE public.chores
  SET
    name                   = p_name,
    assignee_user_id       = p_assignee_user_id,
    start_date             = p_start_date,
    recurrence             = v_target_recur,
    recurrence_every       = v_target_every,
    recurrence_unit        = v_target_unit,
    expectation_photo_path = v_new_path,
    how_to_video_url       = COALESCE(p_how_to_video_url, v_existing.how_to_video_url),
    notes                  = COALESCE(p_notes, v_existing.notes),
    state                  = 'active',
    updated_at             = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_new;

  -- Update usage counters if the slot changed
  IF v_photo_delta <> 0 THEN
    PERFORM public._home_usage_apply_delta(
      v_new.home_id,
      jsonb_build_object('chore_photos', v_photo_delta)
    );
  END IF;

  RETURN v_new;
END;
$$;


ALTER FUNCTION "public"."chores_update"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chores_update_v2"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date" DEFAULT NULL::"date", "p_recurrence_every" integer DEFAULT NULL::integer, "p_recurrence_unit" "text" DEFAULT NULL::"text", "p_expectation_photo_path" "text" DEFAULT NULL::"text", "p_how_to_video_url" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."chores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_existing     public.chores;
  v_new          public.chores;
  v_new_path     text;
  v_photo_delta  integer := 0;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_assignee_user_id IS NOT NULL,
    'INVALID_INPUT',
    'Assignee is required when updating a chore.',
    '22023',
    jsonb_build_object('field', 'assignee_user_id')
  );
  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery and recurrenceUnit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF p_recurrence_every IS NOT NULL AND p_recurrence_every < 1 THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery must be >= 1.',
      '22023',
      jsonb_build_object('field', 'recurrenceEvery')
    );
  END IF;

  IF p_recurrence_unit IS NOT NULL
     AND p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceUnit must be one of day|week|month|year.',
      '22023',
      jsonb_build_object('field', 'recurrenceUnit')
    );
  END IF;

  SELECT * INTO v_existing
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Chore not found.', '22023', jsonb_build_object('chore_id', p_chore_id));
  END IF;

  PERFORM public._assert_home_member(v_existing.home_id);

  PERFORM public.api_assert(
    v_existing.created_by_user_id = v_user_id
    OR v_existing.assignee_user_id = v_user_id,
    'FORBIDDEN',
    'Only the chore creator or current assignee can update this chore.',
    '42501',
    jsonb_build_object('chore_id', p_chore_id, 'home_id', v_existing.home_id)
  );

  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      WHERE m.home_id = v_existing.home_id
        AND m.user_id = p_assignee_user_id
        AND m.is_current
    ),
    'ASSIGNEE_NOT_CURRENT_MEMBER',
    'Assignee must be a current member of this home.',
    '42501',
    jsonb_build_object(
      'home_id',  v_existing.home_id,
      'assignee', p_assignee_user_id
    )
  );


  v_new_path := COALESCE(p_expectation_photo_path, v_existing.expectation_photo_path);
  IF v_existing.expectation_photo_path IS NULL AND v_new_path IS NOT NULL THEN
    v_photo_delta := 1;
  ELSIF v_existing.expectation_photo_path IS NOT NULL AND v_new_path IS NULL THEN
    v_photo_delta := -1;
  ELSE
    v_photo_delta := 0;
  END IF;

  IF v_photo_delta > 0 THEN
    PERFORM public._home_assert_quota(
      v_existing.home_id,
      jsonb_build_object(
        'chore_photos', v_photo_delta
      )
    );
  END IF;

  UPDATE public.chores
  SET
    name                   = p_name,
    assignee_user_id       = p_assignee_user_id,
    start_date             = COALESCE(p_start_date, v_existing.start_date),
    recurrence_every       = p_recurrence_every,
    recurrence_unit        = p_recurrence_unit,
    expectation_photo_path = v_new_path,
    how_to_video_url       = COALESCE(p_how_to_video_url, v_existing.how_to_video_url),
    notes                  = COALESCE(p_notes, v_existing.notes),
    state                  = 'active',
    updated_at             = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_new;

  IF v_photo_delta <> 0 THEN
    PERFORM public._home_usage_apply_delta(
      v_new.home_id,
      jsonb_build_object('chore_photos', v_photo_delta)
    );
  END IF;

  RETURN v_new;
END;
$$;


ALTER FUNCTION "public"."chores_update_v2"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expense_plans_generate_due_cycles"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_plan        public.expense_plans%ROWTYPE;
  v_cycle_date  date;
  v_next_date   date;

  v_cycles_done integer;
  v_cap constant integer := 31;   -- max cycles per plan per run

  v_total_cycles_done integer := 0;
  v_total_cap constant integer := 500; -- global max cycles per run
BEGIN
  FOR v_plan IN
    SELECT *
      FROM public.expense_plans
     WHERE status = 'active'
       AND next_cycle_date <= current_date
     FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_total_cycles_done >= v_total_cap;

    v_cycle_date := v_plan.next_cycle_date;
    v_next_date := v_plan.next_cycle_date;

    v_cycles_done := 0;

    WHILE v_cycle_date <= current_date AND v_cycles_done < v_cap LOOP
      EXIT WHEN v_total_cycles_done >= v_total_cap;

      PERFORM public._expense_plan_generate_cycle(v_plan.id, v_cycle_date);

      v_next_date := public._expense_plan_next_cycle_date_v2(
        v_plan.recurrence_every,
        v_plan.recurrence_unit,
        v_cycle_date
      );

      v_cycle_date  := v_next_date;
      v_cycles_done := v_cycles_done + 1;
      v_total_cycles_done := v_total_cycles_done + 1;
    END LOOP;

    UPDATE public.expense_plans
       SET next_cycle_date = v_next_date,
           updated_at      = now()
     WHERE id = v_plan.id;
  END LOOP;

  RETURN;
END;
$$;


ALTER FUNCTION "public"."expense_plans_generate_due_cycles"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expense_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "created_by_user_id" "uuid" NOT NULL,
    "split_type" "public"."expense_split_type" NOT NULL,
    "amount_cents" bigint NOT NULL,
    "description" "text" NOT NULL,
    "notes" "text",
    "recurrence_interval" "public"."recurrence_interval",
    "start_date" "date" NOT NULL,
    "next_cycle_date" "date" NOT NULL,
    "status" "public"."expense_plan_status" DEFAULT 'active'::"public"."expense_plan_status" NOT NULL,
    "terminated_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recurrence_every" integer NOT NULL,
    "recurrence_unit" "text" NOT NULL,
    CONSTRAINT "chk_expense_plans_amount_positive" CHECK (("amount_cents" > 0)),
    CONSTRAINT "chk_expense_plans_description_length" CHECK (("char_length"("btrim"("description")) <= 280)),
    CONSTRAINT "chk_expense_plans_next_cycle_not_before_start" CHECK (("next_cycle_date" >= "start_date")),
    CONSTRAINT "chk_expense_plans_notes_length" CHECK ((("notes" IS NULL) OR ("char_length"("notes") <= 2000))),
    CONSTRAINT "chk_expense_plans_recurrence_every_min" CHECK (("recurrence_every" >= 1)),
    CONSTRAINT "chk_expense_plans_recurrence_unit_allowed" CHECK (("recurrence_unit" = ANY (ARRAY['day'::"text", 'week'::"text", 'month'::"text", 'year'::"text"]))),
    CONSTRAINT "chk_expense_plans_status_timestamp" CHECK (((("status" = 'terminated'::"public"."expense_plan_status") AND ("terminated_at" IS NOT NULL)) OR (("status" = 'active'::"public"."expense_plan_status") AND ("terminated_at" IS NULL))))
);


ALTER TABLE "public"."expense_plans" OWNER TO "postgres";


COMMENT ON COLUMN "public"."expense_plans"."recurrence_every" IS 'Recurring interval count (>= 1).';



COMMENT ON COLUMN "public"."expense_plans"."recurrence_unit" IS 'Recurring interval unit (day|week|month|year).';



CREATE OR REPLACE FUNCTION "public"."expense_plans_terminate"("p_plan_id" "uuid") RETURNS "public"."expense_plans"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user  uuid := auth.uid();
  v_plan  public.expense_plans%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_plan_id IS NULL THEN
    PERFORM public.api_error('INVALID_PLAN', 'Plan id is required.', '22023');
  END IF;

  SELECT *
    INTO v_plan
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense plan not found.',
      'P0002',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  IF v_plan.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the plan creator can terminate this plan.',
      '42501'
    );
  END IF;

  PERFORM public._assert_home_member(v_plan.home_id);
  PERFORM public._assert_home_active(v_plan.home_id);

  IF v_plan.status = 'terminated' THEN
    RETURN v_plan;
  END IF;

  UPDATE public.expense_plans
     SET status        = 'terminated',
         terminated_at = now(),
         updated_at    = now()
   WHERE id = p_plan_id
  RETURNING * INTO v_plan;

  RETURN v_plan;
END;
$$;


ALTER FUNCTION "public"."expense_plans_terminate"("p_plan_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_cancel"("p_expense_id" "uuid") RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid;
  v_expense        public.expenses%ROWTYPE;
  v_home_is_active boolean;
  v_has_paid       boolean := FALSE;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EXPENSE',
      'Expense id is required.',
      '22023'
    );
  END IF;

  SELECT *
  INTO v_expense
  FROM public.expenses e
  WHERE e.id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can cancel this expense.',
      '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_expense.status = 'cancelled' THEN
    RETURN v_expense;
  END IF;

  IF v_expense.status NOT IN ('draft', 'active') THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Only draft or active expenses can be cancelled.',
      'P0003'
    );
  END IF;

  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_expense.home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_expense.home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_expense.home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  PERFORM 1
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id
  FOR UPDATE;

  SELECT EXISTS (
    SELECT 1
    FROM public.expense_splits s
    WHERE s.expense_id = v_expense.id
      AND s.status     = 'paid'
      AND s.debtor_user_id <> v_expense.created_by_user_id
  )
  INTO v_has_paid;

  IF v_has_paid THEN
    PERFORM public.api_error(
      'EXPENSE_LOCKED_AFTER_PAYMENT',
      'Expenses with paid shares cannot be cancelled.',
      'P0004',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  UPDATE public.expenses
  SET status     = 'cancelled',
      updated_at = now()
  WHERE id = v_expense.id
  RETURNING * INTO v_expense;

  PERFORM public._home_usage_apply_delta(
    v_expense.home_id,
    jsonb_build_object('active_expenses', -1)
  );

  RETURN v_expense;
END;
$$;


ALTER FUNCTION "public"."expenses_cancel"("p_expense_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint DEFAULT NULL::bigint, "p_notes" "text" DEFAULT NULL::"text", "p_split_mode" "public"."expense_split_type" DEFAULT NULL::"public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid := p_home_id;
  v_home_is_active boolean;
  v_result         public.expenses%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  IF p_split_mode IS NULL THEN
    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;

    IF p_amount_cents IS NOT NULL THEN
      IF p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
        PERFORM public.api_error(
          'INVALID_AMOUNT',
          format('Amount must be between 1 and %s cents.', v_amount_cap),
          '22023'
        );
      END IF;
    END IF;
  ELSE
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;

    IF p_amount_cents IS NULL
       OR p_amount_cents <= 0
       OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023'
      );
    END IF;
  END IF;

  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_expenses', 1)
  );

  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );
  END IF;

  INSERT INTO public.expenses (
    home_id,
    created_by_user_id,
    status,
    split_type,
    amount_cents,
    description,
    notes
  )
  VALUES (
    v_home_id,
    v_user,
    v_new_status,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), '')
  )
  RETURNING * INTO v_result;

  IF v_has_splits THEN
    INSERT INTO public.expense_splits (
      expense_id,
      debtor_user_id,
      amount_cents,
      status,
      marked_paid_at
    )
    SELECT v_result.id,
           debtor_user_id,
           amount_cents,
           CASE
             WHEN debtor_user_id = v_user
               THEN 'paid'::public.expense_share_status
             ELSE 'unpaid'::public.expense_share_status
           END,
           CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;
  END IF;

  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_expenses', 1)
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint DEFAULT NULL::bigint, "p_notes" "text" DEFAULT NULL::"text", "p_split_mode" "public"."expense_split_type" DEFAULT NULL::"public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb", "p_recurrence" "public"."recurrence_interval" DEFAULT 'none'::"public"."recurrence_interval", "p_start_date" "date" DEFAULT CURRENT_DATE) RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid := p_home_id;
  v_home_is_active boolean;

  v_result         public.expenses%ROWTYPE;
  v_plan           public.expense_plans%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;
  v_is_recurring   boolean := FALSE;

  v_recur_every    integer := NULL;
  v_recur_unit     text := NULL;

  v_split_count    integer := 0;
  v_split_sum      bigint  := 0;
  v_split_min      bigint  := 0;

  v_join_date      date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_start_date IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF p_recurrence IS NULL THEN
    PERFORM public.api_error('INVALID_RECURRENCE', 'Recurrence is required.', '22023');
  END IF;

  v_is_recurring := p_recurrence <> 'none';

  IF v_is_recurring AND p_recurrence NOT IN ('weekly', 'every_2_weeks', 'monthly', 'every_2_months', 'annual') THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence interval must be weekly, every_2_weeks, monthly, every_2_months, or annual.',
      '22023'
    );
  END IF;

  IF v_is_recurring THEN
    CASE p_recurrence
      WHEN 'weekly' THEN
        v_recur_every := 1;
        v_recur_unit := 'week';
      WHEN 'every_2_weeks' THEN
        v_recur_every := 2;
        v_recur_unit := 'week';
      WHEN 'monthly' THEN
        v_recur_every := 1;
        v_recur_unit := 'month';
      WHEN 'every_2_months' THEN
        v_recur_every := 2;
        v_recur_unit := 'month';
      WHEN 'annual' THEN
        v_recur_every := 1;
        v_recur_unit := 'year';
      ELSE
        PERFORM public.api_error(
          'INVALID_RECURRENCE',
          'Recurrence interval is not supported.',
          '22023'
        );
    END CASE;
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  -- Draft vs active based on splits presence (p_split_mode)
  IF p_split_mode IS NULL THEN
    -- Draft
    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    -- UPDATED: draft may optionally include amount, but if present must be valid.
    IF p_amount_cents IS NOT NULL THEN
      IF p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
        PERFORM public.api_error(
          'INVALID_AMOUNT',
          format('Amount must be between 1 and %s cents when provided.', v_amount_cap),
          '22023',
          jsonb_build_object('amountCents', p_amount_cents)
        );
      END IF;
    END IF;

    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;
  ELSE
    -- Activating (one-off active) OR recurring activation (plan + first cycle)
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;

    IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023'
      );
    END IF;
  END IF;

  -- Membership join date for start_date validation
  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a current member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id, 'userId', v_user)
    );
  END IF;

  IF p_start_date < v_join_date OR p_start_date < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  p_start_date
      )
    );
  END IF;

  -- Lock home (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- If activating (splits present), build/validate split buffer (also validates members + sums)
  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );

    SELECT COUNT(*)::int,
           COALESCE(SUM(amount_cents), 0),
           COALESCE(MIN(amount_cents), 0)
      INTO v_split_count, v_split_sum, v_split_min
      FROM pg_temp.expense_split_buffer;

    IF v_split_count < 2 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
    END IF;

    IF v_split_min <= 0 THEN
      PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
    END IF;

    IF v_split_sum <> p_amount_cents THEN
      PERFORM public.api_error(
        'INVALID_SPLITS_SUM',
        'Split amounts must sum to the expense amount.',
        '22023',
        jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
      );
    END IF;
  END IF;
  -- One-off path (non-recurring)
  IF NOT v_is_recurring THEN
    -- Paywall only if we are creating an ACTIVE expense (splits present)
    IF v_new_status = 'active' THEN
      PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_interval,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_home_id,
      v_user,
      v_new_status,
      v_target_split,
      p_amount_cents,                 -- may be NULL (draft) or >0
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      'none',
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    -- Create splits only for active
    IF v_has_splits THEN
      INSERT INTO public.expense_splits (
        expense_id,
        debtor_user_id,
        amount_cents,
        status,
        marked_paid_at
      )
      SELECT v_result.id,
             debtor_user_id,
             amount_cents,
             CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
                  ELSE 'unpaid'::public.expense_share_status
             END,
             CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
        FROM pg_temp.expense_split_buffer;
    END IF;

    -- Usage only for active
    IF v_new_status = 'active' THEN
      PERFORM public._home_usage_apply_delta(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    RETURN v_result;
  END IF;

  -- Recurring activation path (user-generated): enforce quota for FIRST cycle intent
  -- (cron later ignores quota by design)
  PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    split_type,
    amount_cents,
    description,
    notes,
    recurrence_interval,
    recurrence_every,
    recurrence_unit,
    start_date,
    next_cycle_date,
    status
  )
  VALUES (
    v_home_id,
    v_user,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), ''),
    p_recurrence,
    v_recur_every,
    v_recur_unit,
    p_start_date,
    public._expense_plan_next_cycle_date_v2(v_recur_every, v_recur_unit, p_start_date),
    'active'
  )
  RETURNING * INTO v_plan;

  INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
  SELECT v_plan.id, debtor_user_id, amount_cents
    FROM pg_temp.expense_split_buffer;

  -- First cycle creation increments usage inside _expense_plan_generate_cycle (canonical)
  v_result := public._expense_plan_generate_cycle(v_plan.id, p_start_date);
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_create_v2"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint DEFAULT NULL::bigint, "p_notes" "text" DEFAULT NULL::"text", "p_split_mode" "public"."expense_split_type" DEFAULT NULL::"public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb", "p_recurrence_every" integer DEFAULT NULL::integer, "p_recurrence_unit" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT CURRENT_DATE) RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid := p_home_id;
  v_home_is_active boolean;

  v_result         public.expenses%ROWTYPE;
  v_plan           public.expense_plans%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;
  v_is_recurring   boolean := FALSE;

  v_recur_every    integer := p_recurrence_every;
  v_recur_unit     text := p_recurrence_unit;

  v_split_count    integer := 0;
  v_split_sum      bigint  := 0;
  v_split_min      bigint  := 0;

  v_join_date      date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_start_date IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  v_is_recurring := p_recurrence_every IS NOT NULL;

  IF v_is_recurring THEN
    IF p_recurrence_every < 1 THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence every must be >= 1.',
        '22023'
      );
    END IF;

    IF p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence unit must be day, week, month, or year.',
        '22023'
      );
    END IF;
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  -- Draft vs active based on splits presence (p_split_mode)
  IF p_split_mode IS NULL THEN
    -- Draft
    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    -- Draft may optionally include amount, but if present must be valid.
    IF p_amount_cents IS NOT NULL THEN
      IF p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
        PERFORM public.api_error(
          'INVALID_AMOUNT',
          format('Amount must be between 1 and %s cents when provided.', v_amount_cap),
          '22023',
          jsonb_build_object('amountCents', p_amount_cents)
        );
      END IF;
    END IF;

    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;
  ELSE
    -- Activating (one-off active) OR recurring activation (plan + first cycle)
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;

    IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023'
      );
    END IF;
  END IF;

  -- Membership join date for start_date validation
  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a current member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id, 'userId', v_user)
    );
  END IF;

  IF p_start_date < v_join_date OR p_start_date < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  p_start_date
      )
    );
  END IF;

  -- Lock home (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- If activating (splits present), build/validate split buffer (also validates members + sums)
  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );

    SELECT COUNT(*)::int,
           COALESCE(SUM(amount_cents), 0),
           COALESCE(MIN(amount_cents), 0)
      INTO v_split_count, v_split_sum, v_split_min
      FROM pg_temp.expense_split_buffer;

    IF v_split_count < 2 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
    END IF;

    IF v_split_min <= 0 THEN
      PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
    END IF;

    IF v_split_sum <> p_amount_cents THEN
      PERFORM public.api_error(
        'INVALID_SPLITS_SUM',
        'Split amounts must sum to the expense amount.',
        '22023',
        jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
      );
    END IF;
  END IF;
  -- One-off path (non-recurring)
  IF NOT v_is_recurring THEN
    -- Paywall only if we are creating an ACTIVE expense (splits present)
    IF v_new_status = 'active' THEN
      PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_home_id,
      v_user,
      v_new_status,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    -- Create splits only for active
    IF v_has_splits THEN
      INSERT INTO public.expense_splits (
        expense_id,
        debtor_user_id,
        amount_cents,
        status,
        marked_paid_at
      )
      SELECT v_result.id,
             debtor_user_id,
             amount_cents,
             CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
                  ELSE 'unpaid'::public.expense_share_status
             END,
             CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
        FROM pg_temp.expense_split_buffer;
    END IF;

    -- Usage only for active
    IF v_new_status = 'active' THEN
      PERFORM public._home_usage_apply_delta(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    RETURN v_result;
  END IF;

  -- Recurring activation path (user-generated): enforce quota for FIRST cycle intent
  -- (cron later ignores quota by design)
  PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    split_type,
    amount_cents,
    description,
    notes,
    recurrence_every,
    recurrence_unit,
    start_date,
    next_cycle_date,
    status
  )
  VALUES (
    v_home_id,
    v_user,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), ''),
    v_recur_every,
    v_recur_unit,
    p_start_date,
    public._expense_plan_next_cycle_date_v2(v_recur_every, v_recur_unit, p_start_date),
    'active'
  )
  RETURNING * INTO v_plan;

  INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
  SELECT v_plan.id, debtor_user_id, amount_cents
    FROM pg_temp.expense_split_buffer;

  -- First cycle creation increments usage inside _expense_plan_generate_cycle (canonical)
  v_result := public._expense_plan_generate_cycle(v_plan.id, p_start_date);
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_create_v2"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text" DEFAULT NULL::"text", "p_split_mode" "public"."expense_split_type" DEFAULT NULL::"public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid;
  v_home_is_active boolean;

  v_existing       public.expenses%ROWTYPE;
  v_result         public.expenses%ROWTYPE;

  v_has_paid       boolean := FALSE;
  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_should_replace boolean := FALSE;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  IF p_amount_cents IS NULL
     OR p_amount_cents <= 0
     OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      format('Amount must be between 1 and %s cents.', v_amount_cap),
      '22023'
    );
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  -- Load existing expense and lock it
  SELECT *
  INTO v_existing
  FROM public.expenses e
  WHERE e.id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  v_home_id := v_existing.home_id;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can modify this expense.',
      '42501'
    );
  END IF;

  IF v_existing.status = 'cancelled' THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Cancelled expenses cannot be edited.',
      'P0003'
    );
  END IF;

  -- Lock splits rowset for this expense to avoid races
  PERFORM 1
  FROM public.expense_splits s
  WHERE s.expense_id = v_existing.id
  FOR UPDATE;

  -- Check if any share is paid
  SELECT EXISTS (
    SELECT 1
    FROM public.expense_splits s
    WHERE s.expense_id = v_existing.id
      AND s.status     = 'paid'
      AND s.debtor_user_id <> v_existing.created_by_user_id
  )
  INTO v_has_paid;

  -- Determine new status + split_type
  IF v_existing.status = 'draft' THEN
    -- New rule: editing a draft MUST choose a split and becomes active
    IF p_split_mode IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_REQUIRED',
        'Draft edits must choose a split; editing will activate the expense.',
        '22023'
      );
    END IF;

    v_target_split   := p_split_mode;
    v_new_status     := 'active';
    v_should_replace := TRUE;

  ELSE
    -- Existing is active (cancelled already rejected)
    v_new_status := 'active';

    IF v_has_paid THEN
      -- Lock amount and split once any share is paid
      IF p_split_mode IS NOT NULL THEN
        PERFORM public.api_error(
          'EXPENSE_LOCKED_AFTER_PAYMENT',
          'Split settings cannot change after a payment.',
          'P0004'
        );
      END IF;

      IF p_amount_cents <> v_existing.amount_cents THEN
        PERFORM public.api_error(
          'EXPENSE_LOCKED_AFTER_PAYMENT',
          'Amount cannot change after a payment.',
          'P0004'
        );
      END IF;

      v_target_split   := v_existing.split_type;
      v_should_replace := FALSE;
    ELSE
      -- No paid shares yet on an active expense
      IF p_split_mode IS NULL THEN
        -- Keep current split_type
        IF p_amount_cents <> v_existing.amount_cents THEN
          PERFORM public.api_error(
            'SPLIT_REQUIRED',
            'Provide split details when changing the amount of an active expense.',
            '22023'
          );
        END IF;

        v_target_split   := v_existing.split_type;
        v_should_replace := FALSE;
      ELSE
        -- Update split_type and rebuild splits
        v_target_split   := p_split_mode;
        v_should_replace := TRUE;
      END IF;
    END IF;
  END IF;

  IF v_new_status = 'active' AND v_target_split IS NULL THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Active expenses must keep a split.',
      'P0003'
    );
  END IF;

  -- Membership + home state
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  -- Prepare split buffer if we need to rebuild splits
  IF v_should_replace THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );
  END IF;

  -- Persist UPDATE
  UPDATE public.expenses
  SET amount_cents = p_amount_cents,
      description  = btrim(p_description),
      notes        = NULLIF(btrim(p_notes), ''),
      status       = v_new_status,
      split_type   = v_target_split,
      updated_at   = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_result;

  -- Rebuild splits if required
  IF v_should_replace THEN
    DELETE FROM public.expense_splits
    WHERE expense_id = v_result.id;

    INSERT INTO public.expense_splits (
      expense_id,
      debtor_user_id,
      amount_cents,
      status,
      marked_paid_at
    )
    SELECT v_result.id,
           debtor_user_id,
           amount_cents,
           CASE
             WHEN debtor_user_id = v_user
               THEN 'paid'::public.expense_share_status
             ELSE 'unpaid'::public.expense_share_status
           END,
           CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;
  END IF;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text" DEFAULT NULL::"text", "p_split_mode" "public"."expense_split_type" DEFAULT NULL::"public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb", "p_recurrence" "public"."recurrence_interval" DEFAULT NULL::"public"."recurrence_interval", "p_start_date" "date" DEFAULT NULL::"date") RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user            uuid := auth.uid();

  v_existing_unsafe public.expenses%ROWTYPE;
  v_existing        public.expenses%ROWTYPE;

  v_result          public.expenses%ROWTYPE;
  v_plan            public.expense_plans%ROWTYPE;

  v_home_is_active  boolean;

  v_target_split    public.expense_split_type;
  v_target_recur    public.recurrence_interval;
  v_target_recur_every integer;
  v_target_recur_unit  text;
  v_target_start    date;
  v_is_recurring    boolean := FALSE;

  v_split_count     integer := 0;
  v_split_sum       bigint  := 0;
  v_split_min       bigint  := 0;

  v_join_date       date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  -- Activation requires amount
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error('INVALID_AMOUNT', format('Amount must be between 1 and %s cents.', v_amount_cap), '22023');
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', format('Description must be %s characters or fewer.', v_desc_max), '22023');
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error('INVALID_NOTES', format('Notes must be %s characters or fewer.', v_notes_max), '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Splits are required. Editing an expense always activates it.', '22023');
  END IF;

  SELECT *
    INTO v_existing_unsafe
    FROM public.expenses e
   WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  -- Lock home first (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_existing_unsafe.home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_existing_unsafe.home_id));
  END IF;

  -- Lock expense row next (homes -> expenses)
  SELECT *
    INTO v_existing
    FROM public.expenses e
   WHERE e.id = p_expense_id
   FOR UPDATE;

  IF v_existing.home_id <> v_existing_unsafe.home_id THEN
    PERFORM public.api_error('CONCURRENT_MODIFICATION', 'Expense changed while editing. Please retry.', '40001', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can modify this expense.', '42501');
  END IF;

  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_existing.home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error('NOT_HOME_MEMBER', 'You are not a current member of this home.', '42501',
      jsonb_build_object('homeId', v_existing.home_id, 'userId', v_user)
    );
  END IF;

  IF v_existing.plan_id IS NOT NULL THEN
    PERFORM public.api_error('IMMUTABLE_CYCLE', 'Expenses generated from a recurring plan cannot be edited.', '42501');
  END IF;

  IF v_existing.status = 'active' THEN
    PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Active expenses cannot be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  IF v_existing.status <> 'draft' THEN
    PERFORM public.api_error('INVALID_STATE', 'Only draft expenses can be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  v_target_split := p_split_mode;
  v_target_recur := COALESCE(p_recurrence, 'none');
  v_target_start := COALESCE(p_start_date, v_existing.start_date);

  IF v_target_start IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF v_target_start < v_join_date OR v_target_start < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  v_target_start
      )
    );
  END IF;

  v_is_recurring := v_target_recur <> 'none';

  IF v_is_recurring AND v_target_recur NOT IN ('weekly', 'every_2_weeks', 'monthly', 'every_2_months', 'annual') THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence interval must be weekly, every_2_weeks, monthly, every_2_months, or annual.',
      '22023'
    );
  END IF;

  IF v_is_recurring THEN
    CASE v_target_recur
      WHEN 'weekly' THEN
        v_target_recur_every := 1;
        v_target_recur_unit := 'week';
      WHEN 'every_2_weeks' THEN
        v_target_recur_every := 2;
        v_target_recur_unit := 'week';
      WHEN 'monthly' THEN
        v_target_recur_every := 1;
        v_target_recur_unit := 'month';
      WHEN 'every_2_months' THEN
        v_target_recur_every := 2;
        v_target_recur_unit := 'month';
      WHEN 'annual' THEN
        v_target_recur_every := 1;
        v_target_recur_unit := 'year';
      ELSE
        PERFORM public.api_error(
          'INVALID_RECURRENCE',
          'Recurrence interval is not supported.',
          '22023'
        );
    END CASE;
  ELSE
    v_target_recur_every := NULL;
    v_target_recur_unit := NULL;
  END IF;

  -- Build splits (this truncates pg_temp buffer itself)
  PERFORM public._expenses_prepare_split_buffer(
    v_existing.home_id,
    v_user,
    p_amount_cents,
    v_target_split,
    p_member_ids,
    p_splits
  );

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COALESCE(MIN(amount_cents), 0)
    INTO v_split_count, v_split_sum, v_split_min
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 2 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
  END IF;

  IF v_split_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error('INVALID_SPLITS_SUM', 'Split amounts must sum to the expense amount.', '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  -- Lock order convention: expense already locked; now safe to mutate splits
  DELETE FROM public.expense_splits s
   WHERE s.expense_id = v_existing.id;
  IF v_is_recurring THEN
    -- User-generated recurring activation consumes quota for the first cycle intent
    PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

    INSERT INTO public.expense_plans (
      home_id,
      created_by_user_id,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_interval,
      recurrence_every,
      recurrence_unit,
      start_date,
      next_cycle_date,
      status
    )
    VALUES (
      v_existing.home_id,
      v_user,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_target_recur,
      v_target_recur_every,
      v_target_recur_unit,
      v_target_start,
      public._expense_plan_next_cycle_date_v2(v_target_recur_every, v_target_recur_unit, v_target_start),
      'active'
    )
    RETURNING * INTO v_plan;

    INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
    SELECT v_plan.id, debtor_user_id, amount_cents
      FROM pg_temp.expense_split_buffer;

    -- Mark original draft as converted; do NOT increment usage here
    UPDATE public.expenses
       SET status              = 'converted',
           plan_id             = v_plan.id,
           recurrence_interval = v_target_recur,
           recurrence_every    = v_target_recur_every,
           recurrence_unit     = v_target_recur_unit,
           start_date          = v_target_start,
           updated_at          = now()
     WHERE id = v_existing.id;

    -- First cycle creation increments usage inside _expense_plan_generate_cycle
    v_result := public._expense_plan_generate_cycle(v_plan.id, v_target_start);
    RETURN v_result;
  END IF;

  -- One-off activation path
  PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  UPDATE public.expenses
     SET status              = 'active',
         split_type          = v_target_split,
         amount_cents        = p_amount_cents,
         description         = btrim(p_description),
         notes               = NULLIF(btrim(p_notes), ''),
         recurrence_interval = 'none',
         recurrence_every    = NULL,
         recurrence_unit     = NULL,
         start_date          = v_target_start,
         updated_at          = now()
   WHERE id = v_existing.id
   RETURNING * INTO v_result;

  INSERT INTO public.expense_splits (
    expense_id,
    debtor_user_id,
    amount_cents,
    status,
    marked_paid_at
  )
  SELECT v_result.id,
         debtor_user_id,
         amount_cents,
         CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
              ELSE 'unpaid'::public.expense_share_status
         END,
         CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;

  PERFORM public._home_usage_apply_delta(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_edit_v2"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text" DEFAULT NULL::"text", "p_split_mode" "public"."expense_split_type" DEFAULT NULL::"public"."expense_split_type", "p_member_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_splits" "jsonb" DEFAULT NULL::"jsonb", "p_recurrence_every" integer DEFAULT NULL::integer, "p_recurrence_unit" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date") RETURNS "public"."expenses"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user            uuid := auth.uid();

  v_existing_unsafe public.expenses%ROWTYPE;
  v_existing        public.expenses%ROWTYPE;

  v_result          public.expenses%ROWTYPE;
  v_plan            public.expense_plans%ROWTYPE;

  v_home_is_active  boolean;

  v_target_split       public.expense_split_type;
  v_target_recur_every integer;
  v_target_recur_unit  text;
  v_target_start       date;
  v_is_recurring       boolean := FALSE;

  v_split_count     integer := 0;
  v_split_sum       bigint  := 0;
  v_split_min       bigint  := 0;

  v_join_date       date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  -- Activation requires amount
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error('INVALID_AMOUNT', format('Amount must be between 1 and %s cents.', v_amount_cap), '22023');
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', format('Description must be %s characters or fewer.', v_desc_max), '22023');
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error('INVALID_NOTES', format('Notes must be %s characters or fewer.', v_notes_max), '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Splits are required. Editing an expense always activates it.', '22023');
  END IF;

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  v_target_split := p_split_mode;
  v_target_recur_every := p_recurrence_every;
  v_target_recur_unit := p_recurrence_unit;
  v_target_start := COALESCE(p_start_date, NULL);

  v_is_recurring := v_target_recur_every IS NOT NULL;

  IF v_is_recurring THEN
    IF v_target_recur_every < 1 THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence every must be >= 1.',
        '22023'
      );
    END IF;

    IF v_target_recur_unit NOT IN ('day', 'week', 'month', 'year') THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence unit must be day, week, month, or year.',
        '22023'
      );
    END IF;
  END IF;

  SELECT *
    INTO v_existing_unsafe
    FROM public.expenses e
   WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  -- Lock home first (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_existing_unsafe.home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_existing_unsafe.home_id));
  END IF;

  -- Lock expense row next (homes -> expenses)
  SELECT *
    INTO v_existing
    FROM public.expenses e
   WHERE e.id = p_expense_id
   FOR UPDATE;

  IF v_existing.home_id <> v_existing_unsafe.home_id THEN
    PERFORM public.api_error('CONCURRENT_MODIFICATION', 'Expense changed while editing. Please retry.', '40001', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can modify this expense.', '42501');
  END IF;

  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_existing.home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error('NOT_HOME_MEMBER', 'You are not a current member of this home.', '42501',
      jsonb_build_object('homeId', v_existing.home_id, 'userId', v_user)
    );
  END IF;

  IF v_existing.plan_id IS NOT NULL THEN
    PERFORM public.api_error('IMMUTABLE_CYCLE', 'Expenses generated from a recurring plan cannot be edited.', '42501');
  END IF;

  IF v_existing.status = 'active' THEN
    PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Active expenses cannot be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  IF v_existing.status <> 'draft' THEN
    PERFORM public.api_error('INVALID_STATE', 'Only draft expenses can be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  v_target_start := COALESCE(p_start_date, v_existing.start_date);

  IF v_target_start IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF v_target_start < v_join_date OR v_target_start < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  v_target_start
      )
    );
  END IF;

  -- Build splits (this truncates pg_temp buffer itself)
  PERFORM public._expenses_prepare_split_buffer(
    v_existing.home_id,
    v_user,
    p_amount_cents,
    v_target_split,
    p_member_ids,
    p_splits
  );

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COALESCE(MIN(amount_cents), 0)
    INTO v_split_count, v_split_sum, v_split_min
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 2 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
  END IF;

  IF v_split_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error('INVALID_SPLITS_SUM', 'Split amounts must sum to the expense amount.', '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  -- Lock order convention: expense already locked; now safe to mutate splits
  DELETE FROM public.expense_splits s
   WHERE s.expense_id = v_existing.id;
  IF v_is_recurring THEN
    -- User-generated recurring activation consumes quota for the first cycle intent
    PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

    INSERT INTO public.expense_plans (
      home_id,
      created_by_user_id,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_every,
      recurrence_unit,
      start_date,
      next_cycle_date,
      status
    )
    VALUES (
      v_existing.home_id,
      v_user,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_target_recur_every,
      v_target_recur_unit,
      v_target_start,
      public._expense_plan_next_cycle_date_v2(v_target_recur_every, v_target_recur_unit, v_target_start),
      'active'
    )
    RETURNING * INTO v_plan;

    INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
    SELECT v_plan.id, debtor_user_id, amount_cents
      FROM pg_temp.expense_split_buffer;

    -- Mark original draft as converted; do NOT increment usage here
    UPDATE public.expenses
       SET status           = 'converted',
           plan_id          = v_plan.id,
           recurrence_every = v_target_recur_every,
           recurrence_unit  = v_target_recur_unit,
           start_date       = v_target_start,
           updated_at       = now()
     WHERE id = v_existing.id;

    -- First cycle creation increments usage inside _expense_plan_generate_cycle
    v_result := public._expense_plan_generate_cycle(v_plan.id, v_target_start);
    RETURN v_result;
  END IF;

  -- One-off activation path
  PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  UPDATE public.expenses
     SET status           = 'active',
         split_type       = v_target_split,
         amount_cents     = p_amount_cents,
         description      = btrim(p_description),
         notes            = NULLIF(btrim(p_notes), ''),
         recurrence_every = NULL,
         recurrence_unit  = NULL,
         start_date       = v_target_start,
         updated_at       = now()
   WHERE id = v_existing.id
   RETURNING * INTO v_result;

  INSERT INTO public.expense_splits (
    expense_id,
    debtor_user_id,
    amount_cents,
    status,
    marked_paid_at
  )
  SELECT v_result.id,
         debtor_user_id,
         amount_cents,
         CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
              ELSE 'unpaid'::public.expense_share_status
         END,
         CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;

  PERFORM public._home_usage_apply_delta(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_edit_v2"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_get_created_by_me"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid;
  v_result         jsonb;
  v_home_is_active boolean;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  -- Caller must be a current member of this home
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = p_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id, 'userId', v_user)
    );
  END IF;

  -- Home is fully frozen when inactive
  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = p_home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  /*
    Build list of live expenses created by the current user.
  */
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',        e.id,
               'homeId',           e.home_id,
               'createdByUserId',  e.created_by_user_id,
               'description',      e.description,
               'amountCents',      e.amount_cents,
               'status',           e.status,
               'splitType',        e.split_type,
               'createdAt',        e.created_at,
               'recurrenceEvery',  e.recurrence_every,
               'recurrenceUnit',   e.recurrence_unit,
               'startDate',        e.start_date,
               'totalShares',      COALESCE(stats.total_shares, 0)::int,
               'paidShares',       COALESCE(stats.paid_shares, 0)::int,
               'paidAmountCents',  COALESCE(stats.paid_amount_cents, 0),
               'allPaid',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN FALSE
                   ELSE COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                 END,
               'fullyPaidAt',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN NULL
                   WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                     THEN stats.max_paid_at
                   ELSE NULL
                 END
             )
             ORDER BY
               CASE
                 WHEN COALESCE(stats.total_shares, 0) = 0 THEN 0
                 WHEN COALESCE(stats.paid_shares, 0) = 0 THEN 0
                 WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                   THEN 2
                 ELSE 1
               END,
               e.created_at DESC,
               e.id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM public.expenses e
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) AS total_shares,
        COUNT(*) FILTER (WHERE s.status = 'paid') AS paid_shares,
        COALESCE(
          SUM(s.amount_cents) FILTER (WHERE s.status = 'paid'),
          0
        ) AS paid_amount_cents,
        MAX(s.marked_paid_at) FILTER (WHERE s.status = 'paid') AS max_paid_at
      FROM public.expense_splits s
      WHERE s.expense_id = e.id
    ) stats ON TRUE
  WHERE e.home_id            = p_home_id
    AND e.created_by_user_id = v_user
    AND e.status IN ('draft', 'active')
    AND NOT (
      COALESCE(stats.total_shares, 0) > 0
      AND COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
      AND e.created_at < (CURRENT_TIMESTAMP - INTERVAL '14 days')
    );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_get_created_by_me"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_get_current_owed"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user   uuid;
  v_result jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'payerUserId',     payer_user_id,
               'payerDisplay',    payer_display,
               'payerAvatarUrl',  payer_avatar_url,
               'totalOwedCents',  total_owed_cents,
               'items',           items
             )
             ORDER BY payer_display NULLS LAST, payer_user_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      e.created_by_user_id                          AS payer_user_id,
      COALESCE(p.username, p.full_name, p.email)    AS payer_display,
      a.storage_path                                AS payer_avatar_url,
      SUM(s.amount_cents)                           AS total_owed_cents,
      jsonb_agg(
        jsonb_build_object(
          'expenseId',       e.id,
          'description',     e.description,
          'amountCents',     s.amount_cents,
          'notes',           e.notes,
          'recurrenceEvery', e.recurrence_every,
          'recurrenceUnit',  e.recurrence_unit,
          'startDate',       e.start_date
        )
        ORDER BY e.created_at DESC, e.id
      ) AS items
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.profiles p
      ON p.id = e.created_by_user_id
    JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE e.home_id        = p_home_id
      AND e.status         = 'active'
      AND s.debtor_user_id = v_user
      AND s.status         = 'unpaid'
    GROUP BY e.created_by_user_id, payer_display, payer_avatar_url
  ) owed;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_get_current_owed"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_get_current_paid_to_me_by_debtor_details"("p_home_id" "uuid", "p_debtor_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user   uuid;
  v_result jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  IF p_debtor_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Debtor id is required.',
      '22023'
    );
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',       expense_id,
               'description',     description,
               'notes',           notes,
               'amountCents',     amount_cents,
               'markedPaidAt',    marked_paid_at,
               'debtorUsername',  debtor_username,
               'debtorAvatarUrl', debtor_avatar_url,
               'isOwner',         debtor_is_owner,
               'recurrenceEvery', recurrence_every,
               'recurrenceUnit',  recurrence_unit,
               'startDate',       start_date
             )
             ORDER BY marked_paid_at DESC, expense_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      e.id                                      AS expense_id,
      e.description                             AS description,
      e.notes                                   AS notes,
      s.amount_cents                            AS amount_cents,
      s.marked_paid_at                          AS marked_paid_at,
      p.username                                AS debtor_username,
      a.storage_path                            AS debtor_avatar_url,
      (h.owner_user_id = s.debtor_user_id)      AS debtor_is_owner,
      e.recurrence_every                        AS recurrence_every,
      e.recurrence_unit                         AS recurrence_unit,
      e.start_date                              AS start_date
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.homes h
      ON h.id = e.home_id
    JOIN public.profiles p
      ON p.id = s.debtor_user_id
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE e.home_id            = p_home_id
      AND e.created_by_user_id = v_user
      AND s.debtor_user_id     = p_debtor_user_id
      AND s.status             = 'paid'
      AND s.marked_paid_at     IS NOT NULL
      AND s.recipient_viewed_at IS NULL
      AND s.debtor_user_id    <> e.created_by_user_id
  ) details;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_get_current_paid_to_me_by_debtor_details"("p_home_id" "uuid", "p_debtor_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_get_current_paid_to_me_debtors"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user   uuid;
  v_result jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'debtorUserId',   debtor_user_id,
                'debtorUsername', debtor_username,
               'debtorAvatarUrl', debtor_avatar_url,
               'isOwner',        debtor_is_owner,
               'totalPaidCents', total_paid_cents,
               'unseenCount',    unseen_count,
               'latestPaidAt',   latest_paid_at
             )
             ORDER BY latest_paid_at DESC,
                      debtor_username,
                      debtor_user_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      s.debtor_user_id                                      AS debtor_user_id,
      p.username                                            AS debtor_username,
      a.storage_path                                        AS debtor_avatar_url,
      (h.owner_user_id = s.debtor_user_id)                  AS debtor_is_owner,
      SUM(s.amount_cents)                                   AS total_paid_cents,
      COUNT(*) FILTER (WHERE s.recipient_viewed_at IS NULL) AS unseen_count,
      MAX(s.marked_paid_at)                                 AS latest_paid_at
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.profiles p
      ON p.id = s.debtor_user_id
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    JOIN public.homes h
      ON h.id = e.home_id
    WHERE e.home_id            = p_home_id
      AND e.created_by_user_id = v_user
      AND s.status             = 'paid'
      AND s.marked_paid_at     IS NOT NULL
      AND s.recipient_viewed_at IS NULL
      AND s.debtor_user_id    <> e.created_by_user_id
    GROUP BY s.debtor_user_id, p.username, a.storage_path, h.owner_user_id
  ) debtors
  WHERE unseen_count > 0;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."expenses_get_current_paid_to_me_debtors"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_get_for_edit"("p_expense_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_expense            public.expenses%ROWTYPE;
  v_home_is_active     boolean;
  v_plan_status        public.expense_plan_status;
  v_splits             jsonb := '[]'::jsonb;
  v_can_edit           boolean := FALSE;
  v_edit_disabled      text := NULL;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  SELECT e.*
    INTO v_expense
    FROM public.expenses e
   WHERE e.id = p_expense_id
     AND EXISTS (
       SELECT 1
         FROM public.memberships m
        WHERE m.home_id    = e.home_id
          AND m.user_id    = v_user
          AND m.is_current = TRUE
          AND m.valid_to IS NULL
     );

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_expense.home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_expense.home_id));
  END IF;

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can edit this expense.', '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_expense.plan_id IS NOT NULL THEN
    SELECT ep.status
      INTO v_plan_status
      FROM public.expense_plans ep
     WHERE ep.id = v_expense.plan_id
     LIMIT 1;
  END IF;

  v_can_edit := (v_expense.status = 'draft'::public.expense_status);

  IF NOT v_can_edit THEN
    IF v_expense.plan_id IS NOT NULL THEN
      IF v_expense.status = 'converted'::public.expense_status THEN
        v_edit_disabled := 'CONVERTED_TO_PLAN';
      ELSE
        v_edit_disabled := 'RECURRING_CYCLE_IMMUTABLE';
      END IF;
    ELSE
      CASE v_expense.status
        WHEN 'active'::public.expense_status THEN v_edit_disabled := 'ACTIVE_IMMUTABLE';
        WHEN 'converted'::public.expense_status THEN v_edit_disabled := 'CONVERTED_TO_PLAN';
        ELSE v_edit_disabled := 'NOT_EDITABLE';
      END CASE;
    END IF;
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',    s.expense_id,
               'debtorUserId', s.debtor_user_id,
               'amountCents',  s.amount_cents,
               'status',       s.status,
               'markedPaidAt', s.marked_paid_at
             )
             ORDER BY s.debtor_user_id
           ),
           '[]'::jsonb
         )
    INTO v_splits
    FROM public.expense_splits s
   WHERE s.expense_id = v_expense.id;

  RETURN jsonb_build_object(
    'expenseId',          v_expense.id,
    'homeId',             v_expense.home_id,
    'createdByUserId',    v_expense.created_by_user_id,
    'status',             v_expense.status,
    'splitType',          v_expense.split_type,
    'amountCents',        v_expense.amount_cents,
    'description',        v_expense.description,
    'notes',              v_expense.notes,
    'createdAt',          v_expense.created_at,
    'updatedAt',          v_expense.updated_at,
    'planId',             v_expense.plan_id,
    'planStatus',         v_plan_status,
    'recurrenceEvery',    v_expense.recurrence_every,
    'recurrenceUnit',     v_expense.recurrence_unit,
    'startDate',          v_expense.start_date,
    'canEdit',            v_can_edit,
    'editDisabledReason', v_edit_disabled,
    'splits',             v_splits
  );
END;
$$;


ALTER FUNCTION "public"."expenses_get_for_edit"("p_expense_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_mark_paid_received_viewed_for_debtor"("p_home_id" "uuid", "p_debtor_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user    uuid;
  v_updated integer := 0;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  IF p_debtor_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Debtor id is required.',
      '22023'
    );
  END IF;

  UPDATE public.expense_splits s
  SET recipient_viewed_at = now()
  FROM public.expenses e
  WHERE s.expense_id          = e.id
    AND e.home_id             = p_home_id
    AND e.created_by_user_id  = v_user
    AND s.debtor_user_id      = p_debtor_user_id
    AND s.status              = 'paid'
    AND s.marked_paid_at      IS NOT NULL
    AND s.debtor_user_id     <> e.created_by_user_id
    AND s.recipient_viewed_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('updated', COALESCE(v_updated, 0));
END;
$$;


ALTER FUNCTION "public"."expenses_mark_paid_received_viewed_for_debtor"("p_home_id" "uuid", "p_debtor_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expenses_pay_my_due"("p_recipient_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user                 uuid := auth.uid();
  v_split_count          integer := 0;
  v_expense_count        integer := 0;
  v_newly_fully_paid_cnt integer := 0;
  v_touched_count        integer := 0;
  r                      record;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_recipient_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_RECIPIENT',
      'Recipient (expense creator) is required.',
      '22023'
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expenses_touched (
    expense_id uuid PRIMARY KEY
  ) ON COMMIT DROP;
  TRUNCATE TABLE pg_temp.expenses_touched;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expenses_newly_paid (
    home_id uuid NOT NULL
  ) ON COMMIT DROP;
  TRUNCATE TABLE pg_temp.expenses_newly_paid;

  WITH target_expenses AS (
    SELECT DISTINCT e.id, e.home_id
      FROM public.expense_splits s
      JOIN public.expenses e ON e.id = s.expense_id
      JOIN public.homes h ON h.id = e.home_id
      JOIN public.memberships m
        ON m.home_id    = e.home_id
       AND m.user_id    = v_user
       AND m.is_current = TRUE
       AND m.valid_to IS NULL
     WHERE s.debtor_user_id = v_user
       AND s.status = 'unpaid'
       AND e.status = 'active'
       AND e.created_by_user_id = p_recipient_user_id
       AND h.is_active = TRUE
  ),
  locked_homes AS (
    SELECT h.id
      FROM public.homes h
     WHERE h.id IN (SELECT home_id FROM target_expenses)
     ORDER BY h.id
     FOR UPDATE
  ),
  locked_expenses AS (
    SELECT e.id, e.home_id
      FROM public.expenses e
      JOIN locked_homes lh ON lh.id = e.home_id
      JOIN public.homes h ON h.id = e.home_id
     WHERE e.id IN (SELECT id FROM target_expenses)
       AND e.status = 'active'
       AND h.is_active = TRUE
     ORDER BY e.id
     FOR UPDATE
  ),
  updated AS (
    UPDATE public.expense_splits s
       SET status              = 'paid',
           marked_paid_at      = now(),
           recipient_viewed_at = NULL
     WHERE s.debtor_user_id = v_user
       AND s.expense_id IN (SELECT id FROM locked_expenses)
       AND s.status = 'unpaid'
    RETURNING s.expense_id
  ),
  aggregates AS (
    SELECT
      COUNT(*)::int AS split_count,
      COUNT(DISTINCT expense_id)::int AS expense_count
    FROM updated
  ),
  inserted AS (
    INSERT INTO pg_temp.expenses_touched (expense_id)
    SELECT DISTINCT expense_id FROM updated
    RETURNING 1
  )
  SELECT
    COALESCE(a.split_count, 0),
    COALESCE(a.expense_count, 0),
    COALESCE((SELECT COUNT(*) FROM inserted), 0)
  INTO
    v_split_count,
    v_expense_count,
    v_touched_count
  FROM aggregates a;

  WITH newly_paid AS (
    UPDATE public.expenses e
       SET fully_paid_at = now()
     WHERE e.id IN (SELECT expense_id FROM pg_temp.expenses_touched)
       AND e.fully_paid_at IS NULL
       AND NOT EXISTS (
         SELECT 1
           FROM public.expense_splits s
          WHERE s.expense_id = e.id
            AND s.status = 'unpaid'
       )
    RETURNING e.home_id
  )
  INSERT INTO pg_temp.expenses_newly_paid (home_id)
  SELECT home_id FROM newly_paid;

  SELECT COUNT(*)::int
    INTO v_newly_fully_paid_cnt
    FROM pg_temp.expenses_newly_paid;

  FOR r IN
    SELECT home_id, COUNT(*)::int AS dec_count
      FROM pg_temp.expenses_newly_paid
     GROUP BY home_id
  LOOP
    PERFORM public._home_usage_apply_delta(
      r.home_id,
      jsonb_build_object('active_expenses', -r.dec_count)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'recipientUserId',          p_recipient_user_id,
    'splitsPaid',               v_split_count,
    'expensesTouched',          v_expense_count,
    'expensesNewlyFullyPaid',   v_newly_fully_paid_cnt
  );
END;
$$;


ALTER FUNCTION "public"."expenses_pay_my_due"("p_recipient_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_plan_status"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_home_id uuid;
  v_plan    text := 'free';
BEGIN
  PERFORM public._assert_authenticated();

  -- Resolve caller's current home (one active stint enforced by uq_memberships_user_one_current)
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user_id
     AND m.is_current = TRUE
   LIMIT 1;

  -- No current home → UI should use failure fallback
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'NO_CURRENT_HOME',
      'You are not currently a member of any home.',
      '42501',
      jsonb_build_object(
        'context', 'get_plan_status',
        'reason',  'no_current_home'
      )
    );
  END IF;

  -- Guards
  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  -- Effective plan (subscription-aware)
  v_plan := COALESCE(public._home_effective_plan(v_home_id), 'free');

  RETURN jsonb_build_object(
    'plan',    v_plan,
    'home_id', v_home_id
  );
END;
$$;


ALTER FUNCTION "public"."get_plan_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gratitude_wall_list"("p_home_id" "uuid", "p_limit" integer DEFAULT 20, "p_cursor_created_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_cursor_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("post_id" "uuid", "author_user_id" "uuid", "author_username" "public"."citext", "author_avatar_url" "text", "mood" "public"."mood_scale", "message" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_limit int := LEAST(COALESCE(p_limit, 20), 100);
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  RETURN QUERY
  SELECT
    p.id,
    p.author_user_id,
    pr.username,
    a.storage_path AS author_avatar_url,
    p.mood,
    p.message,
    p.created_at
  FROM public.gratitude_wall_posts AS p
  JOIN public.profiles AS pr
    ON pr.id = p.author_user_id
  LEFT JOIN public.avatars AS a
    ON a.id = pr.avatar_id
  WHERE p.home_id = p_home_id
    -- ✅ EPHEMERAL WINDOW (last 7 days)
    AND p.created_at >= (now() - interval '7 days')
    AND (
      p_cursor_created_at IS NULL
      OR (
        p.created_at < p_cursor_created_at
        OR (
          p_cursor_id IS NOT NULL
          AND p.created_at = p_cursor_created_at
          AND p.id < p_cursor_id
        )
      )
    )
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT v_limit;
END;
$$;


ALTER FUNCTION "public"."gratitude_wall_list"("p_home_id" "uuid", "p_limit" integer, "p_cursor_created_at" timestamp with time zone, "p_cursor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gratitude_wall_mark_read"("p_home_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  INSERT INTO public.gratitude_wall_reads (home_id, user_id, last_read_at)
  VALUES (p_home_id, v_user_id, now())
  ON CONFLICT (home_id, user_id)
  DO UPDATE SET last_read_at = EXCLUDED.last_read_at;

  -- If we got here without error, we consider it a success.
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."gratitude_wall_mark_read"("p_home_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gratitude_wall_mark_read"("p_home_id" "uuid") IS 'Mark the gratitude wall as read for the current user in the specified home. Inserts or updates the last_read_at timestamp in gratitude_wall_reads. Parameters: p_home_id (home ID). Returns: boolean (TRUE on success).';



CREATE OR REPLACE FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") RETURNS TABLE("total_posts" integer, "unread_count" integer, "last_read_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_last_read_at  timestamptz;
  v_total_posts   int;
  v_unread_count  int;
BEGIN
  -- Guard: must be authenticated & an active member of the home
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Get the most recent last_read_at for this user + home
  SELECT MAX(r.last_read_at)
  INTO v_last_read_at
  FROM public.gratitude_wall_reads AS r
  WHERE r.home_id = p_home_id
    AND r.user_id = auth.uid();

  -- Count total + unread posts in a single scan
  SELECT
    COUNT(*)::int AS total_posts,
    (COUNT(*) FILTER (
       WHERE v_last_read_at IS NULL
          OR p.created_at > v_last_read_at
     ))::int AS unread_count
  INTO
    v_total_posts,
    v_unread_count
  FROM public.gratitude_wall_posts AS p
  WHERE p.home_id   = p_home_id
    -- Keep stats simple: count all posts for the home. If soft-delete is added later,
    -- reintroduce an is_active predicate alongside the column.
    ;

  total_posts  := COALESCE(v_total_posts, 0);
  unread_count := COALESCE(v_unread_count, 0);
  last_read_at := v_last_read_at;

  RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") IS 'Returns total, unread count, and last_read_at for the current user''s gratitude wall in the given home.';



CREATE OR REPLACE FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") RETURNS TABLE("has_unread" boolean, "last_read_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id          uuid := auth.uid();
  v_latest_created_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT r.last_read_at
  INTO last_read_at
  FROM public.gratitude_wall_reads r
  WHERE r.home_id = p_home_id
    AND r.user_id = v_user_id
  LIMIT 1;

  SELECT p.created_at
  INTO v_latest_created_at
  FROM public.gratitude_wall_posts p
  WHERE p.home_id = p_home_id
    AND p.author_user_id <> v_user_id  
  ORDER BY p.created_at DESC, p.id DESC
  LIMIT 1;

  has_unread :=
    CASE
      WHEN v_latest_created_at IS NULL THEN FALSE
      WHEN last_read_at IS NULL THEN TRUE
      ELSE v_latest_created_at > last_read_at
    END;

  RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") IS 'Returns whether the current user has unread gratitude wall posts for the given home, and the last_read_at timestamp.';



CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  default_avatar uuid;
  v_username     public.citext;  -- 👈 qualify the type
BEGIN
  SELECT id INTO default_avatar
  FROM public.avatars
  ORDER BY created_at ASC
  LIMIT 1;

  IF default_avatar IS NULL THEN
    RAISE EXCEPTION 'handle_new_user: no default avatar found';
  END IF;

  v_username := public._gen_unique_username(NEW.email, NEW.id);

  INSERT INTO public.profiles (id, email, full_name, avatar_id, username)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NULL),
    default_avatar,
    v_username
  )
  ON CONFLICT (id) DO UPDATE
    SET
      email     = COALESCE(public.profiles.email, EXCLUDED.email),
      full_name = COALESCE(public.profiles.full_name, EXCLUDED.full_name),
      avatar_id = COALESCE(public.profiles.avatar_id, EXCLUDED.avatar_id),
      username  = COALESCE(public.profiles.username, EXCLUDED.username);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_new_user"() IS 'Trigger function to create a default profile row for each new auth user with a default avatar.';



CREATE OR REPLACE FUNCTION "public"."home_assignees_list"("p_home_id" "uuid") RETURNS TABLE("user_id" "uuid", "full_name" "text", "email" "text", "avatar_storage_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  -- 1️⃣ Require auth
  PERFORM public._assert_authenticated();

  -- 2️⃣ Ensure caller actually belongs to this home
  PERFORM public._assert_home_member(p_home_id);

  -- 3️⃣ Return all *active* members of this home as potential assignees
  RETURN QUERY
  SELECT
    m.user_id,
    p.full_name,
    p.email,
    a.storage_path
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE        -- or your "still in house" condition
  ORDER BY COALESCE(p.full_name, p.email);
END;
$$;


ALTER FUNCTION "public"."home_assignees_list"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."home_entitlements_refresh"("_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_has_valid  boolean;
  v_latest_exp timestamptz;
BEGIN
  SELECT
    EXISTS (
      SELECT 1
        FROM public.user_subscriptions us
       WHERE us.home_id = _home_id
         AND us.status IN ('active', 'cancelled')
         AND (us.current_period_end_at IS NULL OR us.current_period_end_at > now())
    ) AS has_valid_subscription,
    MAX(us.current_period_end_at) AS latest_expiry
  INTO v_has_valid, v_latest_exp
  FROM public.user_subscriptions us
  WHERE us.home_id = _home_id;

  INSERT INTO public.home_entitlements AS he (home_id, plan, expires_at)
  VALUES (
    _home_id,
    CASE WHEN v_has_valid THEN 'premium' ELSE 'free' END,
    CASE WHEN v_has_valid THEN v_latest_exp ELSE NULL END
  )
  ON CONFLICT (home_id) DO UPDATE
  SET
    plan       = EXCLUDED.plan,
    expires_at = EXCLUDED.expires_at,
    updated_at = now();

  -- If upgraded to premium, attempt to process pending member-cap joins
  IF v_has_valid THEN
    PERFORM public.member_cap_process_pending(_home_id);
  END IF;
END;
$$;


ALTER FUNCTION "public"."home_entitlements_refresh"("_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."home_mood_feedback_counters_inc"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_row       public.home_mood_feedback_counters%ROWTYPE;
  v_milestone integer;
  v_step      constant integer := 13; -- feedbacks per NPS milestone
BEGIN
  -- Ensure caller is authenticated; membership checks already happen in mood_submit
  PERFORM public._assert_authenticated();

  -- Upsert basic counters
  INSERT INTO public.home_mood_feedback_counters AS c (
    home_id,
    user_id,
    feedback_count,
    first_feedback_at,
    last_feedback_at
  )
  VALUES (
    NEW.home_id,
    NEW.user_id,
    1,
    NEW.created_at,
    NEW.created_at
  )
  ON CONFLICT (home_id, user_id)
  DO UPDATE
    SET feedback_count   = c.feedback_count + 1,
        last_feedback_at = NEW.created_at;

  -- Fetch updated row
  SELECT *
  INTO v_row
  FROM public.home_mood_feedback_counters
  WHERE home_id = NEW.home_id
    AND user_id = NEW.user_id;

  -- Compute current milestone and decide if NPS is required.
  -- Example: feedback_count = 13 -> milestone = 13
  --          feedback_count = 20 -> milestone = 13
  --          feedback_count = 26 -> milestone = 26
  IF v_row.feedback_count >= v_step THEN
    v_milestone := (v_row.feedback_count / v_step) * v_step;

    IF v_milestone > 0
       AND v_milestone > v_row.last_nps_feedback_count
    THEN
      UPDATE public.home_mood_feedback_counters
      SET nps_required = TRUE
      WHERE home_id = NEW.home_id
        AND user_id = NEW.user_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."home_mood_feedback_counters_inc"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_mood_feedback_counters_inc"() IS 'Trigger to maintain per-home per-user feedback counters and mark when NPS is required.';



CREATE OR REPLACE FUNCTION "public"."home_nps_get_status"("p_home_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_required boolean;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT c.nps_required
  INTO v_required
  FROM public.home_mood_feedback_counters c
  WHERE c.home_id = p_home_id
    AND c.user_id = v_user_id;

  RETURN COALESCE(v_required, FALSE);
END;
$$;


ALTER FUNCTION "public"."home_nps_get_status"("p_home_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_nps_get_status"("p_home_id" "uuid") IS 'Returns TRUE if an NPS response is currently required for this user in the given home, otherwise FALSE.';



CREATE TABLE IF NOT EXISTS "public"."home_nps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "score" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nps_feedback_count" integer NOT NULL,
    CONSTRAINT "home_nps_score_check" CHECK ((("score" >= 0) AND ("score" <= 10)))
);


ALTER TABLE "public"."home_nps" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_nps" IS 'History of NPS responses per home and user, tied to feedback milestones.';



COMMENT ON COLUMN "public"."home_nps"."nps_feedback_count" IS 'Value of feedback_count at the time this NPS was submitted (e.g. 13, 26, 39...).';



CREATE OR REPLACE FUNCTION "public"."home_nps_submit"("p_home_id" "uuid", "p_score" integer) RETURNS "public"."home_nps"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id  uuid := auth.uid();
  v_counters public.home_mood_feedback_counters%ROWTYPE;
  v_row      public.home_nps%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Validate score
  PERFORM public.api_assert(
    p_score BETWEEN 0 AND 10,
    'INVALID_NPS_SCORE',
    'NPS score must be between 0 and 10.',
    '22023'
  );

  -- Get counters row
  SELECT *
  INTO v_counters
  FROM public.home_mood_feedback_counters
  WHERE home_id = p_home_id
    AND user_id = v_user_id;

  -- Must have some feedback history
  PERFORM public.api_assert(
    v_counters.home_id IS NOT NULL,
    'NPS_NOT_ELIGIBLE',
    'NPS cannot be submitted before any mood feedback.',
    '22023'
  );

  -- NPS must actually be required right now
  PERFORM public.api_assert(
    v_counters.nps_required IS TRUE,
    'NPS_NOT_REQUIRED',
    'NPS is not currently required.',
    '22023'
  );

  INSERT INTO public.home_nps (
    home_id,
    user_id,
    score,
    nps_feedback_count
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_score,
    v_counters.feedback_count
  )
  RETURNING * INTO v_row;

  -- Update counters with latest NPS info and clear the requirement
  UPDATE public.home_mood_feedback_counters
  SET last_nps_at             = v_row.created_at,
      last_nps_score          = v_row.score,
      last_nps_feedback_count = v_row.nps_feedback_count,
      nps_required            = FALSE
  WHERE home_id = p_home_id
    AND user_id = v_user_id;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."home_nps_submit"("p_home_id" "uuid", "p_score" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_nps_submit"("p_home_id" "uuid", "p_score" integer) IS 'Submit an NPS response (0–10) for a home when NPS is required. Uses current feedback_count as nps_feedback_count, records the score, and clears nps_required in home_mood_feedback_counters.';



CREATE OR REPLACE FUNCTION "public"."homes_create_with_invite"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home public.homes;
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- 1) Create home
  INSERT INTO public.homes (owner_user_id)
  VALUES (v_user)
  RETURNING * INTO v_home;

  -- 2) Create owner membership (first active member)
  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  -- 3) Increment usage counters: active_members +1
  PERFORM public._home_usage_apply_delta(
    v_home.id,
    jsonb_build_object('active_members', 1)
  );

  -- 4) Set entitlements (default: free)
  INSERT INTO public.home_entitlements (home_id, plan, expires_at)
  VALUES (v_home.id, 'free', NULL);

  -- 5) Create first invite (one active per home enforced by partial index)
  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING * INTO v_inv;

  IF NOT FOUND THEN
    SELECT *
    INTO v_inv
    FROM public.invites
    WHERE home_id = v_home.id
      AND revoked_at IS NULL
    LIMIT 1;
  END IF;

  -- 6) Attach existing subscription to this home (if any)
  PERFORM public._home_attach_subscription_to_home(v_user, v_home.id);

  -- 7) Return result
  RETURN jsonb_build_object(
    'home', jsonb_build_object(
      'id',            v_home.id,
      'owner_user_id', v_home.owner_user_id,
      'created_at',    v_home.created_at
    ),
    'invite', jsonb_build_object(
      'id',         v_inv.id,
      'home_id',    v_inv.home_id,
      'code',       v_inv.code,
      'created_at', v_inv.created_at
    )
  );
END;
$$;


ALTER FUNCTION "public"."homes_create_with_invite"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."homes_join"("p_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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


ALTER FUNCTION "public"."homes_join"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."homes_leave"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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
   WHERE user_id = v_user
     AND home_id = p_home_id
     AND m.is_current
  RETURNING 1 INTO v_left_rows;

  IF v_left_rows IS NULL THEN
    PERFORM public.api_error(
      'STATE_CHANGED_RETRY',
      'Membership state changed; retry.',
      '40001'
    );
  END IF;

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
      'home_id',            p_home_id,
      'role_before',        v_role_before,
      'members_remaining',  v_members_left,
      'home_deactivated',   v_deactivated
    )
  );
END;
$$;


ALTER FUNCTION "public"."homes_leave"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."homes_transfer_owner"("p_home_id" "uuid", "p_new_owner_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user              uuid := auth.uid();
  v_owner_row_ended   integer;
  v_new_owner_ended   integer;
BEGIN
  PERFORM public._assert_authenticated();

  --------------------------------------------------------------------
  -- 1️⃣ Validate new owner input
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    p_new_owner_id IS NOT NULL AND p_new_owner_id <> v_user,
    'INVALID_NEW_OWNER',
    'Please choose a different member to transfer ownership to.',
    '22023',
    jsonb_build_object('home_id', p_home_id, 'new_owner_id', p_new_owner_id)
  );

  --------------------------------------------------------------------
  -- 2️⃣ Verify caller is current owner of an active home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id   = v_user
        AND m.home_id   = p_home_id
        AND m.role      = 'owner'
        AND m.is_current = TRUE
        AND h.is_active = TRUE
    ),
    'FORBIDDEN',
    'Only the current home owner can transfer ownership.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  --------------------------------------------------------------------
  -- 3️⃣ Verify new owner is an active member of the same home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id    = p_new_owner_id
        AND m.home_id    = p_home_id
        AND m.is_current = TRUE
        AND h.is_active  = TRUE
    ),
    'NEW_OWNER_NOT_MEMBER',
    'The selected user must already be a current member of this household.',
    'P0001',
    jsonb_build_object('home_id', p_home_id, 'new_owner_id', p_new_owner_id)
  );

  --------------------------------------------------------------------
  -- 4️⃣ (Optional but recommended) serialize with leave/join
  --------------------------------------------------------------------
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  --------------------------------------------------------------------
  -- 5️⃣ End current owner stint (role = owner)
  --     We *do* close the owner stint for history...
  --------------------------------------------------------------------
  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
   WHERE m.user_id   = v_user
     AND m.home_id   = p_home_id
     AND m.role      = 'owner'
     AND m.is_current = TRUE
  RETURNING 1 INTO v_owner_row_ended;

  PERFORM public.api_assert(
    v_owner_row_ended = 1,
    'STATE_CHANGED_RETRY',
    'Ownership state changed during transfer; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'user_id', v_user)
  );

  --------------------------------------------------------------------
  -- 6️⃣ Insert new MEMBER stint for the old owner
  --     👉 This is the bit you were missing.
  --------------------------------------------------------------------
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, p_home_id, 'member', now(), NULL);

  --------------------------------------------------------------------
  -- 7️⃣ End new owner’s current MEMBER stint
  --------------------------------------------------------------------
  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
   WHERE m.user_id    = p_new_owner_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
  RETURNING 1 INTO v_new_owner_ended;

  PERFORM public.api_assert(
    v_new_owner_ended = 1,
    'STATE_CHANGED_RETRY',
    'New owner membership state changed during transfer; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'new_owner_id', p_new_owner_id)
  );

  --------------------------------------------------------------------
  -- 8️⃣ Insert new OWNER stint for the new owner
  --------------------------------------------------------------------
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (p_new_owner_id, p_home_id, 'owner', now(), NULL);


  --------------------------------------------------------------------
  -- 9️⃣ Update homes.owner_user_id
  --------------------------------------------------------------------
  UPDATE public.homes h
     SET owner_user_id = p_new_owner_id,
         updated_at    = now()
   WHERE h.id           = p_home_id;

  --------------------------------------------------------------------
  -- 9️⃣ Return success response
  --------------------------------------------------------------------
  RETURN jsonb_build_object(
    'status',       'success',
    'code',         'ownership_transferred',
    'message',      'Ownership has been successfully transferred.',
    'home_id',      p_home_id,
    'new_owner_id', p_new_owner_id
  );
END;
$$;


ALTER FUNCTION "public"."homes_transfer_owner"("p_home_id" "uuid", "p_new_owner_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."house_pulse_weekly" (
    "home_id" "uuid" NOT NULL,
    "iso_week_year" integer NOT NULL,
    "iso_week" integer NOT NULL,
    "contract_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "member_count" integer NOT NULL,
    "reflection_count" integer NOT NULL,
    "weather_display" "public"."mood_scale",
    "care_present" boolean NOT NULL,
    "friction_present" boolean NOT NULL,
    "complexity_present" boolean DEFAULT false NOT NULL,
    "pulse_state" "public"."house_pulse_state" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_house_pulse_weekly_contract_version_nonempty" CHECK (("btrim"("contract_version") <> ''::"text")),
    CONSTRAINT "chk_house_pulse_weekly_iso_week" CHECK ((("iso_week" >= 1) AND ("iso_week" <= 53))),
    CONSTRAINT "chk_house_pulse_weekly_iso_year" CHECK ((("iso_week_year" >= 2000) AND ("iso_week_year" <= 2100))),
    CONSTRAINT "chk_house_pulse_weekly_member_count" CHECK (("member_count" >= 0)),
    CONSTRAINT "chk_house_pulse_weekly_reflection_count" CHECK (("reflection_count" >= 0))
);


ALTER TABLE "public"."house_pulse_weekly" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."house_pulse_compute_week"("p_home_id" "uuid", "p_iso_week_year" integer DEFAULT NULL::integer, "p_iso_week" integer DEFAULT NULL::integer, "p_contract_version" "text" DEFAULT 'v1'::"text") RETURNS "public"."house_pulse_weekly"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_now timestamptz := now();
  v_iso_week int;
  v_iso_week_year int;

  v_member_count int := 0;
  v_reflection_count int := 0;

  v_light_count int := 0;
  v_neutral_count int := 0;
  v_heavy_count int := 0;

  v_distinct_participants int := 0;
  v_has_any_comment boolean := false;

  v_heavy_ratio numeric := 0;
  v_light_ratio numeric := 0;
  v_participation_ratio numeric := 0;

  v_has_thunderstorm boolean := false;
  v_has_complexity_note boolean := false; -- heavy mood + comment
  v_has_weekly_personal_mention boolean := false;

  v_care_present boolean := false;
  v_friction_present boolean := false;
  v_complexity_present boolean := false;

  v_weather_mode public.mood_scale;
  v_pulse_state public.house_pulse_state;
  v_weather_for_display public.mood_scale;

  v_row public.house_pulse_weekly;

  v_missing_label boolean := false;
  v_cv text := COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1');

  v_required_reflections int := 0;
BEGIN
  PERFORM public._assert_authenticated();

  -- Home checks
  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Resolve week (UTC ISO week/year) using v_now for consistency
  SELECT
    COALESCE(
      p_iso_week,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IW')::int
    ),
    COALESCE(
      p_iso_week_year,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IYYY')::int
    )
  INTO v_iso_week, v_iso_week_year;

  PERFORM public.api_assert(
    p_iso_week IS NULL OR (p_iso_week BETWEEN 1 AND 53),
    'INVALID_ARGUMENT',
    'iso_week must be between 1 and 53.',
    '22023'
  );

  PERFORM public.api_assert(
    p_iso_week_year IS NULL OR (p_iso_week_year BETWEEN 2000 AND 2100),
    'INVALID_ARGUMENT',
    'iso_week_year is out of supported range.',
    '22023'
  );

  -- Advisory lock: serialize compute per (home, week, contract) using bigint hash
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      format('house_pulse:%s:%s:%s:%s', p_home_id::text, v_iso_week_year::text, v_iso_week::text, v_cv),
      0
    )
  );

  -- Current member count (current home composition)
  SELECT COUNT(*)
    INTO v_member_count
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current = TRUE;

  -- Consolidated aggregation for week entries (from CURRENT members)
  WITH current_members AS (
    SELECT m.user_id
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE
  ),
  week_entries AS (
    SELECT e.id, e.user_id, e.mood, e.comment
    FROM public.home_mood_entries e
    JOIN current_members cm ON cm.user_id = e.user_id
    WHERE e.home_id = p_home_id
      AND e.iso_week_year = v_iso_week_year
      AND e.iso_week = v_iso_week
  ),
  counts AS (
    SELECT
      we.mood,
      COUNT(*) AS cnt,
      CASE we.mood
        WHEN 'thunderstorm' THEN 5
        WHEN 'rainy' THEN 4
        WHEN 'cloudy' THEN 3
        WHEN 'partially_sunny' THEN 2
        WHEN 'sunny' THEN 1
        ELSE 0
      END AS weight
    FROM week_entries we
    GROUP BY we.mood
  ),
  mention_presence AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.gratitude_wall_personal_items i
      JOIN week_entries we ON we.id = i.source_entry_id
      WHERE i.home_id = p_home_id
        AND i.author_user_id <> i.recipient_user_id
    ) AS has_weekly_personal_mention
  )
  SELECT
    -- bucket counts
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood IN ('sunny','partially_sunny')), 0) AS light_count,
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood = 'cloudy'), 0) AS neutral_count,
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood IN ('rainy','thunderstorm')), 0) AS heavy_count,
    COALESCE(SUM(c.cnt), 0) AS total_count,

    -- flags
    COALESCE(SUM(c.cnt) FILTER (WHERE c.mood = 'thunderstorm'), 0) > 0 AS has_thunderstorm,

    -- deterministic mode mood (stable tie-break)
    (
      SELECT c2.mood
      FROM counts c2
      ORDER BY c2.cnt DESC, c2.weight DESC, c2.mood ASC
      LIMIT 1
    ) AS weather_mode,

    -- complexity note: ONLY count non-empty comments on rainy/thunderstorm
    EXISTS (
      SELECT 1
      FROM week_entries we2
      WHERE we2.mood IN ('rainy','thunderstorm')
        AND NULLIF(btrim(we2.comment), '') IS NOT NULL
    ) AS has_complexity_note,

    -- care amplifier: personal mention exists for that week
    (SELECT mp.has_weekly_personal_mention FROM mention_presence mp) AS has_weekly_personal_mention,

    -- additional care signals
    (SELECT COUNT(DISTINCT we3.user_id) FROM week_entries we3) AS distinct_participants,
    EXISTS (
      SELECT 1 FROM week_entries we4
      WHERE NULLIF(btrim(we4.comment), '') IS NOT NULL
    ) AS has_any_comment
  FROM counts c
  INTO
    v_light_count, v_neutral_count, v_heavy_count,
    v_reflection_count,
    v_has_thunderstorm,
    v_weather_mode,
    v_has_complexity_note,
    v_has_weekly_personal_mention,
    v_distinct_participants,
    v_has_any_comment;

  IF v_reflection_count > 0 THEN
    v_heavy_ratio := v_heavy_count::numeric / v_reflection_count::numeric;
    v_light_ratio := v_light_count::numeric / v_reflection_count::numeric;
  END IF;

  IF v_member_count > 0 THEN
    v_participation_ratio := v_reflection_count::numeric / v_member_count::numeric;
  END IF;

  -- Softer FORMING gate:
  -- required reflections scales with home size but caps at 4, floor at 2 (unless solo home)
  v_required_reflections :=
    CASE
      WHEN v_member_count <= 1 THEN 1
      ELSE LEAST(4, GREATEST(2, CEIL(v_member_count * 0.35)::int))
    END;

  -- complexity_present is separate (no longer drives friction)
  v_complexity_present := v_has_complexity_note;

  -- care_present requires participation and at least one care signal:
  -- (>=25% light) OR (weekly personal mention) OR (any comment) OR (enough distinct participants)
  v_care_present :=
    v_reflection_count > 0 AND (
      v_light_ratio >= 0.25
      OR v_has_weekly_personal_mention
      OR v_has_any_comment
      OR (v_member_count >= 2 AND v_distinct_participants >= LEAST(3, CEIL(v_member_count * 0.50)::int))
    );

  -- friction_present is tension/conflict risk only:
  v_friction_present :=
    v_has_thunderstorm
    OR (v_reflection_count > 0 AND v_heavy_ratio >= 0.30);

  -- Participation gate (FORMING is "insufficient signal")
  v_pulse_state := NULL;

  IF v_member_count <= 0 THEN
    v_pulse_state := 'forming';
  ELSIF v_reflection_count < v_required_reflections THEN
    v_pulse_state := 'forming';
  ELSIF v_participation_ratio < 0.30 THEN
    v_pulse_state := 'forming';
  END IF;

  -- If not forming, classify
  IF v_pulse_state IS NULL THEN
    IF v_has_thunderstorm THEN
      v_pulse_state := 'thunderstorm';

    ELSIF v_reflection_count > 0 AND v_heavy_ratio >= 0.30 THEN
      IF v_care_present THEN
        v_pulse_state := 'rainy_supported';
      ELSE
        v_pulse_state := 'rainy_unsupported';
      END IF;

    ELSIF v_reflection_count > 0 AND v_light_ratio >= 0.60 AND v_care_present AND NOT v_friction_present THEN
      v_pulse_state := 'sunny_calm';

    ELSIF v_reflection_count > 0 AND v_light_ratio >= 0.40 AND v_care_present AND v_friction_present THEN
      v_pulse_state := 'sunny_bumpy';

    ELSIF v_reflection_count > 0 AND v_weather_mode = 'partially_sunny' AND v_care_present THEN
      v_pulse_state := 'partly_supported';

    ELSIF v_reflection_count > 0 AND v_weather_mode = 'cloudy' THEN
      IF v_friction_present THEN
        v_pulse_state := 'cloudy_tense';
      ELSE
        v_pulse_state := 'cloudy_steady';
      END IF;

    ELSE
      IF v_friction_present THEN
        v_pulse_state := 'cloudy_tense';
      ELSE
        v_pulse_state := 'cloudy_steady';
      END IF;
    END IF;
  END IF;

  -- Assert mapping exists (table-driven)
  SELECT NOT EXISTS (
    SELECT 1
    FROM public.house_pulse_labels l
    WHERE l.contract_version = v_cv
      AND l.pulse_state = v_pulse_state
      AND l.is_active = TRUE
  )
  INTO v_missing_label;

  PERFORM public.api_assert(
    v_missing_label = FALSE,
    'PULSE_LABEL_MISSING',
    'Missing house_pulse_labels mapping for contract/state.',
    'P0001',
    jsonb_build_object('contractVersion', v_cv, 'pulseState', v_pulse_state)
  );

  -- Optional display weather token
  v_weather_for_display := CASE v_pulse_state
    WHEN 'forming' THEN NULL
    WHEN 'thunderstorm' THEN 'thunderstorm'
    WHEN 'rainy_supported' THEN 'rainy'
    WHEN 'rainy_unsupported' THEN 'rainy'
    WHEN 'partly_supported' THEN 'partially_sunny'
    WHEN 'sunny_calm' THEN 'sunny'
    WHEN 'sunny_bumpy' THEN 'sunny'
    ELSE 'cloudy'
  END;

  INSERT INTO public.house_pulse_weekly (
    home_id, iso_week_year, iso_week, contract_version,
    member_count, reflection_count, weather_display,
    care_present, friction_present, complexity_present,
    pulse_state,
    computed_at
  )
  VALUES (
    p_home_id, v_iso_week_year, v_iso_week, v_cv,
    COALESCE(v_member_count, 0), COALESCE(v_reflection_count, 0), v_weather_for_display,
    COALESCE(v_care_present, FALSE), COALESCE(v_friction_present, FALSE), COALESCE(v_complexity_present, FALSE),
    v_pulse_state,
    v_now
  )
  ON CONFLICT (home_id, iso_week_year, iso_week, contract_version)
  DO UPDATE SET
    member_count = EXCLUDED.member_count,
    reflection_count = EXCLUDED.reflection_count,
    weather_display = EXCLUDED.weather_display,
    care_present = EXCLUDED.care_present,
    friction_present = EXCLUDED.friction_present,
    complexity_present = EXCLUDED.complexity_present,
    pulse_state = EXCLUDED.pulse_state,
    computed_at = EXCLUDED.computed_at
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."house_pulse_compute_week"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."house_pulse_label_get_v1"("p_pulse_state" "public"."house_pulse_state", "p_contract_version" "text" DEFAULT 'v1'::"text") RETURNS TABLE("contract_version" "text", "pulse_state" "public"."house_pulse_state", "title_key" "text", "summary_key" "text", "image_key" "text", "ui" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_pulse_state IS NOT NULL,
    'INVALID_ARGUMENT',
    'pulse_state is required.',
    '22023'
  );

  RETURN QUERY
  SELECT
    l.contract_version,
    l.pulse_state,
    l.title_key,
    l.summary_key,
    l.image_key,
    l.ui
  FROM public.house_pulse_labels l
  WHERE l.contract_version = COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1')
    AND l.pulse_state = p_pulse_state
    AND l.is_active = TRUE;
END;
$$;


ALTER FUNCTION "public"."house_pulse_label_get_v1"("p_pulse_state" "public"."house_pulse_state", "p_contract_version" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."house_pulse_reads" (
    "home_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "iso_week_year" integer NOT NULL,
    "iso_week" integer NOT NULL,
    "contract_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "last_seen_pulse_state" "public"."house_pulse_state" NOT NULL,
    "last_seen_computed_at" timestamp with time zone NOT NULL,
    "seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_house_pulse_reads_contract_version_nonempty" CHECK (("btrim"("contract_version") <> ''::"text")),
    CONSTRAINT "chk_house_pulse_reads_iso_week" CHECK ((("iso_week" >= 1) AND ("iso_week" <= 53))),
    CONSTRAINT "chk_house_pulse_reads_iso_year" CHECK ((("iso_week_year" >= 2000) AND ("iso_week_year" <= 2100)))
);


ALTER TABLE "public"."house_pulse_reads" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."house_pulse_mark_seen"("p_home_id" "uuid", "p_iso_week_year" integer DEFAULT NULL::integer, "p_iso_week" integer DEFAULT NULL::integer, "p_contract_version" "text" DEFAULT 'v1'::"text") RETURNS "public"."house_pulse_reads"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid;
  v_now timestamptz := now();
  v_iso_week int;
  v_iso_week_year int;
  v_cv text := COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1');

  v_payload jsonb;
  v_pulse jsonb;
  v_row public.house_pulse_reads;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT
    COALESCE(
      p_iso_week,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IW')::int
    ),
    COALESCE(
      p_iso_week_year,
      to_char((v_now AT TIME ZONE 'UTC')::date, 'IYYY')::int
    )
  INTO v_iso_week, v_iso_week_year;

  -- single-call friendly: get-or-compute payload (jsonb with pulse/label/seen)
  v_payload := public.house_pulse_weekly_get(p_home_id, v_iso_week_year, v_iso_week, v_cv);
  v_pulse := v_payload->'pulse';

  INSERT INTO public.house_pulse_reads (
    home_id, user_id, iso_week_year, iso_week, contract_version,
    last_seen_pulse_state, last_seen_computed_at, seen_at
  )
  VALUES (
    p_home_id, v_user, v_iso_week_year, v_iso_week, v_cv,
    (v_pulse->>'pulse_state')::public.house_pulse_state,
    (v_pulse->>'computed_at')::timestamptz,
    v_now
  )
  ON CONFLICT (home_id, user_id, iso_week_year, iso_week, contract_version)
  DO UPDATE SET
    last_seen_pulse_state = EXCLUDED.last_seen_pulse_state,
    last_seen_computed_at = EXCLUDED.last_seen_computed_at,
    seen_at = EXCLUDED.seen_at
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."house_pulse_mark_seen"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."house_pulse_weekly_get"("p_home_id" "uuid", "p_iso_week_year" integer DEFAULT NULL::integer, "p_iso_week" integer DEFAULT NULL::integer, "p_contract_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_now timestamptz := now();
  v_iso_week int;
  v_iso_week_year int;

  v_cv text := COALESCE(NULLIF(btrim(p_contract_version), ''), 'v1');

  v_row public.house_pulse_weekly;
  v_label public.house_pulse_labels;
  v_seen public.house_pulse_reads;

  v_latest_entry_at timestamptz;
  v_needs_recompute boolean := false;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Fix 3: canonical iso week/year (UTC ISO)
  SELECT
    COALESCE(p_iso_week_year, w.iso_week_year),
    COALESCE(p_iso_week, w.iso_week)
  INTO v_iso_week_year, v_iso_week
  FROM public._iso_week_utc(v_now) w;

  PERFORM public.api_assert(
    p_iso_week IS NULL OR (p_iso_week BETWEEN 1 AND 53),
    'INVALID_ARGUMENT',
    'iso_week must be between 1 and 53.',
    '22023'
  );

  PERFORM public.api_assert(
    p_iso_week_year IS NULL OR (p_iso_week_year BETWEEN 2000 AND 2100),
    'INVALID_ARGUMENT',
    'iso_week_year is out of supported range.',
    '22023'
  );

  SELECT *
    INTO v_row
    FROM public.house_pulse_weekly w
   WHERE w.home_id = p_home_id
     AND w.iso_week_year = v_iso_week_year
     AND w.iso_week = v_iso_week
     AND w.contract_version = v_cv;

  IF FOUND THEN
    -- Fix 1: determine whether new relevant entries exist since computed_at
    -- Only consider entries authored by CURRENT members (matches compute semantics)
    SELECT MAX(e.created_at)
      INTO v_latest_entry_at
      FROM public.home_mood_entries e
      JOIN public.memberships m
        ON m.home_id = p_home_id
       AND m.user_id = e.user_id
       AND m.is_current = TRUE
     WHERE e.home_id = p_home_id
       AND e.iso_week_year = v_iso_week_year
       AND e.iso_week = v_iso_week;

    v_needs_recompute :=
      (v_latest_entry_at IS NOT NULL)
      AND (v_latest_entry_at > v_row.computed_at);

    IF v_needs_recompute THEN
      v_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, v_cv);
    END IF;

    SELECT *
      INTO v_seen
      FROM public.house_pulse_reads r
     WHERE r.home_id = p_home_id
       AND r.user_id = auth.uid()
       AND r.iso_week_year = v_iso_week_year
       AND r.iso_week = v_iso_week
       AND r.contract_version = v_cv;

    SELECT *
      INTO v_label
      FROM public.house_pulse_labels l
     WHERE l.contract_version = v_cv
       AND l.pulse_state = v_row.pulse_state
       AND l.is_active = TRUE;

    RETURN jsonb_build_object(
      'pulse', to_jsonb(v_row),
      'label', to_jsonb(v_label),
      'seen', to_jsonb(v_seen)
    );
  END IF;

  -- No snapshot yet -> compute
  v_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, v_cv);

  SELECT *
    INTO v_seen
    FROM public.house_pulse_reads r
   WHERE r.home_id = p_home_id
     AND r.user_id = auth.uid()
     AND r.iso_week_year = v_iso_week_year
     AND r.iso_week = v_iso_week
     AND r.contract_version = v_cv;

  SELECT *
    INTO v_label
    FROM public.house_pulse_labels l
   WHERE l.contract_version = v_cv
     AND l.pulse_state = v_row.pulse_state
     AND l.is_active = TRUE;

  RETURN jsonb_build_object(
    'pulse', to_jsonb(v_row),
    'label', to_jsonb(v_label),
    'seen', to_jsonb(v_seen)
  );
END;
$$;


ALTER FUNCTION "public"."house_pulse_weekly_get"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."house_vibe_compute"("p_home_id" "uuid", "p_force" boolean DEFAULT false, "p_include_axes" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_mapping_version text;
  v_min_side int;
  v_required_n int;

  v_cached public.house_vibes%ROWTYPE;

  v_total int := 0;
  v_contributed int := 0;
  v_ratio numeric := 0;

  -- axis leans + confidences (default to balanced/0 if absent)
  v_energy_lean text := 'balanced';
  v_energy_conf numeric := 0;

  v_structure_lean text := 'balanced';
  v_structure_conf numeric := 0;

  v_social_lean text := 'balanced';
  v_social_conf numeric := 0;

  v_repair_lean text := 'balanced';
  v_repair_conf numeric := 0;

  v_noise_lean text := 'balanced';
  v_noise_conf numeric := 0;

  v_clean_lean text := 'balanced';
  v_clean_conf numeric := 0;

  v_axes jsonb := '{}'::jsonb;

  v_label_id text := 'insufficient_data';
  v_label_conf numeric := 0;
  v_confidence_kind text := 'coverage';

  v_candidate_score numeric;
  v_best_score numeric := -1;
  v_best_label text := null;

  v_label_title_key text;
  v_label_summary_key text;
  v_label_image_key text;
  v_label_ui jsonb;

  -- time anchor to avoid drift
  v_now timestamptz := now();

BEGIN
  --------------------------------------------------------------------
  -- AuthZ guards (SECURITY DEFINER, but still enforce caller rights)
  --------------------------------------------------------------------
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._assert_home_member(p_home_id);

  --------------------------------------------------------------------
  -- Resolve mapping_version (active)
  --------------------------------------------------------------------
  SELECT hv.mapping_version
    INTO v_mapping_version
  FROM public.house_vibe_versions hv
  WHERE hv.status = 'active'
  ORDER BY hv.created_at DESC
  LIMIT 1;

  IF v_mapping_version IS NULL THEN
    v_mapping_version := 'v1';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_home_id::text || ':' || v_mapping_version, 0)
  );

  --------------------------------------------------------------------
  -- Return cached snapshot if not forcing and not out_of_date
  --------------------------------------------------------------------
  SELECT *
    INTO v_cached
  FROM public.house_vibes
  WHERE home_id = p_home_id
    AND mapping_version = v_mapping_version;

  IF v_cached.home_id IS NOT NULL
     AND p_force = false
     AND v_cached.out_of_date = false THEN

    SELECT title_key, summary_key, image_key, ui
      INTO v_label_title_key, v_label_summary_key, v_label_image_key, v_label_ui
    FROM public.house_vibe_labels
    WHERE mapping_version = v_cached.mapping_version
      AND label_id = v_cached.label_id
    LIMIT 1;

    RETURN jsonb_build_object(
      'ok', true,
      'source', 'cache',
      'home_id', v_cached.home_id,
      'mapping_version', v_cached.mapping_version,
      'label_id', v_cached.label_id,
      'confidence', v_cached.confidence,
      'confidence_kind', public._house_vibe_confidence_kind(v_cached.label_id),
      'coverage', jsonb_build_object(
        'answered', v_cached.coverage_answered,
        'total', v_cached.coverage_total
      ),
      'coverage_ratio', CASE
        WHEN v_cached.coverage_total = 0 THEN 0
        ELSE ROUND((v_cached.coverage_answered::numeric / v_cached.coverage_total::numeric), 3)
      END,
      'computed_at', v_cached.computed_at,
      'presentation', jsonb_build_object(
        'title_key', v_label_title_key,
        'summary_key', v_label_summary_key,
        'image_key', v_label_image_key,
        'ui', COALESCE(v_label_ui, '{}'::jsonb)
      ),
      'axes', CASE WHEN p_include_axes THEN COALESCE(v_cached.axes, '{}'::jsonb) ELSE '{}'::jsonb END
    );
  END IF;

  --------------------------------------------------------------------
  -- Total current members for this home
  --------------------------------------------------------------------
  SELECT COUNT(*)
    INTO v_total
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.is_current = true;

  --------------------------------------------------------------------
  -- Determine "complete set" requirement for this mapping version
  --------------------------------------------------------------------
  SELECT COUNT(DISTINCT me.preference_id)
    INTO v_required_n
  FROM public.house_vibe_mapping_effects me
  WHERE me.mapping_version = v_mapping_version;

  IF COALESCE(v_required_n, 0) <= 0 THEN
    RAISE EXCEPTION
      'house_vibe_compute: mapping_version % has no mapping_effects; cannot derive required preference count',
      v_mapping_version;
  END IF;

  --------------------------------------------------------------------
  -- min_side_count depends on total size
  --------------------------------------------------------------------
  SELECT CASE
           WHEN v_total <= 3 THEN hv.min_side_count_small
           ELSE hv.min_side_count_large
         END
    INTO v_min_side
  FROM public.house_vibe_versions hv
  WHERE hv.mapping_version = v_mapping_version
  ORDER BY hv.created_at DESC
  LIMIT 1;

  IF v_min_side IS NULL THEN
    v_min_side := 2;
  END IF;

  --------------------------------------------------------------------
  -- Contributors + Axes (single pass)
  --------------------------------------------------------------------
  WITH
  current_members AS (
    SELECT m.user_id
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.is_current = true
  ),
  required_prefs AS (
    SELECT DISTINCT me.preference_id
    FROM public.house_vibe_mapping_effects me
    WHERE me.mapping_version = v_mapping_version
  ),
  per_user_required AS (
    SELECT
      pr.user_id,
      COUNT(DISTINCT pr.preference_id) AS answered_required_n
    FROM public.preference_responses pr
    JOIN current_members cm
      ON cm.user_id = pr.user_id
    JOIN required_prefs rp
      ON rp.preference_id = pr.preference_id
    GROUP BY pr.user_id
  ),
  contributors AS (
    SELECT pur.user_id
    FROM per_user_required pur
    WHERE pur.answered_required_n >= v_required_n
  ),
  contributed_count AS (
    SELECT COUNT(*)::int AS n
    FROM contributors
  ),
  mapped AS (
    SELECT
      pr.user_id,
      me.axis,
      me.delta,
      me.weight
    FROM public.preference_responses pr
    JOIN contributors c
      ON c.user_id = pr.user_id
    JOIN public.house_vibe_mapping_effects me
      ON me.mapping_version = v_mapping_version
     AND me.preference_id = pr.preference_id
     AND me.option_index = pr.option_index
  ),
  member_axis AS (
    SELECT
      user_id,
      axis,
      CASE
        WHEN SUM(weight) = 0 THEN NULL
        ELSE (SUM((delta::numeric) * weight) / SUM(weight))
      END AS score
    FROM mapped
    GROUP BY user_id, axis
  ),
  member_votes AS (
    SELECT
      axis,
      user_id,
      score,
      CASE
        WHEN score IS NULL THEN 'none'
        WHEN score > 0.20 THEN 'high'
        WHEN score < -0.20 THEN 'low'
        ELSE 'neutral'
      END AS vote
    FROM member_axis
  ),
  axis_counts AS (
    SELECT
      axis,
      COUNT(*) FILTER (WHERE vote = 'high')    AS high_n,
      COUNT(*) FILTER (WHERE vote = 'low')     AS low_n,
      COUNT(*) FILTER (WHERE vote = 'neutral') AS neutral_n,
      COUNT(*) FILTER (WHERE vote <> 'none')   AS contributed_n,
      AVG(score)                               AS score_avg
    FROM member_votes
    GROUP BY axis
  ),
  axis_resolved AS (
    SELECT
      ac.axis,
      ac.high_n,
      ac.low_n,
      ac.neutral_n,
      ac.contributed_n,
      ac.score_avg,
      CASE
        WHEN ac.high_n >= v_min_side AND ac.low_n >= v_min_side THEN 'mixed'
        WHEN ac.high_n >= v_min_side AND ac.high_n > ac.low_n THEN 'leans_high'
        WHEN ac.low_n  >= v_min_side AND ac.low_n  > ac.high_n THEN 'leans_low'
        ELSE 'balanced'
      END AS lean,
      LEAST(
        1,
        GREATEST(
          0,
          -- contributors-only coverage term:
          (ac.contributed_n::numeric / NULLIF((SELECT n FROM contributed_count), 0)::numeric)
          *
          -- imbalance term (includes neutrals in denominator):
          (CASE
             WHEN (ac.high_n + ac.low_n + ac.neutral_n) = 0 THEN 0
             ELSE (ABS(ac.high_n - ac.low_n)::numeric / (ac.high_n + ac.low_n + ac.neutral_n)::numeric)
           END)
        )
      ) AS confidence
    FROM axis_counts ac
  )
  SELECT
    (SELECT n FROM contributed_count) AS contributed_n,
    COALESCE(
      jsonb_object_agg(
        ar.axis,
        jsonb_build_object(
          'lean', ar.lean,
          'score', ROUND(COALESCE(ar.score_avg, 0)::numeric, 3),
          'confidence', ROUND(COALESCE(ar.confidence, 0)::numeric, 3),
          'counts', jsonb_build_object(
            'high', COALESCE(ar.high_n, 0),
            'low', COALESCE(ar.low_n, 0),
            'neutral', COALESCE(ar.neutral_n, 0),
            'contributed', COALESCE(ar.contributed_n, 0),
            'contributors_total', (SELECT n FROM contributed_count),
            'total_members', v_total
          )
        )
      ) FILTER (WHERE ar.axis IS NOT NULL),
      '{}'::jsonb
    ) AS axes_json
  INTO v_contributed, v_axes
  FROM axis_resolved ar;

  v_contributed := COALESCE(v_contributed, 0);
  v_axes := COALESCE(v_axes, '{}'::jsonb);

  -- coverage ratio for label gating remains contributor share of total members
  IF v_total > 0 THEN
    v_ratio := (v_contributed::numeric / v_total::numeric);
  ELSE
    v_ratio := 0;
  END IF;

  --------------------------------------------------------------------
  -- Extract axis lean/conf from v_axes JSON
  --------------------------------------------------------------------
  v_energy_lean := COALESCE(v_axes #>> '{energy_level,lean}', 'balanced');
  v_energy_conf := COALESCE((v_axes #>> '{energy_level,confidence}')::numeric, 0);

  v_structure_lean := COALESCE(v_axes #>> '{structure_level,lean}', 'balanced');
  v_structure_conf := COALESCE((v_axes #>> '{structure_level,confidence}')::numeric, 0);

  v_social_lean := COALESCE(v_axes #>> '{social_level,lean}', 'balanced');
  v_social_conf := COALESCE((v_axes #>> '{social_level,confidence}')::numeric, 0);

  v_repair_lean := COALESCE(v_axes #>> '{repair_style,lean}', 'balanced');
  v_repair_conf := COALESCE((v_axes #>> '{repair_style,confidence}')::numeric, 0);

  v_noise_lean := COALESCE(v_axes #>> '{noise_tolerance,lean}', 'balanced');
  v_noise_conf := COALESCE((v_axes #>> '{noise_tolerance,confidence}')::numeric, 0);

  v_clean_lean := COALESCE(v_axes #>> '{cleanliness_rhythm,lean}', 'balanced');
  v_clean_conf := COALESCE((v_axes #>> '{cleanliness_rhythm,confidence}')::numeric, 0);

  --------------------------------------------------------------------
  -- Deterministic resolution
  --------------------------------------------------------------------
  IF v_total = 0
     OR v_contributed < 2
     OR v_ratio < 0.4
  THEN
    v_label_id := 'insufficient_data';
    v_label_conf := CASE WHEN v_total = 0 THEN 0 ELSE v_ratio END;

  ELSE
    -- Any axis in 'mixed' -> mixed_home
    IF v_energy_lean = 'mixed'
       OR v_structure_lean = 'mixed'
       OR v_social_lean = 'mixed'
       OR v_repair_lean = 'mixed'
       OR v_noise_lean = 'mixed'
       OR v_clean_lean = 'mixed'
    THEN
      v_label_id := 'mixed_home';

      v_label_conf := 1;
      IF v_energy_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_energy_conf); END IF;
      IF v_structure_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_structure_conf); END IF;
      IF v_social_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_social_conf); END IF;
      IF v_repair_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_repair_conf); END IF;
      IF v_noise_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_noise_conf); END IF;
      IF v_clean_lean = 'mixed' THEN v_label_conf := LEAST(v_label_conf, v_clean_conf); END IF;

    ELSE
      v_best_score := -1;
      v_best_label := NULL;

      -- --------------------------------------------------------------
      -- SOCIAL VARIANTS (close holes where social is high but energy/noise aren't)
      -- --------------------------------------------------------------

      -- cozy_social_home: social high + (energy low OR noise low)
      IF v_social_lean = 'leans_high'
         AND (v_energy_lean = 'leans_low' OR v_noise_lean = 'leans_low')
      THEN
        SELECT AVG(x)::numeric
          INTO v_candidate_score
        FROM (VALUES
          (v_social_conf),
          (CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf END),
          (CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf END)
        ) t(x)
        WHERE x IS NOT NULL;

        IF v_candidate_score IS NOT NULL AND v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'cozy_social_home';
        END IF;
      END IF;

      -- social_home: social high + energy high
      IF v_social_lean = 'leans_high' AND v_energy_lean = 'leans_high' THEN
        v_candidate_score := (v_social_conf + v_energy_conf) / 2;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'social_home';
        END IF;
      END IF;

      -- warm_social_home: social high + energy not high
      IF v_social_lean = 'leans_high'
         AND v_energy_lean <> 'leans_high'
      THEN
        v_candidate_score := v_social_conf;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'warm_social_home';
        END IF;
      END IF;

      -- --------------------------------------------------------------
      -- STRUCTURE / EASE
      -- --------------------------------------------------------------

      -- structured_home
      IF v_structure_lean = 'leans_high' AND v_clean_lean = 'leans_high' THEN
        v_candidate_score := (v_structure_conf + v_clean_conf) / 2;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'structured_home';
        END IF;
      END IF;

      -- easygoing_home
      IF (v_structure_lean = 'leans_low' OR v_clean_lean = 'leans_low')
         AND NOT (v_noise_lean = 'leans_low')
      THEN
        v_candidate_score := (v_structure_conf + v_clean_conf + v_noise_conf) / 3;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'easygoing_home';
        END IF;
      END IF;

      -- --------------------------------------------------------------
      -- INDEPENDENCE / QUIET CARE
      -- --------------------------------------------------------------

      -- independent_home
      IF v_social_lean = 'leans_low'
         AND (v_structure_lean = 'balanced' OR v_structure_lean = 'leans_high')
      THEN
        v_candidate_score := (v_social_conf + v_structure_conf) / 2;
        IF v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'independent_home';
        END IF;
      END IF;

      -- quiet_care_home: (energy low OR noise low) AND social not high
      IF (v_energy_lean = 'leans_low' OR v_noise_lean = 'leans_low')
         AND NOT (v_social_lean = 'leans_high')
      THEN
        SELECT AVG(x)::numeric
          INTO v_candidate_score
        FROM (VALUES
          (CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf END),
          (CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf END),
          (CASE WHEN v_social_lean <> 'leans_high' THEN v_social_conf END)
        ) t(x)
        WHERE x IS NOT NULL;

        IF v_candidate_score IS NOT NULL AND v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'quiet_care_home';
        END IF;
      END IF;

      -- --------------------------------------------------------------
      -- steady_home: social balanced + not structured/easygoing + action signals
      -- (lets repair/clean contribute without dominating the whole taxonomy)
      -- --------------------------------------------------------------
      IF v_social_lean = 'balanced'
         AND v_energy_lean <> 'leans_low'
         AND v_noise_lean <> 'leans_low'
         AND v_structure_lean <> 'leans_high'   -- avoids structured-like emphasis
         AND v_structure_lean <> 'leans_low'    -- avoids easygoing via structure low
         AND v_clean_lean <> 'leans_low'        -- avoids easygoing via clean low
         AND (v_clean_lean = 'leans_high' OR v_repair_lean = 'leans_high')
      THEN
        SELECT AVG(x)::numeric
          INTO v_candidate_score
        FROM (VALUES
          (v_social_conf),
          (CASE WHEN v_clean_lean = 'leans_high' THEN v_clean_conf END),
          (CASE WHEN v_repair_lean = 'leans_high' THEN v_repair_conf END)
        ) t(x)
        WHERE x IS NOT NULL;

        IF v_candidate_score IS NOT NULL AND v_candidate_score > v_best_score THEN
          v_best_score := v_candidate_score;
          v_best_label := 'steady_home';
        END IF;
      END IF;

      -- Finalize label
      IF v_best_label IS NULL THEN
        v_label_id := 'default_home';
        v_label_conf := CASE WHEN v_total = 0 THEN 0 ELSE v_ratio END;
      ELSE
        v_label_id := v_best_label;

        -- Confidence per label (min/least of contributing axes)
        IF v_label_id = 'cozy_social_home' THEN
          v_label_conf := LEAST(
            v_social_conf,
            CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf ELSE 1 END,
            CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf  ELSE 1 END
          );

        ELSIF v_label_id = 'social_home' THEN
          v_label_conf := LEAST(v_social_conf, v_energy_conf);

        ELSIF v_label_id = 'warm_social_home' THEN
          v_label_conf := v_social_conf;

        ELSIF v_label_id = 'structured_home' THEN
          v_label_conf := LEAST(v_structure_conf, v_clean_conf);

        ELSIF v_label_id = 'easygoing_home' THEN
          v_label_conf := LEAST(v_structure_conf, LEAST(v_clean_conf, v_noise_conf));

        ELSIF v_label_id = 'independent_home' THEN
          v_label_conf := LEAST(v_social_conf, v_structure_conf);

        ELSIF v_label_id = 'quiet_care_home' THEN
          SELECT LEAST(1, GREATEST(0, MIN(x)))::numeric
            INTO v_label_conf
          FROM (VALUES
            (CASE WHEN v_energy_lean = 'leans_low' THEN v_energy_conf END),
            (CASE WHEN v_noise_lean  = 'leans_low' THEN v_noise_conf END),
            (CASE WHEN v_social_lean <> 'leans_high' THEN v_social_conf END)
          ) t(x)
          WHERE x IS NOT NULL;

        ELSIF v_label_id = 'steady_home' THEN
          SELECT LEAST(1, GREATEST(0, MIN(x)))::numeric
            INTO v_label_conf
          FROM (VALUES
            (v_social_conf),
            (CASE WHEN v_clean_lean = 'leans_high' THEN v_clean_conf END),
            (CASE WHEN v_repair_lean = 'leans_high' THEN v_repair_conf END)
          ) t(x)
          WHERE x IS NOT NULL;

        ELSE
          v_label_id := 'default_home';
          v_label_conf := CASE WHEN v_total = 0 THEN 0 ELSE v_ratio END;
        END IF;

        v_label_conf := LEAST(1, GREATEST(0, COALESCE(v_label_conf, 0)));
      END IF;
    END IF;
  END IF;

  -- single source of truth (cache + compute)
  v_confidence_kind := public._house_vibe_confidence_kind(v_label_id);

  --------------------------------------------------------------------
  -- Persist snapshot (Model B upsert on (home_id, mapping_version))
  --------------------------------------------------------------------
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
    v_mapping_version,
    v_label_id,
    v_label_conf,
    v_contributed,
    v_total,
    COALESCE(v_axes, '{}'::jsonb),
    v_now,
    false,
    NULL
  )
  ON CONFLICT (home_id, mapping_version) DO UPDATE
    SET label_id          = EXCLUDED.label_id,
        confidence        = EXCLUDED.confidence,
        coverage_answered = EXCLUDED.coverage_answered,
        coverage_total    = EXCLUDED.coverage_total,
        axes              = EXCLUDED.axes,
        computed_at       = EXCLUDED.computed_at,
        out_of_date       = false,
        invalidated_at    = NULL;

  --------------------------------------------------------------------
  -- Presentation join
  --------------------------------------------------------------------
  SELECT title_key, summary_key, image_key, ui
    INTO v_label_title_key, v_label_summary_key, v_label_image_key, v_label_ui
  FROM public.house_vibe_labels
  WHERE mapping_version = v_mapping_version
    AND label_id = v_label_id
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'source', 'computed',
    'home_id', p_home_id,
    'mapping_version', v_mapping_version,
    'label_id', v_label_id,
    'confidence', v_label_conf,
    'confidence_kind', v_confidence_kind,
    'coverage', jsonb_build_object('answered', v_contributed, 'total', v_total),
    'coverage_ratio', ROUND(v_ratio, 3),
    'computed_at', v_now,
    'presentation', jsonb_build_object(
      'title_key', v_label_title_key,
      'summary_key', v_label_summary_key,
      'image_key', v_label_image_key,
      'ui', COALESCE(v_label_ui, '{}'::jsonb)
    ),
    'axes', CASE WHEN p_include_axes THEN COALESCE(v_axes, '{}'::jsonb) ELSE '{}'::jsonb END
  );
END;
$$;


ALTER FUNCTION "public"."house_vibe_compute"("p_home_id" "uuid", "p_force" boolean, "p_include_axes" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "code" "public"."citext" NOT NULL,
    "revoked_at" timestamp with time zone,
    "used_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_invites_code_format" CHECK (("upper"(("code")::"text") ~ '^[A-HJ-NP-Z2-9]{6}$'::"text")),
    CONSTRAINT "chk_invites_revoked_after_created" CHECK ((("revoked_at" IS NULL) OR ("revoked_at" >= "created_at"))),
    CONSTRAINT "chk_invites_used_nonneg" CHECK (("used_count" >= 0))
);


ALTER TABLE "public"."invites" OWNER TO "postgres";


COMMENT ON TABLE "public"."invites" IS 'Permanent invitation codes for joining homes. Unlimited-use; owners can rotate by revoking.';



COMMENT ON COLUMN "public"."invites"."id" IS 'Primary key (UUID).';



COMMENT ON COLUMN "public"."invites"."home_id" IS 'FK to homes.id; identifies which home the code belongs to.';



COMMENT ON COLUMN "public"."invites"."code" IS '6-char, typeable invite (A–H J–N P–Z, 2–9). Case-insensitive; normalized to uppercase.';



COMMENT ON COLUMN "public"."invites"."revoked_at" IS 'UTC time when the invite was revoked by the owner; NULL means still active.';



COMMENT ON COLUMN "public"."invites"."used_count" IS 'Analytics counter for how many times the code has been used.';



COMMENT ON COLUMN "public"."invites"."created_at" IS 'UTC creation timestamp.';



CREATE OR REPLACE FUNCTION "public"."invites_get_active"("p_home_id" "uuid") RETURNS "public"."invites"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_inv public.invites;
BEGIN
  -- Ensure caller is authenticated + active member of this home
  PERFORM public._assert_home_member(p_home_id);

  -- Fetch the current active invite (no side-effects)
  SELECT *
    INTO v_inv
  FROM public.invites i
  WHERE i.home_id   = p_home_id
    AND i.revoked_at IS NULL
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    -- Use the same structured error pattern as your helpers
    PERFORM public.api_error(
      'INVITE_NOT_FOUND',
      'No active invite exists for this home.',
      'P0001',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  RETURN v_inv;
END;
$$;


ALTER FUNCTION "public"."invites_get_active"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invites_revoke"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();

  -- 1️⃣ Must be the current owner
  PERFORM public.api_assert(EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.home_id = p_home_id
      AND m.role = 'owner'
      AND m.is_current = TRUE
  ), 'FORBIDDEN', 'Only the current owner can revoke an invite.', '42501',
     jsonb_build_object('homeId', p_home_id));

  -- 2️⃣ Revoke any active invite(s)
  UPDATE public.invites i
     SET revoked_at = now()
   WHERE i.home_id = p_home_id
     AND i.revoked_at IS NULL
  RETURNING * INTO v_inv;

  -- 3️⃣ If no active invite existed, return a soft info response
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status',  'info',
      'code',    'no_active_invite',
      'message', 'No active invite was found to revoke.'
    );
  END IF;

  -- 4️⃣ Return structured success payload
  RETURN jsonb_build_object(
    'status',      'success',
    'code',        'invite_revoked',
    'message',     'The active invite has been revoked successfully.',
    'invite_id',   v_inv.id,
    'home_id',     v_inv.home_id,
    'revoked_at',  v_inv.revoked_at
  );
END;
$$;


ALTER FUNCTION "public"."invites_revoke"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invites_rotate"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
  v_new  public.invites;
BEGIN
  PERFORM public._assert_authenticated();

  -- ensure caller is the current owner of an active home
  PERFORM public.api_assert(EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.homes h ON h.id = m.home_id
    WHERE m.user_id    = v_user
      AND m.home_id    = p_home_id
      AND m.role       = 'owner'
      AND m.is_current = TRUE
      AND h.is_active  = TRUE
  ), 'FORBIDDEN', 'Only the current owner of an active household can rotate invites.', '42501',
     jsonb_build_object('homeId', p_home_id));

  -- revoke existing active invites
  UPDATE public.invites
     SET revoked_at = now()
   WHERE home_id    = p_home_id
     AND revoked_at IS NULL;

  -- create a new invite; partial unique index enforces 1 active per home
  INSERT INTO public.invites (home_id, code)
  VALUES (p_home_id, public._gen_invite_code())
  ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING * INTO v_new;

  -- race-safe fallback if another txn inserted first
  IF v_new.id IS NULL THEN
    SELECT *
      INTO v_new
      FROM public.invites
     WHERE home_id = p_home_id
       AND revoked_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'status','success',
    'code','invite_rotated',
    'message','A new invite code has been generated successfully.',
    'invite_id',   v_new.id,
    'invite_code', v_new.code
  );
END;
$$;


ALTER FUNCTION "public"."invites_rotate"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_home_owner"("p_home_id" "uuid", "p_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.user_id = COALESCE(p_user_id, auth.uid())
      AND m.is_current = TRUE
      AND m.role = 'owner'
  );
$$;


ALTER FUNCTION "public"."is_home_owner"("p_home_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leads_rate_limits_cleanup"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  delete from public.leads_rate_limits
   where updated_at < now() - interval '8 days';
end;
$$;


ALTER FUNCTION "public"."leads_rate_limits_cleanup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leads_upsert_v1"("p_email" "text", "p_country_code" "text", "p_ui_locale" "text", "p_source" "text" DEFAULT 'kinly_web_get'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_lead_id uuid;
  v_deduped boolean := false;

  v_now timestamptz := now();

  v_email_key text;
  v_global_key text;

  v_email_lock_id bigint;
  v_global_lock_id bigint;

  v_email_window timestamptz;
  v_global_window timestamptz;

  v_email_n integer;
  v_global_n integer;

  c_email_limit_per_day constant integer := 5;
  c_global_limit_per_minute constant integer := 300;
begin
  -- Normalize inputs
  p_email := trim(coalesce(p_email, ''));
  p_country_code := upper(trim(coalesce(p_country_code, '')));
  p_ui_locale := trim(coalesce(p_ui_locale, ''));
  p_source := coalesce(nullif(trim(p_source), ''), 'kinly_web_get');

  perform public.api_assert(
    p_email <> '' and p_country_code <> '' and p_ui_locale <> '',
    'LEADS_MISSING_FIELDS',
    'email, country_code, and ui_locale are required.'
  );

  -- Email (permissive) + max length
  perform public.api_assert(length(p_email) <= 254,
    'LEADS_EMAIL_TOO_LONG',
    'Email must be 254 characters or fewer.'
  );

  perform public.api_assert(length(p_email) >= 3,
    'LEADS_EMAIL_TOO_SHORT',
    'Email must be at least 3 characters.'
  );

  perform public.api_assert(
    p_email !~ '\s'
    and position('@' in p_email) > 1
    and position('.' in split_part(p_email, '@', 2)) > 1,
    'LEADS_EMAIL_INVALID',
    'Email format is invalid.'
  );

  -- country_code strict format only (ZZ allowed)
  perform public.api_assert(p_country_code ~ '^[A-Z]{2}$',
    'LEADS_COUNTRY_CODE_INVALID',
    'country_code must be ISO alpha-2 (e.g., NZ).'
  );

  -- ui_locale: light BCP-47-ish, no spaces
  perform public.api_assert(
    length(p_ui_locale) between 2 and 35
    and p_ui_locale !~ '\s'
    and p_ui_locale ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$',
    'LEADS_UI_LOCALE_INVALID',
    'ui_locale must look like a locale tag (e.g., en-NZ).'
  );

  -- source allowlist
  perform public.api_assert(
    p_source in ('kinly_web_get', 'kinly_dating_web_get', 'kinly_rent_web_get'),
    'LEADS_SOURCE_INVALID',
    'source is not allowed.'
  );

  -- Abuse mitigation (NO IP)
  v_email_window := date_trunc('day', v_now);
  v_global_window := date_trunc('minute', v_now);

  -- Hash keys (NO PII stored)
  -- Canonicalize email with citext semantics: (p_email::public.citext)::text
  v_email_key := public._sha256_hex(
    'email:' || (p_email::public.citext)::text || ':' || v_email_window::text
  );

  v_global_key := public._sha256_hex(
    'global:' || v_global_window::text
  );

  -- 64-bit advisory lock ids derived from sha256 hex keys (first 16 hex chars)
  v_email_lock_id := ('x' || substr(v_email_key, 1, 16))::bit(64)::bigint;
  v_global_lock_id := ('x' || substr(v_global_key, 1, 16))::bit(64)::bigint;

  -- Global limiter
  perform pg_advisory_xact_lock(v_global_lock_id);
  insert into public.leads_rate_limits(k, n, updated_at)
  values (v_global_key, 1, v_now)
  on conflict (k) do update
     set n = public.leads_rate_limits.n + 1,
         updated_at = v_now
  returning n into v_global_n;

  perform public.api_assert(v_global_n <= c_global_limit_per_minute,
    'LEADS_RATE_LIMIT_GLOBAL',
    'Too many requests. Please try again later.'
  );

  -- Email limiter
  perform pg_advisory_xact_lock(v_email_lock_id);
  insert into public.leads_rate_limits(k, n, updated_at)
  values (v_email_key, 1, v_now)
  on conflict (k) do update
     set n = public.leads_rate_limits.n + 1,
         updated_at = v_now
  returning n into v_email_n;

  perform public.api_assert(v_email_n <= c_email_limit_per_day,
    'LEADS_RATE_LIMIT_EMAIL',
    'Too many requests for this email today.'
  );

  -- UPSERT (deduped is precise via xmax)
  insert into public.leads (email, country_code, ui_locale, source)
  values (p_email::public.citext, p_country_code, p_ui_locale, p_source)
  on conflict (email) do update
    set country_code = excluded.country_code,
        ui_locale     = excluded.ui_locale,
        source        = excluded.source
  returning id, (xmax <> 0) as deduped
    into v_lead_id, v_deduped;

  return jsonb_build_object(
    'ok', true,
    'lead_id', v_lead_id,
    'deduped', v_deduped
  );
end;
$_$;


ALTER FUNCTION "public"."leads_upsert_v1"("p_email" "text", "p_country_code" "text", "p_ui_locale" "text", "p_source" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."locale_base"("p_locale" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT
    CASE
      WHEN p_locale IS NULL OR length(trim(p_locale)) = 0 THEN NULL
      ELSE lower(split_part(p_locale, '-', 1))
    END
$$;


ALTER FUNCTION "public"."locale_base"("p_locale" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."member_cap_owner_dismiss"("p_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_owner(p_home_id);

  PERFORM public._member_cap_resolve_requests(
    p_home_id,
    'owner_dismissed',
    NULL,
    jsonb_build_object('by', v_user)
  );
END;
$$;


ALTER FUNCTION "public"."member_cap_owner_dismiss"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."member_cap_process_pending"("p_home_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_inv public.invites;
  v_row public.member_cap_join_requests%ROWTYPE;
  v_home_active boolean;
BEGIN
  IF p_home_id IS NULL THEN
    RETURN;
  END IF;

  -- Only process when premium
  IF NOT public._home_is_premium(p_home_id) THEN
    RETURN;
  END IF;

  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = p_home_id;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    RETURN;
  END IF;

  -- Ensure invite exists (one active per home)
  SELECT *
    INTO v_inv
    FROM public.invites
   WHERE home_id = p_home_id
     AND revoked_at IS NULL
   ORDER BY created_at DESC, id DESC
   LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.invites (home_id, code)
    VALUES (p_home_id, public._gen_invite_code())
    ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING;

    SELECT *
      INTO v_inv
      FROM public.invites
     WHERE home_id = p_home_id
       AND revoked_at IS NULL
     ORDER BY created_at DESC, id DESC
     LIMIT 1;
  END IF;

  FOR v_row IN
    SELECT *
      FROM public.member_cap_join_requests
     WHERE home_id = p_home_id
       AND resolved_at IS NULL
     ORDER BY created_at ASC, id ASC
  LOOP
    -- home inactive (defensive)
    IF v_home_active IS DISTINCT FROM TRUE THEN
      PERFORM public._member_cap_resolve_requests(
        p_home_id,
        'home_inactive',
        ARRAY[v_row.id],
        NULL
      );
      CONTINUE;
    END IF;

    -- no invite (defensive)
    IF v_inv.id IS NULL THEN
      PERFORM public._member_cap_resolve_requests(
        p_home_id,
        'invite_missing',
        ARRAY[v_row.id],
        NULL
      );
      CONTINUE;
    END IF;

    -- attempt to join; handle races safely via unique constraint on memberships(user_id) WHERE is_current
    BEGIN
      INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
      VALUES (v_row.joiner_user_id, p_home_id, 'member', now(), NULL);

      PERFORM public._home_usage_apply_delta(
        p_home_id,
        jsonb_build_object('active_members', 1)
      );

      UPDATE public.invites
         SET used_count = used_count + 1
       WHERE id = v_inv.id;

      PERFORM public._home_attach_subscription_to_home(v_row.joiner_user_id, p_home_id);

      PERFORM public._member_cap_resolve_requests(
        p_home_id,
        'joined',
        ARRAY[v_row.id],
        jsonb_build_object('invite_id', v_inv.id, 'invite_code', v_inv.code)
      );

    EXCEPTION
      WHEN unique_violation THEN
        -- joiner got a current membership elsewhere (or already joined) between checks and insert
        PERFORM public._member_cap_resolve_requests(
          p_home_id,
          'joiner_superseded',
          ARRAY[v_row.id],
          NULL
        );
        CONTINUE;

      WHEN OTHERS THEN
        -- Do NOT RAISE: one bad request should not stall the entire queue.
        -- Leaving unresolved allows future retries after transient issues.
        CONTINUE;
    END;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."member_cap_process_pending"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."members_kick"("p_home_id" "uuid", "p_target_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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


ALTER FUNCTION "public"."members_kick"("p_home_id" "uuid", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."members_list_active_by_home"("p_home_id" "uuid", "p_exclude_self" boolean DEFAULT true) RETURNS TABLE("user_id" "uuid", "username" "public"."citext", "role" "text", "valid_from" timestamp with time zone, "avatar_url" "text", "can_transfer_to" boolean)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT 
    m.user_id,
    p.username,
    m.role,
    m.valid_from,
    a.storage_path AS avatar_url,
    (m.role <> 'owner') AS can_transfer_to
  FROM public.memberships m
  JOIN public.profiles p ON p.id = m.user_id
  JOIN public.avatars  a ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
    AND (p_exclude_self IS FALSE OR m.user_id <> auth.uid())
  ORDER BY 
    CASE WHEN m.role = 'owner' THEN 0 ELSE 1 END,
    p.username;
$$;


ALTER FUNCTION "public"."members_list_active_by_home"("p_home_id" "uuid", "p_exclude_self" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."membership_me_current"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
  v_row  public.memberships;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_row
  FROM public.memberships m
  WHERE m.user_id = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'current', NULL);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'current', jsonb_build_object(
      'user_id', v_row.user_id,
      'home_id', v_row.home_id,
      'role',    v_row.role,
      'valid_from', v_row.valid_from
    )
  );
END;
$$;


ALTER FUNCTION "public"."membership_me_current"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mood_get_current_weekly"("p_home_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_iso_week      int;
  v_iso_week_year int;
  v_exists        boolean;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT extract('week' FROM timezone('UTC', now()))::int,
         extract('isoyear' FROM timezone('UTC', now()))::int
  INTO v_iso_week, v_iso_week_year;

  SELECT EXISTS (
    SELECT 1
    FROM public.home_mood_entries e
    WHERE e.user_id       = v_user_id
      AND e.iso_week_year = v_iso_week_year
      AND e.iso_week      = v_iso_week
  )
  INTO v_exists;

  RETURN v_exists;
END;
$$;


ALTER FUNCTION "public"."mood_get_current_weekly"("p_home_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."mood_get_current_weekly"("p_home_id" "uuid") IS 'Returns TRUE if the user already submitted a mood entry for the current ISO week (in ANY home), otherwise FALSE. The p_home_id parameter is used only for membership and home-active checks.';



CREATE OR REPLACE FUNCTION "public"."mood_submit"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text" DEFAULT NULL::"text", "p_add_to_wall" boolean DEFAULT false) RETURNS TABLE("entry_id" "uuid", "gratitude_post_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_iso_week      int;
  v_iso_week_year int;
  v_post_id       uuid;
  v_comment_trim  text;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  PERFORM public.api_assert(
    p_home_id IS NOT NULL,
    'INVALID_HOME',
    'Home id is required.',
    '22023'
  );

  PERFORM public.api_assert(
    p_mood IS NOT NULL,
    'INVALID_MOOD',
    'Mood is required.',
    '22023'
  );

  SELECT extract('week' FROM timezone('UTC', now()))::int,
         extract('isoyear' FROM timezone('UTC', now()))::int
    INTO v_iso_week, v_iso_week_year;

    PERFORM public.api_assert(
    NOT EXISTS (
        SELECT 1
        FROM public.home_mood_entries e
        WHERE e.user_id       = v_user_id
        AND e.iso_week_year = v_iso_week_year
        AND e.iso_week      = v_iso_week
    ),
    'MOOD_ALREADY_SUBMITTED',
    'Mood already submitted for this ISO week (across all homes).',
    'P0001',
    jsonb_build_object('isoWeek', v_iso_week, 'isoYear', v_iso_week_year)
    );

  -- Normalise comment: trim whitespace, turn empty string into NULL, then cap length at 500
  v_comment_trim := NULLIF(btrim(p_comment), '');

  INSERT INTO public.home_mood_entries (
    home_id,
    user_id,
    mood,
    comment,
    iso_week_year,
    iso_week
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_mood,
    CASE
      WHEN v_comment_trim IS NULL THEN NULL
      ELSE left(v_comment_trim, 500)
    END,
    v_iso_week_year,
    v_iso_week
  )
  RETURNING id INTO entry_id;

  IF COALESCE(p_add_to_wall, FALSE) AND p_mood IN ('sunny','partially_sunny') THEN
    INSERT INTO public.gratitude_wall_posts (
      home_id,
      author_user_id,
      mood,
      message
    )
    VALUES (
      p_home_id,
      v_user_id,
      p_mood,
      CASE
        WHEN v_comment_trim IS NULL THEN NULL
        ELSE left(v_comment_trim, 500)
      END
    )
    RETURNING id INTO v_post_id;

    UPDATE public.home_mood_entries
    SET gratitude_post_id = v_post_id
    WHERE id = entry_id;
  END IF;

  gratitude_post_id := v_post_id;
  RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."mood_submit"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_add_to_wall" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."mood_submit"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_add_to_wall" boolean) IS 'Submit the current user''s weekly mood for a home. Enforces one entry per user per ISO week across all homes. Optionally creates a gratitude wall post when mood is positive (sunny/partially_sunny) and p_add_to_wall is true. Parameters: p_home_id (home ID), p_mood (mood_scale value), p_comment (optional text), p_add_to_wall (whether to post to gratitude wall). Returns: entry_id (mood entry ID), gratitude_post_id (ID of created gratitude wall post, or NULL).';



CREATE OR REPLACE FUNCTION "public"."mood_submit_v2"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text" DEFAULT NULL::"text", "p_public_wall" boolean DEFAULT false, "p_mentions" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id        uuid;
  v_now            timestamptz := now();
  v_iso_week       int;
  v_iso_week_year  int;

  v_entry_id       uuid;
  v_comment_trim   text;

  v_message        text;
  v_post_id        uuid;
  v_source_kind    text;

  v_mentions_raw   uuid[] := COALESCE(p_mentions, ARRAY[]::uuid[]);
  v_mentions_dedup uuid[] := ARRAY[]::uuid[];
  v_mention_count  int := 0;

  v_publish_requested boolean;

  -- Fix 2: computed snapshot row (optional return use; we just force refresh)
  v_pulse_row public.house_pulse_weekly;
BEGIN
  PERFORM public._assert_authenticated();
  v_user_id := auth.uid();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public.api_assert(p_mood IS NOT NULL, 'INVALID_MOOD', 'Mood is required.', '22023');

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Fix 3: canonical UTC ISO week/year
  SELECT w.iso_week_year, w.iso_week
    INTO v_iso_week_year, v_iso_week
    FROM public._iso_week_utc(v_now) w;

  v_comment_trim := NULLIF(btrim(p_comment), '');

  BEGIN
    INSERT INTO public.home_mood_entries (
      home_id, user_id, mood, comment, iso_week_year, iso_week
    )
    VALUES (
      p_home_id,
      v_user_id,
      p_mood,
      CASE WHEN v_comment_trim IS NULL THEN NULL ELSE left(v_comment_trim, 500) END,
      v_iso_week_year,
      v_iso_week
    )
    RETURNING id INTO v_entry_id;
  EXCEPTION
    WHEN unique_violation THEN
      PERFORM public.api_assert(
        FALSE,
        'MOOD_ALREADY_SUBMITTED',
        'Mood already submitted for this ISO week (across all homes).',
        'P0001',
        jsonb_build_object('isoWeek', v_iso_week, 'isoYear', v_iso_week_year)
      );
  END;

  -- Fix 2: eagerly recompute weekly pulse snapshot after a new entry
  -- Keeps the UI fresh even if weekly_get hits an existing snapshot.
  v_pulse_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, 'v1');

  v_publish_requested :=
    COALESCE(p_public_wall, FALSE)
    OR COALESCE(array_length(v_mentions_raw, 1), 0) > 0;

  IF NOT v_publish_requested THEN
    RETURN jsonb_build_object(
      'entry_id', v_entry_id,
      'public_post_id', NULL,
      'mention_count', 0,
      -- optional: nice for immediate UI refresh without an extra call
      'pulse', to_jsonb(v_pulse_row)
    );
  END IF;

  IF p_mood NOT IN ('sunny','partially_sunny') THEN
    PERFORM public.api_assert(
      FALSE,
      'NOT_POSITIVE_MOOD',
      'Publishing gratitude is only available for Sunny or Partially Sunny weeks.',
      '22023'
    );
  END IF;

  v_message := NULLIF(btrim(COALESCE(v_comment_trim, '')), '');
  IF v_message IS NOT NULL THEN
    v_message := left(v_message, 500);
  END IF;

  PERFORM public.api_assert(
    NOT EXISTS (SELECT 1 FROM unnest(v_mentions_raw) m WHERE m IS NULL),
    'INVALID_MENTION_USER',
    'Mention list cannot contain nulls.',
    '22023'
  );

  v_mentions_dedup := COALESCE((
    SELECT array_agg(m ORDER BY m)
    FROM (SELECT DISTINCT m FROM unnest(v_mentions_raw) m) s(m)
  ), ARRAY[]::uuid[]);

  v_mention_count := COALESCE(array_length(v_mentions_dedup, 1), 0);

  IF array_length(v_mentions_raw, 1) IS NOT NULL
     AND array_length(v_mentions_raw, 1) <> v_mention_count THEN
    PERFORM public.api_assert(FALSE, 'DUPLICATE_MENTIONS_NOT_ALLOWED', 'Mentions must be unique.', '22023');
  END IF;

  IF v_mention_count > 5 THEN
    PERFORM public.api_assert(FALSE, 'MENTION_LIMIT_EXCEEDED', 'You can mention at most 5 people.', '22023');
  END IF;

  IF v_user_id = ANY (v_mentions_dedup) THEN
    PERFORM public.api_assert(FALSE, 'SELF_MENTION_NOT_ALLOWED', 'You cannot mention yourself.', '22023');
  END IF;

  IF v_mention_count > 0 THEN
    PERFORM public.api_assert(
      NOT EXISTS (
        SELECT 1
        FROM unnest(v_mentions_dedup) m
        LEFT JOIN public.profiles p ON p.id = m
        LEFT JOIN public.memberships mem
               ON mem.home_id = p_home_id
              AND mem.user_id = m
              AND mem.is_current = TRUE
        WHERE p.id IS NULL OR mem.user_id IS NULL
      ),
      'MENTION_NOT_HOME_MEMBER',
      'All mentions must be existing profiles and current members of the home.',
      '22023'
    );
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('mood_submit_v2_publish'),
    hashtext(v_entry_id::text)
  );

  IF COALESCE(p_public_wall, FALSE) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.gratitude_wall_posts WHERE source_entry_id = v_entry_id
    ) THEN
      INSERT INTO public.gratitude_wall_posts (
        home_id, author_user_id, mood, message, created_at, source_entry_id
      )
      SELECT p_home_id, v_user_id, p_mood, v_message, v_now, v_entry_id;
    END IF;

    SELECT id
      INTO v_post_id
      FROM public.gratitude_wall_posts
     WHERE source_entry_id = v_entry_id
     LIMIT 1;
  END IF;

  IF v_post_id IS NOT NULL AND v_mention_count > 0 THEN
    INSERT INTO public.gratitude_wall_mentions (post_id, home_id, mentioned_user_id, created_at)
    SELECT v_post_id, p_home_id, m, v_now
    FROM unnest(v_mentions_dedup) m
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_mention_count > 0 THEN
    v_source_kind := CASE WHEN v_post_id IS NULL THEN 'mention_only' ELSE 'home_post' END;

    INSERT INTO public.gratitude_wall_personal_items (
      recipient_user_id, home_id, author_user_id, mood, message,
      source_kind, source_post_id, source_entry_id, created_at
    )
    SELECT
      m, p_home_id, v_user_id, p_mood, v_message,
      v_source_kind, v_post_id, v_entry_id, v_now
    FROM unnest(v_mentions_dedup) m
    ON CONFLICT (recipient_user_id, source_entry_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'entry_id', v_entry_id,
    'public_post_id', v_post_id,
    'mention_count', v_mention_count,
    -- optional: return pulse so UI can update instantly
    'pulse', to_jsonb(v_pulse_row)
  );
END;
$$;


ALTER FUNCTION "public"."mood_submit_v2"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_public_wall" boolean, "p_mentions" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."mood_submit_v2"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_public_wall" boolean, "p_mentions" "uuid"[]) IS 'Single-call submit: creates weekly entry and optionally publishes (wall + mentions). Publishing allowed only for sunny/partially_sunny. First publish wins.';



CREATE OR REPLACE FUNCTION "public"."notifications_daily_candidates"("p_limit" integer DEFAULT 200, "p_offset" integer DEFAULT 0) RETURNS TABLE("user_id" "uuid", "locale" "text", "timezone" "text", "token_id" "uuid", "token" "text", "local_date" "date")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  WITH eligible_users AS (
    SELECT
      np.user_id,
      np.locale,
      np.timezone,
      (timezone(np.timezone, now()))::date AS local_date
    FROM public.notification_preferences np
    WHERE np.wants_daily = TRUE
      AND np.os_permission = 'allowed'
      AND np.preferred_hour = date_part('hour', timezone(np.timezone, now()))::int
      AND np.preferred_minute = date_part('minute', timezone(np.timezone, now()))::int
      AND (
        np.last_sent_local_date IS NULL
        OR np.last_sent_local_date < (timezone(np.timezone, now()))::date
      )
      AND public.today_has_content(
        np.user_id,
        np.timezone,
        (timezone(np.timezone, now()))::date
      ) = TRUE
  ),
  eligible_tokens AS (
    SELECT
      eu.user_id,
      eu.locale,
      eu.timezone,
      dt.id   AS token_id,
      dt.token,
      eu.local_date
    FROM eligible_users eu
    JOIN public.device_tokens dt
      ON dt.user_id = eu.user_id
    WHERE dt.status = 'active'
  )
  SELECT
    user_id,
    locale,
    timezone,
    token_id,
    token,
    local_date
  FROM eligible_tokens
  ORDER BY user_id
  LIMIT COALESCE(p_limit, 200)
  OFFSET COALESCE(p_offset, 0);
$$;


ALTER FUNCTION "public"."notifications_daily_candidates"("p_limit" integer, "p_offset" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."notifications_daily_candidates"("p_limit" integer, "p_offset" integer) IS 'Paged list of users + tokens eligible for the daily notification window.';



CREATE OR REPLACE FUNCTION "public"."notifications_mark_send_success"("p_send_id" "uuid", "p_user_id" "uuid", "p_local_date" "date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.notification_sends
  SET status    = 'sent',
      sent_at   = now(),
      updated_at = now()
  WHERE id = p_send_id;

  UPDATE public.notification_preferences
  SET last_sent_local_date = p_local_date,
      updated_at           = now()
  WHERE user_id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."notifications_mark_send_success"("p_send_id" "uuid", "p_user_id" "uuid", "p_local_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_mark_token_status"("p_token_id" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.device_tokens
  SET status    = p_status,
      updated_at = now()
  WHERE id = p_token_id;
END;
$$;


ALTER FUNCTION "public"."notifications_mark_token_status"("p_token_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_reserve_send"("p_user_id" "uuid", "p_token_id" "uuid", "p_local_date" "date", "p_job_run_id" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_token_id IS NULL THEN
    RAISE EXCEPTION 'TOKEN_REQUIRED';
  END IF;

  INSERT INTO public.notification_sends (
    user_id,
    token_id,
    local_date,
    job_run_id,
    status,
    reserved_at
  )
  VALUES (
    p_user_id,
    p_token_id,
    p_local_date,
    p_job_run_id,
    'reserved',
    now()
  )
  ON CONFLICT (token_id, local_date) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;


ALTER FUNCTION "public"."notifications_reserve_send"("p_user_id" "uuid", "p_token_id" "uuid", "p_local_date" "date", "p_job_run_id" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_preferences" (
    "user_id" "uuid" NOT NULL,
    "wants_daily" boolean DEFAULT false NOT NULL,
    "preferred_hour" integer DEFAULT 9 NOT NULL,
    "timezone" "text" NOT NULL,
    "locale" "text" NOT NULL,
    "os_permission" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "last_os_sync_at" timestamp with time zone,
    "last_sent_local_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "preferred_minute" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "chk_notification_preferences_preferred_minute" CHECK ((("preferred_minute" >= 0) AND ("preferred_minute" < 60)))
);


ALTER TABLE "public"."notification_preferences" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_sync_client_state"("p_token" "text", "p_platform" "text", "p_locale" "text", "p_timezone" "text", "p_os_permission" "text", "p_wants_daily" boolean DEFAULT NULL::boolean, "p_preferred_hour" integer DEFAULT NULL::integer, "p_preferred_minute" integer DEFAULT NULL::integer) RETURNS "public"."notification_preferences"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_current     public.notification_preferences;
  v_effective_wants_daily      boolean;
  v_effective_preferred_hour   integer;
  v_effective_preferred_minute integer;
  v_should_upsert boolean;
  v_max_active_per_platform integer := 2;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT *
  INTO v_current
  FROM public.notification_preferences
  WHERE user_id = v_user_id;

  v_effective_wants_daily :=
    COALESCE(
      p_wants_daily,
      v_current.wants_daily,
      (p_os_permission = 'allowed')
    );

  -- Force off when OS is blocked/unknown so UI toggle mirrors system status
  IF p_os_permission IS DISTINCT FROM 'allowed' THEN
    v_effective_wants_daily := FALSE;
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


ALTER FUNCTION "public"."notifications_sync_client_state"("p_token" "text", "p_platform" "text", "p_locale" "text", "p_timezone" "text", "p_os_permission" "text", "p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_update_preferences"("p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) RETURNS "public"."notification_preferences"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_pref    public.notification_preferences;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
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
  SELECT
    v_user_id,
    p_wants_daily,
    p_preferred_hour,
    p_preferred_minute,
    COALESCE(np.timezone, 'UTC'),
    COALESCE(np.locale, 'en'),
    COALESCE(np.os_permission, 'unknown'),
    np.last_os_sync_at,
    np.last_sent_local_date,
    COALESCE(np.created_at, now()),
    now()
  FROM public.notification_preferences np
  WHERE np.user_id = v_user_id
  UNION ALL
  SELECT
    v_user_id,
    p_wants_daily,
    p_preferred_hour,
    p_preferred_minute,
    'UTC',
    'en',
    'unknown',
    NULL,
    NULL,
    now(),
    now()
  WHERE NOT EXISTS (
    SELECT 1 FROM public.notification_preferences WHERE user_id = v_user_id
  )
  ON CONFLICT (user_id) DO UPDATE
    SET wants_daily     = EXCLUDED.wants_daily,
        preferred_hour  = EXCLUDED.preferred_hour,
        preferred_minute = EXCLUDED.preferred_minute,
        updated_at      = EXCLUDED.updated_at
  RETURNING * INTO v_pref;

  RETURN v_pref;
END;
$$;


ALTER FUNCTION "public"."notifications_update_preferences"("p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_update_send_status"("p_send_id" "uuid", "p_status" "text", "p_error" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  UPDATE public.notification_sends
  SET status    = p_status,
      error     = p_error,
      failed_at = CASE WHEN p_status = 'failed' THEN now() ELSE failed_at END,
      updated_at = now()
  WHERE id = p_send_id;
END;
$$;


ALTER FUNCTION "public"."notifications_update_send_status"("p_send_id" "uuid", "p_status" "text", "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  IF p_event_type NOT IN ('impression', 'cta_click', 'dismiss', 'restore_attempt') THEN
    PERFORM public.api_error(
      'INVALID_EVENT',
      'Unsupported paywall event type.',
      '22023'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.home_id = p_home_id
      AND m.is_current = TRUE
  ) THEN
    PERFORM public.api_error(
      'HOME_NOT_MEMBER',
      'You are not a current member of this home.',
      '42501'
    );
  END IF;

  INSERT INTO public.paywall_events (user_id, home_id, event_type, source)
  VALUES (v_user, p_home_id, p_event_type, p_source);
END;
$$;


ALTER FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text") IS 'Auth-only helper to log paywall funnel events for a home.';



CREATE OR REPLACE FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[] DEFAULT NULL::"text"[], "p_event_timestamp" timestamp with time zone DEFAULT "now"(), "p_environment" "text" DEFAULT 'unknown'::"text", "p_rc_event_id" "text" DEFAULT NULL::"text", "p_original_transaction_id" "text" DEFAULT NULL::"text", "p_raw_event" "jsonb" DEFAULT NULL::"jsonb", "p_warnings" "text"[] DEFAULT NULL::"text"[]) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_status public.revenuecat_processing_status;
  v_home_id uuid;
BEGIN
  -- Prevent concurrent double-runs for the same idempotency key
  PERFORM pg_advisory_xact_lock(hashtext(p_environment || ':' || p_idempotency_key));

  -- Basic validation (defense in depth; webhook already validated)
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'Missing p_idempotency_key';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Missing p_user_id';
  END IF;

  -- home_id may be null (floating sub); allow nullable to align with edge behavior

  -- Acquire processing record (or reuse)
  INSERT INTO public.revenuecat_event_processing AS ep (environment, idempotency_key, status, attempts, updated_at)
  VALUES (p_environment, p_idempotency_key, 'processing'::public.revenuecat_processing_status, 1, now())
  ON CONFLICT (environment, idempotency_key)
  DO UPDATE SET
    attempts   = ep.attempts + 1,
    status     = CASE
                  WHEN ep.status = 'succeeded' THEN 'succeeded'::public.revenuecat_processing_status
                  ELSE 'processing'::public.revenuecat_processing_status
                 END,
    updated_at = now()
  RETURNING status INTO v_status;

  -- If already succeeded, return immediately (idempotent)
  IF v_status = 'succeeded'::public.revenuecat_processing_status THEN
    RETURN true; -- deduped
  END IF;

  ------------------------------------------------------------------
  -- Upsert subscription snapshot
  ------------------------------------------------------------------
  INSERT INTO public.user_subscriptions AS us (
    user_id,
    home_id,
    store,
    rc_app_user_id,
    rc_entitlement_id,
    product_id,
    status,
    current_period_end_at,
    original_purchase_at,
    last_purchase_at,
    latest_transaction_id,
    last_synced_at,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_home_id,
    p_store,
    p_rc_app_user_id,
    p_entitlement_id,
    p_product_id,
    p_status,
    p_current_period_end_at,
    p_original_purchase_at,
    p_last_purchase_at,
    p_latest_transaction_id,
    now(),
    now(),
    now()
  )
  ON CONFLICT (user_id, rc_entitlement_id) DO UPDATE
  SET
    home_id               = EXCLUDED.home_id,
    store                 = EXCLUDED.store,
    rc_app_user_id        = EXCLUDED.rc_app_user_id,
    product_id            = EXCLUDED.product_id,
    status                = EXCLUDED.status,
    current_period_end_at = EXCLUDED.current_period_end_at,
    original_purchase_at  = EXCLUDED.original_purchase_at,
    last_purchase_at      = EXCLUDED.last_purchase_at,
    latest_transaction_id = EXCLUDED.latest_transaction_id,
    last_synced_at        = now(),
    updated_at            = now()
  RETURNING home_id INTO v_home_id;

  ------------------------------------------------------------------
  -- Optional: log inside RPC too (safe upsert)
  ------------------------------------------------------------------
INSERT INTO public.revenuecat_webhook_events (
  created_at,
  event_timestamp,
  environment,
  idempotency_key,
  rc_event_id,
  original_transaction_id,
  latest_transaction_id,
  rc_app_user_id,
  home_id,
  entitlement_id,
  entitlement_ids,
  product_id,
  store,
  status,
  current_period_end_at,
  original_purchase_at,
  last_purchase_at,
  warnings,
  raw
) VALUES (
  now(),
  p_event_timestamp,
  p_environment,
  p_idempotency_key,
  p_rc_event_id,
  p_original_transaction_id,
  p_latest_transaction_id,
  p_rc_app_user_id,
  COALESCE(p_home_id, v_home_id),
  p_entitlement_id,
  p_entitlement_ids,
  p_product_id,
  p_store,
  p_status,
  p_current_period_end_at,
  p_original_purchase_at,
  p_last_purchase_at,
  p_warnings,
  p_raw_event
)
ON CONFLICT (environment, idempotency_key)
WHERE idempotency_key IS NOT NULL
DO NOTHING;

  ------------------------------------------------------------------
  -- Refresh home entitlements
  ------------------------------------------------------------------
  PERFORM public.home_entitlements_refresh(COALESCE(p_home_id, v_home_id));

  -- Mark succeeded
  UPDATE public.revenuecat_event_processing
  SET status = 'succeeded'::public.revenuecat_processing_status, last_error = NULL, updated_at = now()
  WHERE environment = p_environment AND idempotency_key = p_idempotency_key;

  RETURN false; -- processed now

EXCEPTION
  WHEN OTHERS THEN
    -- Mark failed (so retries can reattempt)
  UPDATE public.revenuecat_event_processing
  SET status = 'failed'::public.revenuecat_processing_status, last_error = SQLERRM, updated_at = now()
  WHERE environment = p_environment AND idempotency_key = p_idempotency_key;

    RAISE;
END;
$$;


ALTER FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[], "p_event_timestamp" timestamp with time zone, "p_environment" "text", "p_rc_event_id" "text", "p_original_transaction_id" "text", "p_raw_event" "jsonb", "p_warnings" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[], "p_event_timestamp" timestamp with time zone, "p_environment" "text", "p_rc_event_id" "text", "p_original_transaction_id" "text", "p_raw_event" "jsonb", "p_warnings" "text"[]) IS 'Idempotent service-role helper invoked by RevenueCat webhook. Safe for retries via revenuecat_event_processing. Returns deduped boolean.';



CREATE OR REPLACE FUNCTION "public"."paywall_status_get"("p_home_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_plan           text;
  v_now            timestamptz := now();
BEGIN
  PERFORM public._assert_home_member(p_home_id);

  SELECT COALESCE(he.plan, 'free')
    INTO v_plan
    FROM public.home_entitlements he
   WHERE he.home_id = p_home_id;

  RETURN jsonb_build_object(
    'plan', v_plan,
    'is_premium', (v_plan <> 'free'),
    'has_ai',     (v_plan = 'premium_ai'),
    'usage', COALESCE((
      SELECT jsonb_build_object(
        'active_chores',   c.active_chores,
        'chore_photos',    c.chore_photos,
        'active_members',  c.active_members,
        'active_expenses', c.active_expenses,
        'updated_at',      c.updated_at
      )
      FROM public.home_usage_counters c
      WHERE c.home_id = p_home_id
    ), jsonb_build_object(
      'active_chores', 0,
      'chore_photos', 0,
      'active_members', 0,
      'active_expenses', 0,
      'updated_at', v_now
    )),

    'limits', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'metric',    x.metric::text,
          'max_value', x.max_value
        )
        ORDER BY x.metric::text
      )
      FROM (
        SELECT l.metric, l.max_value
        FROM public.home_plan_limits l
        WHERE l.plan = v_plan
      ) x
    ), '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."paywall_status_get"("p_home_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."personal_gratitude_inbox_list_v1"("p_limit" integer DEFAULT 30, "p_before_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "created_at" timestamp with time zone, "home_id" "uuid", "mood" "public"."mood_scale", "message" "text", "source_kind" "text", "source_post_id" "uuid", "source_entry_id" "uuid", "author_user_id" "uuid", "author_username" "public"."citext", "author_avatar_id" "uuid", "author_avatar_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  p_limit := GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));

  -- Enforce: both cursor parts must be provided together, or neither.
  PERFORM public.api_assert(
    (p_before_at IS NULL AND p_before_id IS NULL)
    OR (p_before_at IS NOT NULL AND p_before_id IS NOT NULL),
    'INVALID_PAGINATION_CURSOR',
    'Pagination cursor requires both before_at and before_id, or neither.',
    '22023',
    jsonb_build_object('before_at', p_before_at, 'before_id', p_before_id)
  );

  RETURN QUERY
  SELECT
    i.id,
    i.created_at,
    i.home_id,
    i.mood,
    i.message,
    i.source_kind,
    i.source_post_id,
    i.source_entry_id,

    p.id           AS author_user_id,
    p.username     AS author_username,
    p.avatar_id    AS author_avatar_id,
    a.storage_path AS author_avatar_path
  FROM public.gratitude_wall_personal_items i
  JOIN public.profiles p
    ON p.id = i.author_user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE i.recipient_user_id = v_user_id
    AND (
      p_before_at IS NULL
      OR i.created_at < p_before_at
      OR (i.created_at = p_before_at AND i.id < p_before_id)
    )
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT p_limit;
END;
$$;


ALTER FUNCTION "public"."personal_gratitude_inbox_list_v1"("p_limit" integer, "p_before_at" timestamp with time zone, "p_before_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."personal_gratitude_inbox_list_v1"("p_limit" integer, "p_before_at" timestamp with time zone, "p_before_id" "uuid") IS 'Recipient personal gratitude inbox list (paged). Resolves author username + avatar storage_path at read time. Cursor requires both before_at and before_id.';



CREATE OR REPLACE FUNCTION "public"."personal_gratitude_showcase_stats_v1"("p_exclude_self" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_total   bigint;
  v_authors bigint;
  v_homes   bigint;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT
    COUNT(*)::bigint,
    COUNT(DISTINCT i.author_user_id)::bigint,
    COUNT(DISTINCT i.home_id)::bigint
  INTO v_total, v_authors, v_homes
  FROM public.gratitude_wall_personal_items i
  WHERE i.recipient_user_id = v_user_id
    AND (NOT p_exclude_self OR i.author_user_id <> v_user_id);

  RETURN jsonb_build_object(
    'total_received',     COALESCE(v_total, 0),
    'unique_individuals', COALESCE(v_authors, 0),
    'unique_homes',       COALESCE(v_homes, 0)
  );
END;
$$;


ALTER FUNCTION "public"."personal_gratitude_showcase_stats_v1"("p_exclude_self" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."personal_gratitude_showcase_stats_v1"("p_exclude_self" boolean) IS 'Showcase stats for auth.uid() from personal gratitude inbox: total received items, unique authors, unique homes.';



CREATE OR REPLACE FUNCTION "public"."personal_gratitude_wall_mark_read_v1"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  INSERT INTO public.gratitude_wall_personal_reads (user_id, last_read_at)
  VALUES (v_user_id, now())
  ON CONFLICT (user_id)
  DO UPDATE SET last_read_at = EXCLUDED.last_read_at;

  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."personal_gratitude_wall_mark_read_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."personal_gratitude_wall_status_v1"() RETURNS TABLE("has_unread" boolean, "last_read_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id           uuid := auth.uid();
  v_latest_created_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT r.last_read_at
    INTO last_read_at
  FROM public.gratitude_wall_personal_reads r
  WHERE r.user_id = v_user_id
  LIMIT 1;

  SELECT i.created_at
    INTO v_latest_created_at
  FROM public.gratitude_wall_personal_items i
  WHERE i.recipient_user_id = v_user_id
    AND i.author_user_id <> v_user_id
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT 1;

  has_unread :=
    CASE
      WHEN v_latest_created_at IS NULL THEN FALSE
      WHEN last_read_at IS NULL THEN TRUE
      ELSE v_latest_created_at > last_read_at
    END;

  RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."personal_gratitude_wall_status_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_reports_acknowledge"("p_report_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid := auth.uid();
  v_subject uuid;
  v_status text;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT r.subject_user_id, r.status
    INTO v_subject, v_status
  FROM public.preference_reports r
  WHERE r.id = p_report_id
  LIMIT 1;

  IF v_subject IS NULL THEN
    PERFORM public.api_error('REPORT_NOT_FOUND', 'No preference report found to acknowledge.', 'P0001');
  END IF;

  IF v_status <> 'published' THEN
    PERFORM public.api_error('REPORT_NOT_PUBLISHED', 'Only published reports can be acknowledged.', 'P0001');
  END IF;

  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships a
      JOIN public.memberships b
        ON b.home_id = a.home_id
       AND b.user_id = v_subject
       AND b.is_current = true
      WHERE a.user_id = v_user
        AND a.is_current = true
    ),
    'NOT_IN_SAME_HOME',
    'You can only acknowledge reports for someone in a home you share.',
    '22023'
  );

  INSERT INTO public.preference_report_acknowledgements (
    report_id, viewer_user_id, acknowledged_at
  ) VALUES (
    p_report_id, v_user, now()
  )
  ON CONFLICT (report_id, viewer_user_id) DO NOTHING;

  RETURN jsonb_build_object('ok', true);
END;
$$;


ALTER FUNCTION "public"."preference_reports_acknowledge"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_reports_edit_section_text"("p_template_key" "text", "p_locale" "text", "p_section_key" "text", "p_new_text" "text", "p_change_summary" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_user uuid := auth.uid();
  v_report public.preference_reports%ROWTYPE;

  v_sections jsonb;
  v_new_sections jsonb;
  v_match_count int := 0;

  v_new_content jsonb;
  v_old_text text;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  PERFORM public.api_assert(
    p_section_key IS NOT NULL AND length(trim(p_section_key)) > 0
      AND p_section_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_SECTION_KEY',
    'Section key is required and must match ^[a-z0-9_]{1,64}$.',
    '22023'
  );

  PERFORM public.api_assert(
    p_new_text IS NOT NULL,
    'INVALID_TEXT',
    'Section text cannot be null.',
    '22023'
  );

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = v_user
    AND r.template_key = p_template_key
    AND r.locale = p_locale
    AND r.status = 'published'
  LIMIT 1;

  IF v_report.id IS NULL THEN
    PERFORM public.api_error(
      'REPORT_NOT_FOUND',
      'No published preference report found to edit.',
      'P0001',
      jsonb_build_object('template_key', p_template_key, 'locale', p_locale)
    );
  END IF;

  -- Advisory lock per report
  PERFORM pg_advisory_xact_lock(hashtextextended(v_report.id::text, 0));

  v_sections := v_report.published_content->'sections';

  PERFORM public.api_assert(
    jsonb_typeof(v_sections) = 'array',
    'INVALID_REPORT_SHAPE',
    'published_content.sections must be an array.',
    '22023'
  );

  SELECT COUNT(*)
    INTO v_match_count
  FROM jsonb_array_elements(v_sections) AS s(value)
  WHERE (value->>'section_key') = p_section_key;

  PERFORM public.api_assert(
    v_match_count = 1,
    'SECTION_NOT_FOUND_OR_DUPLICATE',
    'Expected exactly 1 section with the given section_key.',
    '22023',
    jsonb_build_object('section_key', p_section_key, 'match_count', v_match_count)
  );

  -- no-op if unchanged
  SELECT (value->>'text')
    INTO v_old_text
  FROM jsonb_array_elements(v_sections) AS s(value)
  WHERE (value->>'section_key') = p_section_key
  LIMIT 1;

  IF v_old_text IS NOT DISTINCT FROM p_new_text THEN
    RETURN jsonb_build_object('ok', true, 'report_id', v_report.id, 'status', 'unchanged');
  END IF;

  -- rebuild sections
  SELECT COALESCE(
    jsonb_agg(
      CASE
        WHEN (value->>'section_key') = p_section_key THEN
          (value || jsonb_build_object('text', to_jsonb(p_new_text)))
        ELSE
          value
      END
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_new_sections
  FROM jsonb_array_elements(v_sections) WITH ORDINALITY AS e(value, ord);

  v_new_content := jsonb_set(v_report.published_content, '{sections}', v_new_sections, true);

  UPDATE public.preference_reports
     SET published_content = v_new_content,
         last_edited_at = now(),
         last_edited_by = v_user
   WHERE id = v_report.id;

  INSERT INTO public.preference_report_revisions (
    report_id, editor_user_id, edited_at, content, change_summary
  ) VALUES (
    v_report.id, v_user, now(), v_new_content,
    COALESCE(p_change_summary, 'Edited section ' || p_section_key)
  );

  RETURN jsonb_build_object('ok', true, 'report_id', v_report.id, 'status', 'edited');
END;
$_$;


ALTER FUNCTION "public"."preference_reports_edit_section_text"("p_template_key" "text", "p_locale" "text", "p_section_key" "text", "p_new_text" "text", "p_change_summary" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_reports_generate"("p_template_key" "text", "p_locale" "text", "p_force" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_user uuid := auth.uid();

  v_template public.preference_report_templates%ROWTYPE;
  v_report public.preference_reports%ROWTYPE;

  v_all_pref_ids text[];
  v_answered_pref_ids text[];

  v_responses jsonb;
  v_resolved jsonb;

  v_unresolved_missing jsonb;
  v_unresolved_nulls jsonb;
  v_unresolved jsonb;

  v_sections jsonb;

  v_generated jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  -- normalize to base locale for templates/reports
  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  -- Collision-safe advisory lock per (user, key, locale)
  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_user::text || ':' || p_template_key || ':' || p_locale, 0)
  );

  SELECT *
    INTO v_template
  FROM public.preference_report_templates t
  WHERE t.template_key = p_template_key
    AND t.locale = p_locale
  LIMIT 1;

  IF v_template.id IS NULL THEN
    PERFORM public.api_error(
      'TEMPLATE_NOT_FOUND',
      'No preference report template found for the requested key/locale.',
      'P0001',
      jsonb_build_object('template_key', p_template_key, 'locale', p_locale)
    );
  END IF;

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = v_user
    AND r.template_key = p_template_key
    AND r.locale = p_locale
  LIMIT 1;

  IF v_report.id IS NOT NULL
     AND p_force = false
     AND v_report.status <> 'out_of_date' THEN
    RETURN jsonb_build_object('ok', true, 'report_id', v_report.id, 'status', 'unchanged');
  END IF;

  -- all_pref_ids := active taxonomy defs
  SELECT COALESCE(array_agg(t.preference_id ORDER BY t.preference_id), ARRAY[]::text[])
    INTO v_all_pref_ids
  FROM public.preference_taxonomy t
  JOIN public.preference_taxonomy_defs d USING (preference_id)
  WHERE t.is_active = true;

  PERFORM public.api_assert(
    COALESCE(array_length(v_all_pref_ids, 1), 0) > 0,
    'INVALID_TAXONOMY_STATE',
    'No active preference taxonomy defs exist; cannot generate report.',
    '22023'
  );

  -- answered_pref_ids := responses for user
  SELECT COALESCE(array_agg(pr.preference_id ORDER BY pr.preference_id), ARRAY[]::text[])
    INTO v_answered_pref_ids
  FROM public.preference_responses pr
  WHERE pr.user_id = v_user;

  -- responses/resolved for answered only
  WITH resolved_rows AS (
    SELECT
      pr.preference_id,
      pr.option_index,
      (v_template.body->'preferences'->pr.preference_id->(pr.option_index::int)) AS resolved_obj
    FROM public.preference_responses pr
    WHERE pr.user_id = v_user
  )
  SELECT
    COALESCE(jsonb_object_agg(preference_id, option_index), '{}'::jsonb),
    COALESCE(jsonb_object_agg(preference_id, resolved_obj), '{}'::jsonb),
    COALESCE(
      jsonb_agg(preference_id)
        FILTER (WHERE resolved_obj IS NULL OR resolved_obj = 'null'::jsonb),
      '[]'::jsonb
    )
  INTO v_responses, v_resolved, v_unresolved_nulls
  FROM resolved_rows;

  -- unresolved_missing := all_pref_ids EXCEPT answered_pref_ids
  SELECT COALESCE(
    jsonb_agg(x),
    '[]'::jsonb
  )
  INTO v_unresolved_missing
  FROM (
    SELECT unnest(v_all_pref_ids) AS x
    EXCEPT
    SELECT unnest(v_answered_pref_ids) AS x
  ) s;

  -- unresolved := union(missing, nulls), dedup
  SELECT COALESCE(
    jsonb_agg(DISTINCT e.value),
    '[]'::jsonb
  )
  INTO v_unresolved
  FROM jsonb_array_elements(v_unresolved_missing || v_unresolved_nulls) AS e(value);

  -- Build personalized section text from resolved preferences by domain.
  v_sections := v_template.body->'sections';

  WITH section_items AS (
    SELECT value AS section, ord
    FROM jsonb_array_elements(v_sections) WITH ORDINALITY AS e(value, ord)
  ),
  resolved_texts AS (
    SELECT
      d.domain,
      pr.preference_id,
      (v_template.body->'preferences'->pr.preference_id->(pr.option_index::int)->>'text') AS text
    FROM public.preference_responses pr
    JOIN public.preference_taxonomy t USING (preference_id)
    JOIN public.preference_taxonomy_defs d USING (preference_id)
    WHERE pr.user_id = v_user
      AND t.is_active = true
  ),
  per_domain AS (
    SELECT
      domain,
      string_agg(text, ' ' ORDER BY preference_id) AS section_text
    FROM resolved_texts
    WHERE text IS NOT NULL AND btrim(text) <> ''
    GROUP BY domain
  )
  SELECT COALESCE(
    jsonb_agg(
      CASE
        WHEN pd.section_text IS NULL OR btrim(pd.section_text) = '' THEN section
        ELSE jsonb_set(section, '{text}', to_jsonb(pd.section_text), true)
      END
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_sections
  FROM section_items si
  LEFT JOIN per_domain pd
    ON pd.domain = (si.section->>'section_key');

  v_generated := jsonb_build_object(
    'template_key', p_template_key,
    'locale', p_locale,
    'summary', v_template.body->'summary',
    'sections', v_sections,
    'responses', v_responses,
    'resolved', v_resolved,
    'unresolved_pref_ids', v_unresolved
  );

  INSERT INTO public.preference_reports (
    subject_user_id,
    template_key,
    locale,
    status,
    generated_content,
    published_content,
    generated_at,
    published_at
  ) VALUES (
    v_user,
    p_template_key,
    p_locale,
    'published',
    v_generated,
    v_generated,
    now(),
    now()
  )
  ON CONFLICT (subject_user_id, template_key, locale)
  DO UPDATE SET
    status            = 'published',
    generated_content = EXCLUDED.generated_content,
    generated_at      = EXCLUDED.generated_at,

    -- never-edited rule
    published_content =
      CASE
        WHEN public.preference_reports.last_edited_at IS NULL
          THEN EXCLUDED.published_content
        ELSE public.preference_reports.published_content
      END,

    published_at =
      CASE
        WHEN public.preference_reports.last_edited_at IS NULL
          THEN EXCLUDED.published_at
        ELSE public.preference_reports.published_at
      END
  RETURNING * INTO v_report;

  RETURN jsonb_build_object(
    'ok', true,
    'report_id', v_report.id,
    'status', 'generated',
    'unresolved_pref_ids', v_unresolved
  );
END;
$_$;


ALTER FUNCTION "public"."preference_reports_generate"("p_template_key" "text", "p_locale" "text", "p_force" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_reports_get_for_home"("p_home_id" "uuid", "p_subject_user_id" "uuid", "p_template_key" "text", "p_locale" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_report public.preference_reports%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  -- only current members visible
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      WHERE m.home_id = p_home_id
        AND m.user_id = p_subject_user_id
        AND m.is_current = true
    ),
    'SUBJECT_NOT_IN_HOME',
    'Subject user is not a current member of this home.',
    '22023'
  );

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = p_subject_user_id
    AND r.template_key = p_template_key
    AND r.locale = p_locale
    AND r.status = 'published'
  LIMIT 1;

  IF v_report.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'found', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'found', true,
    'report', jsonb_build_object(
      'id', v_report.id,
      'subject_user_id', v_report.subject_user_id,
      'template_key', v_report.template_key,
      'locale', v_report.locale,
      'published_at', v_report.published_at,
      'published_content', v_report.published_content,
      'last_edited_at', v_report.last_edited_at,
      'last_edited_by', v_report.last_edited_by
    )
  );
END;
$_$;


ALTER FUNCTION "public"."preference_reports_get_for_home"("p_home_id" "uuid", "p_subject_user_id" "uuid", "p_template_key" "text", "p_locale" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_reports_get_personal_v1"("p_template_key" "text" DEFAULT 'personal_preferences_v1'::"text", "p_locale" "text" DEFAULT 'en'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_user   uuid;
  v_report public.preference_reports%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  -- We accept "en" or "en-NZ" style values, but normalize to a base language.
  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ). It will be normalized to a base language.',
    '22023'
  );

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Supported base languages are: en, es, ar.',
    '22023'
  );

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = v_user
    AND r.template_key = p_template_key
    AND r.locale = p_locale
    AND r.status = 'published'
  ORDER BY r.published_at DESC NULLS LAST, r.generated_at DESC, r.id DESC
  LIMIT 1;

  IF v_report.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'found', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'found', true,
    'report', jsonb_build_object(
      'id', v_report.id,
      'subject_user_id', v_report.subject_user_id,
      'template_key', v_report.template_key,
      'locale', v_report.locale,
      'published_at', v_report.published_at,
      'published_content', v_report.published_content,
      'last_edited_at', v_report.last_edited_at,
      'last_edited_by', v_report.last_edited_by
    )
  );
END;
$_$;


ALTER FUNCTION "public"."preference_reports_get_personal_v1"("p_template_key" "text", "p_locale" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."preference_reports_get_personal_v1"("p_template_key" "text", "p_locale" "text") IS 'Fetches the caller''s published personal preference report (self-only). Not intended for Start Page gating; use user_context_v1.';



CREATE OR REPLACE FUNCTION "public"."preference_reports_list_for_home"("p_home_id" "uuid", "p_template_key" "text", "p_locale" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Locale must be one of: en, es, ar.',
    '22023'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'items',
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'report_id', r.id,
            'subject_user_id', r.subject_user_id,
            'published_at', r.published_at,
            'last_edited_at', r.last_edited_at
          )
          ORDER BY r.published_at DESC NULLS LAST
        )
        FROM public.memberships m
        JOIN public.preference_reports r
          ON r.subject_user_id = m.user_id
         AND r.template_key = p_template_key
         AND r.locale = p_locale
         AND r.status = 'published'
        WHERE m.home_id = p_home_id
          AND m.is_current = true
      ),
      '[]'::jsonb
    )
  );
END;
$_$;


ALTER FUNCTION "public"."preference_reports_list_for_home"("p_home_id" "uuid", "p_template_key" "text", "p_locale" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_responses_submit"("p_answers" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_user uuid := auth.uid();

  v_tax_keys text[];
  v_answer_keys text[];

  v_extra text[];
  v_missing text[];

  v_bad_value_keys jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    jsonb_typeof(p_answers) = 'object',
    'INVALID_ANSWERS',
    'Answers must be a JSON object of { preference_id: option_index }.',
    '22023',
    jsonb_build_object('expected', 'object')
  );

  -- Active taxonomy keys (must have defs)
  SELECT COALESCE(array_agg(t.preference_id ORDER BY t.preference_id), ARRAY[]::text[])
    INTO v_tax_keys
  FROM public.preference_taxonomy t
  JOIN public.preference_taxonomy_defs d USING (preference_id)
  WHERE t.is_active = true;

  PERFORM public.api_assert(
    COALESCE(array_length(v_tax_keys, 1), 0) > 0,
    'INVALID_TAXONOMY_STATE',
    'No active preference taxonomy defs exist; cannot accept answers.',
    '22023'
  );

  -- Answer keys
  SELECT COALESCE(array_agg(k ORDER BY k), ARRAY[]::text[])
    INTO v_answer_keys
  FROM jsonb_object_keys(p_answers) AS k;

  -- Extra keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_extra
  FROM (
    SELECT unnest(v_answer_keys) AS x
    EXCEPT
    SELECT unnest(v_tax_keys) AS x
  ) s;

  -- Missing keys
  SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_missing
  FROM (
    SELECT unnest(v_tax_keys) AS x
    EXCEPT
    SELECT unnest(v_answer_keys) AS x
  ) s;

  PERFORM public.api_assert(
    COALESCE(array_length(v_extra, 1), 0) = 0
    AND COALESCE(array_length(v_missing, 1), 0) = 0,
    'INCOMPLETE_ANSWERS',
    'You must answer every preference in one submission (no missing or extra keys).',
    '22023',
    jsonb_build_object(
      'extra_pref_ids', COALESCE(to_jsonb(v_extra), '[]'::jsonb),
      'missing_pref_ids', COALESCE(to_jsonb(v_missing), '[]'::jsonb)
    )
  );

  -- Validate each value is an integer 0..2 without unsafe casts.
  SELECT COALESCE(
    jsonb_agg(k) FILTER (WHERE NOT (
      CASE
        WHEN jsonb_typeof(p_answers->k) = 'number'
          AND (p_answers->>k) ~ '^[0-9]+$'
          THEN ((p_answers->>k)::int BETWEEN 0 AND 2)
        ELSE false
      END
    )),
    '[]'::jsonb
  )
  INTO v_bad_value_keys
  FROM unnest(v_answer_keys) AS k;

  PERFORM public.api_assert(
    jsonb_array_length(v_bad_value_keys) = 0,
    'INVALID_OPTION_INDEX',
    'All option_index values must be integers between 0 and 2.',
    '22023',
    jsonb_build_object('bad_pref_ids', v_bad_value_keys)
  );

  -- Atomic upsert of full set
  INSERT INTO public.preference_responses (user_id, preference_id, option_index, captured_at)
  SELECT
    v_user,
    k AS preference_id,
    (p_answers->>k)::int2 AS option_index,
    now() AS captured_at
  FROM unnest(v_answer_keys) AS k
  ON CONFLICT (user_id, preference_id)
  DO UPDATE SET
    option_index = EXCLUDED.option_index,
    captured_at  = EXCLUDED.captured_at
  WHERE public.preference_responses.option_index IS DISTINCT FROM EXCLUDED.option_index;

  RETURN jsonb_build_object('ok', true);
END;
$_$;


ALTER FUNCTION "public"."preference_responses_submit"("p_answers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preference_templates_get_for_user"("p_template_key" "text" DEFAULT 'personal_preferences_v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  v_user uuid := auth.uid();
  v_user_locale text;
  v_base text;
  v_resolved text;
  v_template public.preference_report_templates%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  -- Validate template key
  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  -- Read user's locale (e.g. en-NZ) from notification_preferences
  SELECT np.locale
    INTO v_user_locale
  FROM public.notification_preferences np
  WHERE np.user_id = v_user
  LIMIT 1;

  v_base := public.locale_base(v_user_locale);

  -- Only allow supported languages; otherwise fallback to en
  IF v_base NOT IN ('en','es','ar') THEN
    v_base := 'en';
  END IF;

  -- Prefer base match if exists, else fallback en
  SELECT t.*
    INTO v_template
  FROM public.preference_report_templates t
  WHERE t.template_key = p_template_key
    AND t.locale = v_base
  LIMIT 1;

  IF v_template.id IS NOT NULL THEN
    v_resolved := v_base;
  ELSE
    SELECT t.*
      INTO v_template
    FROM public.preference_report_templates t
    WHERE t.template_key = p_template_key
      AND t.locale = 'en'
    LIMIT 1;

    v_resolved := 'en';
  END IF;

  IF v_template.id IS NULL THEN
    PERFORM public.api_error(
      'TEMPLATE_NOT_FOUND',
      'No template found for template_key (neither user locale nor fallback en).',
      'P0001',
      jsonb_build_object(
        'template_key', p_template_key,
        'requested_locale', v_user_locale,
        'base_locale', v_base
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'template_key', v_template.template_key,
    'requested_locale', v_user_locale,
    'resolved_locale', v_resolved,
    'body', v_template.body
  );
END;
$_$;


ALTER FUNCTION "public"."preference_templates_get_for_user"("p_template_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profile_identity_update"("p_username" "public"."citext", "p_avatar_id" "uuid") RETURNS TABLE("username" "public"."citext", "avatar_id" "uuid", "avatar_storage_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
DECLARE
  -- 3–30 chars, start/end alnum, middle may contain . or _
  v_re              text := '^[A-Za-z0-9][A-Za-z0-9._]{1,28}[A-Za-z0-9]$';
  v_user            uuid := auth.uid();
  v_home_id         uuid;
  v_plan            text;
  v_avatar_category text;
BEGIN
  PERFORM public._assert_authenticated();

  --------------------------------------------------------------------
  -- 1. Validate username shape
  --------------------------------------------------------------------
  IF p_username IS NULL OR p_username !~ v_re THEN
    PERFORM public.api_error(
      'INVALID_USERNAME',
      'Username must be 3–30 chars, start/end with letter/number, may contain . or _',
      '22000'
    );
  END IF;

  --------------------------------------------------------------------
  -- 2. Ensure avatar exists + get its category
  --------------------------------------------------------------------
  SELECT a.category
  INTO v_avatar_category
  FROM public.avatars a
  WHERE a.id = p_avatar_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'AVATAR_NOT_FOUND',
      'Selected avatar does not exist.',
      '22000',
      jsonb_build_object('avatar_id', p_avatar_id)
    );
  END IF;

  --------------------------------------------------------------------
  -- 3. Derive current home (if any) and enforce plan + uniqueness
  --------------------------------------------------------------------
  SELECT m.home_id
  INTO v_home_id
  FROM public.memberships m
  WHERE m.user_id = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF v_home_id IS NOT NULL THEN
    -- Use shared helper for effective plan (same logic as avatars_list_for_home)
    v_plan := public._home_effective_plan(v_home_id);

    -- Plan gating: free homes can only use 'animal' avatars
    IF v_plan = 'free' AND v_avatar_category <> 'animal' THEN
      PERFORM public.api_error(
        'AVATAR_NOT_ALLOWED_FOR_PLAN',
        'This avatar is not available on the free plan for your home.',
        '22000',
        jsonb_build_object(
          'avatar_id', p_avatar_id,
          'home_id',   v_home_id,
          'plan',      v_plan
        )
      );
    END IF;

    -- Uniqueness within this home: no other current member uses this avatar
    PERFORM 1
    FROM public.memberships m
    JOIN public.profiles  p
      ON p.id = m.user_id
    WHERE m.home_id = v_home_id
      AND m.is_current = TRUE
      AND p.deactivated_at IS NULL
      AND p.avatar_id = p_avatar_id
      AND p.id <> v_user;

    IF FOUND THEN
      PERFORM public.api_error(
        'AVATAR_IN_USE',
        'This avatar is already used by another current member of your home.',
        '22000',
        jsonb_build_object(
          'avatar_id', p_avatar_id,
          'home_id',   v_home_id
        )
      );
    END IF;
  END IF;

  --------------------------------------------------------------------
  -- 4. Perform update, handling "no active profile" + username clash
  --------------------------------------------------------------------
  BEGIN
    UPDATE public.profiles
    SET
      username   = p_username,
      avatar_id  = p_avatar_id,
      updated_at = now()
    WHERE id = v_user
      AND deactivated_at IS NULL;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'PROFILE_NOT_FOUND',
        'Active profile not found for current user.',
        '22000'
      );
    END IF;

  EXCEPTION
    WHEN unique_violation THEN
      -- assumes a unique index on profiles(username)
      PERFORM public.api_error(
        'USERNAME_TAKEN',
        'This username is already in use.',
        '23505'
      );
  END;

  --------------------------------------------------------------------
  -- 5. Return updated identity
  --------------------------------------------------------------------
  RETURN QUERY
  SELECT
    p.username,
    p.avatar_id,
    a.storage_path
  FROM public.profiles p
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = v_user
    AND p.deactivated_at IS NULL;
END;
$_$;


ALTER FUNCTION "public"."profile_identity_update"("p_username" "public"."citext", "p_avatar_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profile_me"() RETURNS TABLE("user_id" "uuid", "username" "public"."citext", "avatar_storage_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  PERFORM public._assert_authenticated();

  RETURN QUERY
  SELECT
    p.id           AS user_id,
    p.username     AS username,
    a.storage_path AS avatar_storage_path
  FROM public.profiles p
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = auth.uid()
    AND p.deactivated_at IS NULL;
END;
$$;


ALTER FUNCTION "public"."profile_me"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profiles_request_deactivation"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user           uuid := auth.uid();
  v_home_id        uuid;
  v_deactivated_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();

  -- Find the caller's current home (at most one is allowed today)
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user
     AND m.is_current
   LIMIT 1;

  -- Leave the home first; bubbles OWNER_MUST_TRANSFER_FIRST if needed
  IF v_home_id IS NOT NULL THEN
    PERFORM public.homes_leave(v_home_id);
  END IF;

  -- Mark profile as deactivated (idempotent)
  UPDATE public.profiles p
     SET deactivated_at = COALESCE(p.deactivated_at, now()),
         updated_at     = now()
   WHERE p.id = v_user
  RETURNING deactivated_at INTO v_deactivated_at;

  IF v_deactivated_at IS NULL THEN
    PERFORM public.api_error(
      'PROFILE_NOT_FOUND',
      'Profile not found for current user.',
      'P0002',
      jsonb_build_object('user_id', v_user)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', 'DEACTIVATION_REQUESTED',
    'data', jsonb_build_object(
      'deactivated_at', v_deactivated_at
    )
  );
END;
$$;


ALTER FUNCTION "public"."profiles_request_deactivation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
begin
  perform public._assert_authenticated();

  if p_home_id is not null then
    perform public._assert_home_member(p_home_id);
    perform public._assert_home_active(p_home_id);
  end if;

  perform public._share_log_event_internal(
    p_user_id      => v_user_id,
    p_home_id      => p_home_id,
    p_feature      => p_feature,
    p_channel      => p_channel
  );
end;
$$;


ALTER FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") IS 'Records a share attempt for the current user with feature and channel.';



CREATE OR REPLACE FUNCTION "public"."today_flow_list"("p_home_id" "uuid", "p_state" "public"."chore_state", "p_local_date" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("id" "uuid", "home_id" "uuid", "name" "text", "start_date" "date", "state" "public"."chore_state")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT
    id,
    home_id,
    name,
    current_due_on AS start_date,
    state
  FROM public._chores_base_for_home(p_home_id)
  WHERE state = p_state
    AND current_due_on <= p_local_date  -- client-local day boundary
    AND (
      (p_state = 'draft'::public.chore_state AND created_by_user_id = auth.uid())
      OR (p_state = 'active'::public.chore_state AND assignee_user_id = auth.uid())
    )
  ORDER BY current_due_on ASC, created_at ASC;
$$;


ALTER FUNCTION "public"."today_flow_list"("p_home_id" "uuid", "p_state" "public"."chore_state", "p_local_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."today_has_content"("p_user_id" "uuid", "p_timezone" "text", "p_local_date" "date") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_home_id  uuid;
  v_prev_sub text := current_setting('request.jwt.claim.sub', true);
  v_has      boolean := FALSE;
BEGIN
  -- Use the user's current home membership (one active stint enforced by uq_memberships_user_one_current)
  SELECT home_id
  INTO v_home_id
  FROM public.memberships
  WHERE user_id = p_user_id
    AND is_current = TRUE
  LIMIT 1;

  IF v_home_id IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Impersonate the user for existing RPCs that rely on auth.uid()
  PERFORM set_config('request.jwt.claim.sub', p_user_id::text, true);

  -- Flow/chores: active or draft, due now or overdue (per today_flow_list)
  v_has := EXISTS (
    SELECT 1 FROM public.today_flow_list(v_home_id, 'active')
  ) OR EXISTS (
    SELECT 1 FROM public.today_flow_list(v_home_id, 'draft')
  );

  IF v_has THEN
    PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
    RETURN TRUE;
  END IF;

  -- Expenses: owed to others or created by me
  v_has := (
    SELECT COALESCE(jsonb_array_length(public.expenses_get_current_owed(v_home_id)), 0)
  ) > 0;

  IF v_has THEN
    PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
    RETURN TRUE;
  END IF;

  v_has := (
    SELECT COALESCE(jsonb_array_length(public.expenses_get_created_by_me(v_home_id)), 0)
  ) > 0;

  IF v_has THEN
    PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
    RETURN TRUE;
  END IF;

  -- Gratitude: unread posts
  v_has := EXISTS (
    SELECT 1 FROM public.gratitude_wall_status(v_home_id)
    WHERE has_unread IS TRUE
  );

  -- Restore previous sub claim (best-effort)
  PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
  RETURN v_has;
END;
$$;


ALTER FUNCTION "public"."today_has_content"("p_user_id" "uuid", "p_timezone" "text", "p_local_date" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."today_has_content"("p_user_id" "uuid", "p_timezone" "text", "p_local_date" "date") IS 'Returns true when any Today content exists for the user (Flow, expenses owed/created, gratitude unread).';



CREATE OR REPLACE FUNCTION "public"."today_onboarding_hints"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  DECLARE
    v_user_id uuid := auth.uid();
    v_home_id uuid;

    v_lifetime_authored_chore_count int := 0;

    v_notif_os_permission text := 'unknown';
    v_notif_wants_daily boolean := FALSE;

    v_has_flatmate_invite_share boolean := FALSE;
    v_has_invite_share boolean := FALSE;

    v_prompt_notifications boolean := FALSE;
    v_prompt_flatmate_invite_share boolean := FALSE;
    v_prompt_invite_share boolean := FALSE;

    v_member_cap_payload jsonb := NULL;
    v_member_cap_resolution jsonb := NULL;
    v_resolution_request_id uuid := NULL;
    v_home_plan text;
    v_is_owner boolean := FALSE;
  BEGIN
    PERFORM public._assert_authenticated();

    SELECT m.home_id, (m.role = 'owner')
      INTO v_home_id, v_is_owner
      FROM public.memberships AS m
     WHERE m.user_id    = v_user_id
       AND m.is_current = TRUE
     LIMIT 1;

    IF v_home_id IS NULL THEN
      RETURN jsonb_build_object(
        'userAuthoredChoreCountLifetime', 0,
        'shouldPromptNotifications', FALSE,
        'shouldPromptFlatmateInviteShare', FALSE,
        'shouldPromptInviteShare', FALSE,
        'memberCapJoinRequests', 'null'::jsonb,
        'memberCapJoinResolution', 'null'::jsonb
      );
    END IF;

    PERFORM public._assert_home_member(v_home_id);
    PERFORM public._assert_home_active(v_home_id);

    SELECT plan
      INTO v_home_plan
      FROM public.home_entitlements
     WHERE home_id = v_home_id;

    SELECT COUNT(*)
      INTO v_lifetime_authored_chore_count
      FROM public.chores AS c
     WHERE c.created_by_user_id = v_user_id;

    SELECT
      COALESCE(np.os_permission, 'unknown'),
      COALESCE(np.wants_daily, FALSE)
    INTO v_notif_os_permission, v_notif_wants_daily
    FROM public.notification_preferences AS np
    WHERE np.user_id = v_user_id
    LIMIT 1;

    SELECT EXISTS (
      SELECT 1
        FROM public.share_events AS se
       WHERE se.user_id = v_user_id
         AND se.feature = 'invite_housemate'
         AND se.channel IS NOT NULL
    )
    INTO v_has_flatmate_invite_share;

    SELECT EXISTS (
      SELECT 1
        FROM public.share_events AS se
       WHERE se.user_id = v_user_id
         AND se.feature = 'invite_button'
         AND se.channel IS NOT NULL
    )
    INTO v_has_invite_share;

    IF v_notif_os_permission = 'unknown'
       AND v_lifetime_authored_chore_count >= 1 THEN
      v_prompt_notifications := TRUE;

    ELSIF v_lifetime_authored_chore_count >= 2
          AND NOT v_has_flatmate_invite_share THEN
      v_prompt_flatmate_invite_share := TRUE;

    ELSIF v_lifetime_authored_chore_count >= 5
          AND NOT v_has_invite_share THEN
      v_prompt_invite_share := TRUE;
    END IF;

    IF v_is_owner IS TRUE AND v_home_plan = 'free' THEN
      SELECT jsonb_build_object(
        'homeId', v_home_id,
        'pendingCount', COUNT(*),
        'joinerNames', COALESCE(
          jsonb_agg(p.username ORDER BY r.created_at ASC)
            FILTER (WHERE p.username IS NOT NULL),
          '[]'::jsonb
        ),
        'requestIds', COALESCE(
          jsonb_agg(r.id ORDER BY r.created_at ASC),
          '[]'::jsonb
        )
      )
      INTO v_member_cap_payload
      FROM public.member_cap_join_requests r
      LEFT JOIN public.profiles p ON p.id = r.joiner_user_id
      WHERE r.home_id = v_home_id
        AND r.resolved_at IS NULL;
    END IF;

    IF v_is_owner IS TRUE AND v_home_plan = 'premium' THEN
      SELECT jsonb_build_object(
        'requestId', r.id,
        'joinerName', COALESCE(p.username, ''),
        'resolvedReason', r.resolved_reason
      )
      INTO v_member_cap_resolution
      FROM public.member_cap_join_requests r
      LEFT JOIN public.profiles p ON p.id = r.joiner_user_id
      WHERE r.home_id = v_home_id
        AND r.resolved_at IS NOT NULL
        AND r.resolved_reason IN ('joined', 'joiner_superseded')
        AND r.resolution_notified_at IS NULL
      ORDER BY r.resolved_at DESC
      LIMIT 1;
    END IF;

    IF v_member_cap_resolution IS NOT NULL THEN
      v_resolution_request_id :=
        (v_member_cap_resolution->>'requestId')::uuid;
    END IF;

    IF v_resolution_request_id IS NOT NULL THEN
      UPDATE public.member_cap_join_requests
         SET resolution_notified_at = now()
       WHERE id = v_resolution_request_id
         AND resolution_notified_at IS NULL;
    END IF;

    RETURN jsonb_build_object(
      'userAuthoredChoreCountLifetime', v_lifetime_authored_chore_count,
      'shouldPromptNotifications', v_prompt_notifications,
      'shouldPromptFlatmateInviteShare', v_prompt_flatmate_invite_share,
      'shouldPromptInviteShare', v_prompt_invite_share,
      'memberCapJoinRequests', COALESCE(v_member_cap_payload, 'null'::jsonb),
      'memberCapJoinResolution', COALESCE(v_member_cap_resolution, 'null'::jsonb)
    );
  END;
$$;


ALTER FUNCTION "public"."today_onboarding_hints"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_context_v1"() RETURNS TABLE("user_id" "uuid", "has_preference_report" boolean, "has_personal_mentions" boolean, "show_avatar" boolean, "avatar_storage_path" "text", "display_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user uuid;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  -- Broad existence check: any published personal preference report (any template/locale)
  has_preference_report := EXISTS (
    SELECT 1
    FROM public.preference_reports pr
    WHERE pr.subject_user_id = v_user
      AND pr.status = 'published'
  );

  -- Personal mentions exist (self-only existence check)
  has_personal_mentions := EXISTS (
    SELECT 1
    FROM public.gratitude_wall_personal_items i
    WHERE i.recipient_user_id = v_user
      AND i.author_user_id <> v_user
  );

  show_avatar := (has_preference_report OR has_personal_mentions);

  -- Only return avatar storage path if the avatar should be shown
  SELECT
    p.username,
    a.storage_path
  INTO display_name, avatar_storage_path
  FROM public.profiles p
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = v_user;

  IF NOT show_avatar THEN
    avatar_storage_path := NULL;
  END IF;

  user_id := v_user;
  RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."user_context_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."user_context_v1"() IS 'Self-only context for Start Page avatar menu + personal profile access. No home fields are returned. show_avatar gates avatar rendering; avatar_storage_path is NULL when show_avatar=false. display_name mirrors profiles.username.';



CREATE OR REPLACE FUNCTION "public"."user_subscriptions_home_entitlements_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
BEGIN
  -- INSERT: new subscription row created
  IF TG_OP = 'INSERT' THEN
    IF NEW.home_id IS NOT NULL THEN
      PERFORM public.home_entitlements_refresh(NEW.home_id);
    END IF;

  -- UPDATE: subscription row changed
  ELSIF TG_OP = 'UPDATE' THEN
    -- Case 1: home_id changed (e.g. detach from one home, attach to another)
    IF NEW.home_id IS DISTINCT FROM OLD.home_id THEN
      -- Old home may have lost funding
      IF OLD.home_id IS NOT NULL THEN
        PERFORM public.home_entitlements_refresh(OLD.home_id);
      END IF;

      -- New home may have gained funding
      IF NEW.home_id IS NOT NULL THEN
        PERFORM public.home_entitlements_refresh(NEW.home_id);
      END IF;

    -- Case 2: same home_id, but status/expiry changed
    ELSIF NEW.status IS DISTINCT FROM OLD.status
       OR NEW.current_period_end_at IS DISTINCT FROM OLD.current_period_end_at THEN
      IF NEW.home_id IS NOT NULL THEN
        PERFORM public.home_entitlements_refresh(NEW.home_id);
      END IF;
    END IF;

  -- DELETE: subscription row removed
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.home_id IS NOT NULL THEN
      PERFORM public.home_entitlements_refresh(OLD.home_id);
    END IF;
  END IF;

  -- AFTER trigger: we don't modify the row itself
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."user_subscriptions_home_entitlements_trigger"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."analytics_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "home_id" "uuid",
    "event_type" "text" NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."analytics_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."analytics_events" IS 'Append-only log of user/home actions for product analytics; written via RPCs.';



COMMENT ON COLUMN "public"."analytics_events"."user_id" IS 'User responsible for the event (the actor).';



COMMENT ON COLUMN "public"."analytics_events"."home_id" IS 'Home involved in the event, if any; NULL for global/user-only events.';



COMMENT ON COLUMN "public"."analytics_events"."event_type" IS 'Logical event type identifier (e.g., home.created, home.left, legal_consent.accepted).';



COMMENT ON COLUMN "public"."analytics_events"."occurred_at" IS 'Timestamp when the event occurred.';



COMMENT ON COLUMN "public"."analytics_events"."metadata" IS 'Optional JSON payload with additional details for this event.';



CREATE TABLE IF NOT EXISTS "public"."app_version" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version_number" "text" NOT NULL,
    "min_supported_version" "text" NOT NULL,
    "is_current" boolean DEFAULT false NOT NULL,
    "release_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    CONSTRAINT "chk_min_supported" CHECK (("min_supported_version" ~ '^\d+\.\d+\.\d+$'::"text")),
    CONSTRAINT "chk_version_number" CHECK (("version_number" ~ '^\d+\.\d+\.\d+$'::"text"))
);


ALTER TABLE "public"."app_version" OWNER TO "postgres";


COMMENT ON TABLE "public"."app_version" IS 'Manually maintained table of app versions. The app checks this table at startup to know if the client is outdated.';



COMMENT ON COLUMN "public"."app_version"."min_supported_version" IS 'Minimum version allowed to run. Clients below this version will be blocked.';



CREATE TABLE IF NOT EXISTS "public"."avatars" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "storage_path" "text" NOT NULL,
    "category" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" DEFAULT 'Unnamed Avatar'::"text" NOT NULL,
    CONSTRAINT "avatars_category_check" CHECK (("category" = ANY (ARRAY['animal'::"text", 'plant'::"text"])))
);


ALTER TABLE "public"."avatars" OWNER TO "postgres";


COMMENT ON TABLE "public"."avatars" IS 'Avatars: image metadata for user profile pictures.';



COMMENT ON COLUMN "public"."avatars"."storage_path" IS 'Storage bucket/path or object key.';



COMMENT ON COLUMN "public"."avatars"."category" IS 'Logical grouping, e.g., "animal" (starter pack), "plant", etc.';



COMMENT ON COLUMN "public"."avatars"."created_at" IS 'Creation timestamp (UTC).';



COMMENT ON COLUMN "public"."avatars"."name" IS 'Human-readable name describing what this avatar is about.';



COMMENT ON CONSTRAINT "avatars_category_check" ON "public"."avatars" IS 'Restricts category to only "animal" or "plant".';



CREATE TABLE IF NOT EXISTS "public"."chore_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "chore_id" "uuid" NOT NULL,
    "home_id" "uuid" NOT NULL,
    "actor_user_id" "uuid" NOT NULL,
    "event_type" "public"."chore_event_type" NOT NULL,
    "from_state" "public"."chore_state",
    "to_state" "public"."chore_state",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chore_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."chore_events" IS 'Append-only audit log for chore lifecycle transitions.';



COMMENT ON COLUMN "public"."chore_events"."home_id" IS 'Denormalised home id for easier filtering.';



COMMENT ON COLUMN "public"."chore_events"."actor_user_id" IS 'User who triggered the event.';



COMMENT ON COLUMN "public"."chore_events"."from_state" IS 'Previous state.';



COMMENT ON COLUMN "public"."chore_events"."to_state" IS 'New state.';



COMMENT ON COLUMN "public"."chore_events"."payload" IS 'Structured diff / metadata.';



COMMENT ON COLUMN "public"."chore_events"."occurred_at" IS 'Timestamp of event.';



CREATE TABLE IF NOT EXISTS "public"."device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "provider" "text" DEFAULT 'fcm'::"text" NOT NULL,
    "platform" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expense_plan_debtors" (
    "plan_id" "uuid" NOT NULL,
    "debtor_user_id" "uuid" NOT NULL,
    "share_amount_cents" bigint NOT NULL,
    CONSTRAINT "chk_expense_plan_debtors_amount_positive" CHECK (("share_amount_cents" > 0))
);


ALTER TABLE "public"."expense_plan_debtors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expense_splits" (
    "expense_id" "uuid" NOT NULL,
    "debtor_user_id" "uuid" NOT NULL,
    "amount_cents" bigint NOT NULL,
    "status" "public"."expense_share_status" DEFAULT 'unpaid'::"public"."expense_share_status" NOT NULL,
    "marked_paid_at" timestamp with time zone,
    "recipient_viewed_at" timestamp with time zone,
    CONSTRAINT "chk_expense_splits_amount_positive" CHECK (("amount_cents" > 0)),
    CONSTRAINT "chk_expense_splits_paid_timestamp_alignment" CHECK (((("status" = 'unpaid'::"public"."expense_share_status") AND ("marked_paid_at" IS NULL)) OR (("status" = 'paid'::"public"."expense_share_status") AND ("marked_paid_at" IS NOT NULL)))),
    CONSTRAINT "chk_expense_splits_recipient_viewed_state" CHECK ((("recipient_viewed_at" IS NULL) OR ("marked_paid_at" IS NOT NULL)))
);


ALTER TABLE "public"."expense_splits" OWNER TO "postgres";


COMMENT ON TABLE "public"."expense_splits" IS 'Per-person share of an expense (debtor owes the creator).';



COMMENT ON COLUMN "public"."expense_splits"."debtor_user_id" IS 'Member who owes this share.';



COMMENT ON COLUMN "public"."expense_splits"."amount_cents" IS 'Share amount in cents.';



COMMENT ON COLUMN "public"."expense_splits"."status" IS 'unpaid|paid.';



COMMENT ON COLUMN "public"."expense_splits"."marked_paid_at" IS 'Timestamp when debtor marked the share paid.';



COMMENT ON COLUMN "public"."expense_splits"."recipient_viewed_at" IS 'When the expense creator viewed this paid split (NULL = unseen).';



CREATE TABLE IF NOT EXISTS "public"."gratitude_wall_mentions" (
    "post_id" "uuid" NOT NULL,
    "home_id" "uuid" NOT NULL,
    "mentioned_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."gratitude_wall_mentions" OWNER TO "postgres";


COMMENT ON TABLE "public"."gratitude_wall_mentions" IS 'Mention edges for home gratitude wall posts. Display fields resolved at read time from profiles. home_id is stored as original context.';



CREATE TABLE IF NOT EXISTS "public"."gratitude_wall_personal_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_user_id" "uuid" NOT NULL,
    "home_id" "uuid" NOT NULL,
    "author_user_id" "uuid" NOT NULL,
    "mood" "public"."mood_scale" NOT NULL,
    "message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_kind" "text" NOT NULL,
    "source_post_id" "uuid",
    "source_entry_id" "uuid" NOT NULL,
    CONSTRAINT "gratitude_wall_personal_items_source_kind_check" CHECK (("source_kind" = ANY (ARRAY['home_post'::"text", 'mention_only'::"text"])))
);


ALTER TABLE "public"."gratitude_wall_personal_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."gratitude_wall_personal_items" IS 'Recipient-owned, immutable personal gratitude inbox items. Stable IDs only; resolve display fields at read time. First publish wins.';



CREATE TABLE IF NOT EXISTS "public"."gratitude_wall_personal_reads" (
    "user_id" "uuid" NOT NULL,
    "last_read_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."gratitude_wall_personal_reads" OWNER TO "postgres";


COMMENT ON TABLE "public"."gratitude_wall_personal_reads" IS 'Recipient-only read cursor for the personal gratitude inbox.';



CREATE TABLE IF NOT EXISTS "public"."gratitude_wall_posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "author_user_id" "uuid" NOT NULL,
    "mood" "public"."mood_scale" NOT NULL,
    "message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_entry_id" "uuid",
    CONSTRAINT "chk_gratitude_wall_posts_message_len" CHECK ((("message" IS NULL) OR ("char_length"("message") <= 500)))
);


ALTER TABLE "public"."gratitude_wall_posts" OWNER TO "postgres";


COMMENT ON TABLE "public"."gratitude_wall_posts" IS 'Immutable gratitude messages shared on the home gratitude wall.';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."id" IS 'Unique identifier for the gratitude wall post.';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."home_id" IS 'ID of the home this gratitude post belongs to.';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."author_user_id" IS 'Profile ID of the user who authored this gratitude post.';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."mood" IS 'Mood selected when the gratitude post was created (from mood_scale).';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."message" IS 'User-supplied gratitude message. May be NULL when no text was provided. Max 500 characters.';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."created_at" IS 'Timestamp when this gratitude post was created.';



COMMENT ON COLUMN "public"."gratitude_wall_posts"."source_entry_id" IS 'Origin weekly entry (home_mood_entries.id) that produced this post. Nullable for legacy/manual posts.';



CREATE TABLE IF NOT EXISTS "public"."gratitude_wall_reads" (
    "home_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "last_read_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."gratitude_wall_reads" OWNER TO "postgres";


COMMENT ON TABLE "public"."gratitude_wall_reads" IS 'Tracks when each user last read the gratitude wall for a given home.';



COMMENT ON COLUMN "public"."gratitude_wall_reads"."home_id" IS 'ID of the home whose gratitude wall is being tracked.';



COMMENT ON COLUMN "public"."gratitude_wall_reads"."user_id" IS 'Profile ID of the user whose last read time is stored.';



COMMENT ON COLUMN "public"."gratitude_wall_reads"."last_read_at" IS 'Timestamp when the user last marked the gratitude wall as read for this home.';



CREATE TABLE IF NOT EXISTS "public"."home_entitlements" (
    "home_id" "uuid" NOT NULL,
    "plan" "text" DEFAULT 'free'::"text" NOT NULL,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "home_entitlements_plan_check" CHECK (("plan" = ANY (ARRAY['free'::"text", 'premium'::"text"])))
);


ALTER TABLE "public"."home_entitlements" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_entitlements" IS 'Cached subscription status per home (free vs premium) for fast paywall checks.';



COMMENT ON COLUMN "public"."home_entitlements"."plan" IS 'Logical plan for the home: free | premium.';



COMMENT ON COLUMN "public"."home_entitlements"."expires_at" IS 'Optional max expiration among supporting subscriptions; NULL means indefinite or unknown.';



CREATE TABLE IF NOT EXISTS "public"."home_mood_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "home_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "mood" "public"."mood_scale" NOT NULL,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "iso_week_year" integer NOT NULL,
    "iso_week" integer NOT NULL,
    "gratitude_post_id" "uuid",
    CONSTRAINT "chk_home_mood_entries_comment_len" CHECK ((("comment" IS NULL) OR ("char_length"("comment") <= 500)))
);


ALTER TABLE "public"."home_mood_entries" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_mood_entries" IS 'Weekly mood capture per user (one entry per ISO week across all homes; home_id records which home they were in).';



COMMENT ON COLUMN "public"."home_mood_entries"."id" IS 'Unique identifier for the mood entry.';



COMMENT ON COLUMN "public"."home_mood_entries"."home_id" IS 'ID of the home this mood entry is associated with.';



COMMENT ON COLUMN "public"."home_mood_entries"."user_id" IS 'Profile ID of the user whose mood is recorded in this entry.';



COMMENT ON COLUMN "public"."home_mood_entries"."mood" IS 'Mood selected by the user for this ISO week (from mood_scale).';



COMMENT ON COLUMN "public"."home_mood_entries"."comment" IS 'Optional user comment about how the home feels this week. May be NULL. Max 500 characters.';



COMMENT ON COLUMN "public"."home_mood_entries"."created_at" IS 'Timestamp when this mood entry was created.';



COMMENT ON COLUMN "public"."home_mood_entries"."iso_week_year" IS 'ISO year number for this mood entry (e.g. 2025).';



COMMENT ON COLUMN "public"."home_mood_entries"."iso_week" IS 'ISO week number for this mood entry (1–53).';



COMMENT ON COLUMN "public"."home_mood_entries"."gratitude_post_id" IS 'Optional link to a gratitude wall post created from this mood entry (if the user chose to share).';



CREATE TABLE IF NOT EXISTS "public"."home_mood_feedback_counters" (
    "home_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "feedback_count" integer DEFAULT 0 NOT NULL,
    "first_feedback_at" timestamp with time zone,
    "last_feedback_at" timestamp with time zone,
    "last_nps_at" timestamp with time zone,
    "last_nps_score" integer,
    "last_nps_feedback_count" integer DEFAULT 0 NOT NULL,
    "nps_required" boolean DEFAULT false NOT NULL,
    CONSTRAINT "chk_home_mood_feedback_counters_last_nps_score" CHECK ((("last_nps_score" IS NULL) OR (("last_nps_score" >= 0) AND ("last_nps_score" <= 10))))
);


ALTER TABLE "public"."home_mood_feedback_counters" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_mood_feedback_counters" IS 'Per-home per-user counters for Harmony feedback and NPS state.';



COMMENT ON COLUMN "public"."home_mood_feedback_counters"."feedback_count" IS 'Total number of mood feedback entries submitted by this user in this home.';



COMMENT ON COLUMN "public"."home_mood_feedback_counters"."last_nps_feedback_count" IS 'Feedback_count value at which the last NPS was completed (0 = never).';



COMMENT ON COLUMN "public"."home_mood_feedback_counters"."nps_required" IS 'TRUE when an NPS answer is required and must be completed before normal use.';



CREATE TABLE IF NOT EXISTS "public"."home_plan_limits" (
    "plan" "text" NOT NULL,
    "metric" "public"."home_usage_metric" NOT NULL,
    "max_value" integer NOT NULL,
    CONSTRAINT "home_plan_limits_max_value_check" CHECK (("max_value" >= 0)),
    CONSTRAINT "home_plan_limits_plan_not_blank" CHECK (("btrim"("plan") <> ''::"text"))
);


ALTER TABLE "public"."home_plan_limits" OWNER TO "postgres";


COMMENT ON TABLE "public"."home_plan_limits" IS 'Per-plan limits for home usage metrics (e.g. free vs premium).';



COMMENT ON COLUMN "public"."home_plan_limits"."plan" IS 'Logical plan name (e.g. free, premium).';



COMMENT ON COLUMN "public"."home_plan_limits"."metric" IS 'Usage metric being limited (active_chores, chore_photos, active_members).';



COMMENT ON COLUMN "public"."home_plan_limits"."max_value" IS 'Maximum allowed value for this metric on this plan.';



CREATE TABLE IF NOT EXISTS "public"."homes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "deactivated_at" timestamp with time zone,
    CONSTRAINT "chk_homes_active_vs_deactivated_at" CHECK (((("deactivated_at" IS NULL) AND ("is_active" = true)) OR (("deactivated_at" IS NOT NULL) AND ("is_active" = false))))
);


ALTER TABLE "public"."homes" OWNER TO "postgres";


COMMENT ON TABLE "public"."homes" IS 'Top-level container for collaboration within a household.';



COMMENT ON COLUMN "public"."homes"."owner_user_id" IS 'User ID of the home owner (FK to profiles.id).';



COMMENT ON COLUMN "public"."homes"."created_at" IS 'Date when the home was first created.';



COMMENT ON COLUMN "public"."homes"."updated_at" IS 'Date when the home details were last updated.';



COMMENT ON COLUMN "public"."homes"."is_active" IS 'Indicates if the home is currently active.';



COMMENT ON COLUMN "public"."homes"."deactivated_at" IS 'Timestamp when the home was deactivated.';



CREATE TABLE IF NOT EXISTS "public"."house_pulse_labels" (
    "contract_version" "text" NOT NULL,
    "pulse_state" "public"."house_pulse_state" NOT NULL,
    "title_key" "text" NOT NULL,
    "summary_key" "text" NOT NULL,
    "image_key" "text" NOT NULL,
    "ui" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_house_pulse_labels_contract_version_nonempty" CHECK (("btrim"("contract_version") <> ''::"text"))
);


ALTER TABLE "public"."house_pulse_labels" OWNER TO "postgres";


COMMENT ON TABLE "public"."house_pulse_labels" IS 'UI metadata mapping for house pulse states (versioned by contract_version).';



CREATE TABLE IF NOT EXISTS "public"."house_vibe_labels" (
    "label_id" "text" NOT NULL,
    "mapping_version" "text" NOT NULL,
    "title_key" "text" NOT NULL,
    "summary_key" "text" NOT NULL,
    "image_key" "text" NOT NULL,
    "ui" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."house_vibe_labels" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."house_vibe_mapping_effects" (
    "mapping_version" "text" NOT NULL,
    "preference_id" "text" NOT NULL,
    "option_index" smallint NOT NULL,
    "axis" "text" NOT NULL,
    "delta" smallint NOT NULL,
    "weight" numeric(4,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "house_vibe_mapping_effects_axis_check" CHECK (("axis" = ANY (ARRAY['energy_level'::"text", 'structure_level'::"text", 'social_level'::"text", 'repair_style'::"text", 'noise_tolerance'::"text", 'cleanliness_rhythm'::"text"]))),
    CONSTRAINT "house_vibe_mapping_effects_delta_check" CHECK (("delta" = ANY (ARRAY['-1'::integer, 0, 1]))),
    CONSTRAINT "house_vibe_mapping_effects_option_index_check" CHECK ((("option_index" >= 0) AND ("option_index" <= 2))),
    CONSTRAINT "house_vibe_mapping_effects_weight_check" CHECK ((("weight" >= 0.10) AND ("weight" <= 3.00)))
);


ALTER TABLE "public"."house_vibe_mapping_effects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."house_vibe_versions" (
    "mapping_version" "text" NOT NULL,
    "min_side_count_small" integer DEFAULT 1 NOT NULL,
    "min_side_count_large" integer DEFAULT 2 NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "house_vibe_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text"])))
);


ALTER TABLE "public"."house_vibe_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."house_vibes" (
    "home_id" "uuid" NOT NULL,
    "mapping_version" "text" NOT NULL,
    "label_id" "text" NOT NULL,
    "confidence" numeric NOT NULL,
    "coverage_answered" integer NOT NULL,
    "coverage_total" integer NOT NULL,
    "axes" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "out_of_date" boolean DEFAULT false NOT NULL,
    "invalidated_at" timestamp with time zone,
    CONSTRAINT "chk_house_vibes_confidence_0_1" CHECK ((("confidence" >= (0)::numeric) AND ("confidence" <= (1)::numeric))),
    CONSTRAINT "chk_house_vibes_coverage_nonneg" CHECK ((("coverage_answered" >= 0) AND ("coverage_total" >= 0))),
    CONSTRAINT "chk_house_vibes_coverage_order" CHECK (("coverage_answered" <= "coverage_total"))
);


ALTER TABLE "public"."house_vibes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "public"."citext" NOT NULL,
    "country_code" "text" NOT NULL,
    "ui_locale" "text" NOT NULL,
    "source" "text" DEFAULT 'kinly_web_get'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "leads_country_code_check" CHECK (("country_code" ~ '^[A-Z]{2}$'::"text")),
    CONSTRAINT "leads_source_check" CHECK (("source" = ANY (ARRAY['kinly_web_get'::"text", 'kinly_dating_web_get'::"text", 'kinly_rent_web_get'::"text"]))),
    CONSTRAINT "leads_ui_locale_check" CHECK ((POSITION((' '::"text") IN ("ui_locale")) = 0))
);


ALTER TABLE "public"."leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leads_rate_limits" (
    "k" "text" NOT NULL,
    "n" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."leads_rate_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."memberships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "home_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "valid_to" timestamp with time zone,
    "is_current" boolean GENERATED ALWAYS AS (("valid_to" IS NULL)) STORED,
    "validity" "tstzrange" GENERATED ALWAYS AS ("tstzrange"("valid_from", COALESCE("valid_to", 'infinity'::timestamp with time zone), '[)'::"text")) STORED,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "memberships_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'member'::"text"])))
);


ALTER TABLE "public"."memberships" OWNER TO "postgres";


COMMENT ON TABLE "public"."memberships" IS 'Each row is one “stint” of a user in a home (with a role) and a start/end window; history preserved.';



COMMENT ON COLUMN "public"."memberships"."id" IS 'Surrogate key for the stint row.';



COMMENT ON COLUMN "public"."memberships"."user_id" IS 'FK to profiles.id; identifies the person holding this membership stint.';



COMMENT ON COLUMN "public"."memberships"."home_id" IS 'FK to homes.id; the home this stint is associated with.';



COMMENT ON COLUMN "public"."memberships"."role" IS 'Role during this stint: only "owner" or "member".';



COMMENT ON COLUMN "public"."memberships"."valid_from" IS 'Inclusive start timestamp for the stint.';



COMMENT ON COLUMN "public"."memberships"."valid_to" IS 'Exclusive end timestamp; NULL means the stint is still current.';



COMMENT ON COLUMN "public"."memberships"."is_current" IS 'Computed: TRUE when valid_to IS NULL. Do not update directly.';



COMMENT ON COLUMN "public"."memberships"."validity" IS 'Generated tstzrange of [valid_from, valid_to) (infinity if open) for overlap checks.';



COMMENT ON COLUMN "public"."memberships"."created_at" IS 'Audit timestamp when the row was created.';



COMMENT ON COLUMN "public"."memberships"."updated_at" IS 'Audit timestamp of the most recent update to the row.';



CREATE TABLE IF NOT EXISTS "public"."notification_sends" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "local_date" "date" NOT NULL,
    "job_run_id" "text",
    "status" "text" NOT NULL,
    "error" "text",
    "reserved_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "failed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "token_id" "uuid"
);


ALTER TABLE "public"."notification_sends" OWNER TO "postgres";


COMMENT ON COLUMN "public"."notification_sends"."status" IS 'Notification send state: reserved | sent | failed';



CREATE TABLE IF NOT EXISTS "public"."paywall_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "home_id" "uuid",
    "event_type" "text" NOT NULL,
    "source" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "paywall_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['impression'::"text", 'cta_click'::"text", 'dismiss'::"text", 'restore_attempt'::"text"])))
);


ALTER TABLE "public"."paywall_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."paywall_events" IS 'Funnel events for the paywall (impression, CTA click, dismiss, restore).';



CREATE TABLE IF NOT EXISTS "public"."preference_report_acknowledgements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "report_id" "uuid" NOT NULL,
    "viewer_user_id" "uuid" NOT NULL,
    "acknowledged_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."preference_report_acknowledgements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."preference_report_revisions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "report_id" "uuid" NOT NULL,
    "editor_user_id" "uuid" NOT NULL,
    "edited_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "content" "jsonb" NOT NULL,
    "change_summary" "text"
);


ALTER TABLE "public"."preference_report_revisions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."preference_report_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "locale" "text" NOT NULL,
    "body" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_template_key_format" CHECK (("template_key" ~ '^[a-z0-9_]{1,64}$'::"text")),
    CONSTRAINT "chk_template_locale_base" CHECK (("locale" ~ '^[a-z]{2}$'::"text"))
);


ALTER TABLE "public"."preference_report_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."preference_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "subject_user_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "locale" "text" NOT NULL,
    "status" "text" DEFAULT 'published'::"text" NOT NULL,
    "generated_content" "jsonb" NOT NULL,
    "published_content" "jsonb" NOT NULL,
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "published_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_edited_at" timestamp with time zone,
    "last_edited_by" "uuid",
    CONSTRAINT "chk_preference_reports_status" CHECK (("status" = ANY (ARRAY['published'::"text", 'out_of_date'::"text"]))),
    CONSTRAINT "chk_reports_locale" CHECK (("locale" ~ '^[a-z]{2}$'::"text")),
    CONSTRAINT "chk_reports_template_key_format" CHECK (("template_key" ~ '^[a-z0-9_]{1,64}$'::"text"))
);


ALTER TABLE "public"."preference_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."preference_responses" (
    "user_id" "uuid" NOT NULL,
    "preference_id" "text" NOT NULL,
    "option_index" smallint NOT NULL,
    "captured_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_preference_option_index" CHECK ((("option_index" >= 0) AND ("option_index" <= 2)))
);


ALTER TABLE "public"."preference_responses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."preference_taxonomy" (
    "preference_id" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_taxonomy_preference_id_format" CHECK (("preference_id" ~ '^[a-z0-9_]{1,64}$'::"text"))
);


ALTER TABLE "public"."preference_taxonomy" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."preference_taxonomy_defs" (
    "preference_id" "text" NOT NULL,
    "domain" "text" NOT NULL,
    "label" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" NOT NULL,
    "value_keys" "text"[] NOT NULL,
    "aggregation" "text" DEFAULT 'mode'::"text" NOT NULL,
    "safety_notes" "text"[] DEFAULT ARRAY[]::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_defs_domain_format" CHECK (("domain" ~ '^[a-z0-9_]{1,32}$'::"text")),
    CONSTRAINT "chk_defs_value_keys_each_format" CHECK ((("value_keys"[1] ~ '^[a-z0-9_]{1,64}$'::"text") AND ("value_keys"[2] ~ '^[a-z0-9_]{1,64}$'::"text") AND ("value_keys"[3] ~ '^[a-z0-9_]{1,64}$'::"text"))),
    CONSTRAINT "chk_defs_value_keys_len_3" CHECK (("array_length"("value_keys", 1) = 3))
);


ALTER TABLE "public"."preference_taxonomy_defs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."preference_taxonomy_active_defs" AS
 SELECT "t"."preference_id",
    "d"."domain",
    "d"."label",
    "d"."description",
    "d"."value_keys",
    "d"."aggregation",
    "d"."safety_notes"
   FROM ("public"."preference_taxonomy" "t"
     JOIN "public"."preference_taxonomy_defs" "d" USING ("preference_id"))
  WHERE ("t"."is_active" = true);


ALTER VIEW "public"."preference_taxonomy_active_defs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "full_name" "text",
    "avatar_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deactivated_at" timestamp with time zone,
    "username" "public"."citext" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_profiles_username_format" CHECK (("username" OPERATOR("public".~) '^[a-z0-9](?:[a-z0-9._]{1,28})[a-z0-9]$'::"public"."citext"))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."profiles" IS 'App-facing persona mirroring auth.users by id (1:1).';



COMMENT ON COLUMN "public"."profiles"."id" IS 'Primary key = auth.users.id..';



COMMENT ON COLUMN "public"."profiles"."email" IS 'Optional user email address mirrored from auth.users.email. May be NULL for privacy or deleted accounts. Remains UNIQUE when present.';



COMMENT ON COLUMN "public"."profiles"."full_name" IS 'Optional display name.';



COMMENT ON COLUMN "public"."profiles"."avatar_id" IS 'FK to public.avatars.id (required avatar).';



COMMENT ON COLUMN "public"."profiles"."created_at" IS 'Profile creation timestamp (UTC).';



COMMENT ON COLUMN "public"."profiles"."deactivated_at" IS 'Timestamp when the user deactivated or left the app. NULL = currently active. Used for soft-deletion and retention tracking.';



COMMENT ON COLUMN "public"."profiles"."username" IS 'Case-insensitive unique handle for user identification and @mentions. Must be 3–30 chars long, start/end with a letter or number, and may contain dots or underscores in between. Used for tagging (e.g., @username) and public display names.';



COMMENT ON COLUMN "public"."profiles"."updated_at" IS 'Profile updated timestamp (UTC).';



COMMENT ON CONSTRAINT "chk_profiles_username_format" ON "public"."profiles" IS 'Enforces username format: 3–30 chars, lowercase letters, digits, dots, or underscores. Must start and end with a letter or number.';



CREATE TABLE IF NOT EXISTS "public"."reserved_usernames" (
    "name" "public"."citext" NOT NULL
);


ALTER TABLE "public"."reserved_usernames" OWNER TO "postgres";


COMMENT ON TABLE "public"."reserved_usernames" IS 'Case-insensitive blocklist of usernames that users are not allowed to claim (e.g., admin, support).';



COMMENT ON COLUMN "public"."reserved_usernames"."name" IS 'Reserved handle (CITEXT). Comparisons and PK uniqueness are case-insensitive.';



CREATE TABLE IF NOT EXISTS "public"."revenuecat_event_processing" (
    "environment" "text" NOT NULL,
    "idempotency_key" "text" NOT NULL,
    "status" "public"."revenuecat_processing_status" DEFAULT 'processing'::"public"."revenuecat_processing_status" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."revenuecat_event_processing" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."revenuecat_webhook_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_timestamp" timestamp with time zone,
    "environment" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "rc_app_user_id" "text" NOT NULL,
    "entitlement_id" "text",
    "product_id" "text",
    "store" "public"."subscription_store",
    "status" "public"."subscription_status",
    "current_period_end_at" timestamp with time zone,
    "original_purchase_at" timestamp with time zone,
    "last_purchase_at" timestamp with time zone,
    "latest_transaction_id" "text",
    "home_id" "uuid",
    "raw" "jsonb",
    "error" "text",
    "idempotency_key" "text" NOT NULL,
    "rc_event_id" "text",
    "original_transaction_id" "text",
    "entitlement_ids" "text"[],
    "warnings" "text"[],
    "fatal_error_code" "text",
    "fatal_error" "text",
    "rpc_error_code" "text",
    "rpc_error" "text",
    "rpc_retryable" boolean,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."revenuecat_webhook_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."revenuecat_webhook_events" IS 'Audit log of RevenueCat webhook events used for debugging and analytics.';



CREATE TABLE IF NOT EXISTS "public"."share_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "home_id" "uuid",
    "feature" "text" NOT NULL,
    "channel" "text" NOT NULL,
    CONSTRAINT "share_channel_valid" CHECK (("channel" = ANY (ARRAY['system_share'::"text", 'qr_code'::"text", 'copy_link'::"text", 'other'::"text", 'onboarding_dismiss'::"text"]))),
    CONSTRAINT "share_feature_valid" CHECK (("feature" = ANY (ARRAY['invite_button'::"text", 'invite_housemate'::"text", 'gratitude_wall_house'::"text", 'gratitude_wall_personal'::"text", 'house_rules_detailed'::"text", 'house_rules_summary'::"text", 'preferences_detailed'::"text", 'preferences_summary'::"text", 'house_vibe'::"text", 'house_pulse'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."share_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."share_events" IS 'Internal analytics for tracking share attempts (per user, home, feature, channel).';



CREATE TABLE IF NOT EXISTS "public"."shared_preferences" (
    "user_id" "uuid" NOT NULL,
    "pref_key" "text" NOT NULL,
    "pref_value" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."shared_preferences" OWNER TO "postgres";


COMMENT ON TABLE "public"."shared_preferences" IS 'Per-user key/value preferences (current state only); accessed via RPCs, not direct client DML.';



COMMENT ON COLUMN "public"."shared_preferences"."user_id" IS 'Owner of the preference; references profiles(id).';



COMMENT ON COLUMN "public"."shared_preferences"."pref_key" IS 'Preference key (namespaced, e.g., legal.consent.v1, tutorial.free_upload_camera.v1).';



COMMENT ON COLUMN "public"."shared_preferences"."pref_value" IS 'Preference value as JSONB (boolean, number, string, or structured object).';



COMMENT ON COLUMN "public"."shared_preferences"."created_at" IS 'Timestamp when this preference row was first created.';



COMMENT ON COLUMN "public"."shared_preferences"."updated_at" IS 'Timestamp when this preference row was last updated.';



CREATE TABLE IF NOT EXISTS "public"."user_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "home_id" "uuid",
    "store" "public"."subscription_store" NOT NULL,
    "rc_app_user_id" "text" NOT NULL,
    "rc_entitlement_id" "text" NOT NULL,
    "product_id" "text" NOT NULL,
    "status" "public"."subscription_status" NOT NULL,
    "current_period_end_at" timestamp with time zone,
    "original_purchase_at" timestamp with time zone,
    "last_purchase_at" timestamp with time zone,
    "latest_transaction_id" "text",
    "last_synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_subscriptions" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_subscriptions" IS 'Per-user subscription entitlement snapshot from RevenueCat, tied to a single home and entitlement.';



COMMENT ON COLUMN "public"."user_subscriptions"."user_id" IS 'Paying user (canonical Supabase profile).';



COMMENT ON COLUMN "public"."user_subscriptions"."home_id" IS 'Home whose premium is funded by this subscription (if home-scoped).';



COMMENT ON COLUMN "public"."user_subscriptions"."store" IS 'Store / source of the subscription (app_store, play_store, stripe, promotional).';



COMMENT ON COLUMN "public"."user_subscriptions"."rc_app_user_id" IS 'Latest RevenueCat app_user_id associated with this user/entitlement.';



COMMENT ON COLUMN "public"."user_subscriptions"."rc_entitlement_id" IS 'RevenueCat entitlement identifier, e.g. home_premium.';



COMMENT ON COLUMN "public"."user_subscriptions"."product_id" IS 'Store product id that most recently granted this entitlement.';



COMMENT ON COLUMN "public"."user_subscriptions"."status" IS 'Subscription state snapshot mapped from RevenueCat.';



COMMENT ON COLUMN "public"."user_subscriptions"."current_period_end_at" IS 'End of the current entitlement period (from RevenueCat).';



COMMENT ON COLUMN "public"."user_subscriptions"."last_synced_at" IS 'Timestamp when this row was last updated from RevenueCat.';



ALTER TABLE ONLY "public"."analytics_events"
    ADD CONSTRAINT "analytics_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_version"
    ADD CONSTRAINT "app_version_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."avatars"
    ADD CONSTRAINT "avatars_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chore_events"
    ADD CONSTRAINT "chore_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chores"
    ADD CONSTRAINT "chores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expense_plans"
    ADD CONSTRAINT "expense_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "gratitude_wall_personal_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gratitude_wall_personal_reads"
    ADD CONSTRAINT "gratitude_wall_personal_reads_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."gratitude_wall_posts"
    ADD CONSTRAINT "gratitude_wall_posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."home_entitlements"
    ADD CONSTRAINT "home_entitlements_pkey" PRIMARY KEY ("home_id");



ALTER TABLE ONLY "public"."home_mood_entries"
    ADD CONSTRAINT "home_mood_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."home_nps"
    ADD CONSTRAINT "home_nps_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."home_plan_limits"
    ADD CONSTRAINT "home_plan_limits_pkey" PRIMARY KEY ("plan", "metric");



ALTER TABLE ONLY "public"."home_usage_counters"
    ADD CONSTRAINT "home_usage_counters_pkey" PRIMARY KEY ("home_id");



ALTER TABLE ONLY "public"."homes"
    ADD CONSTRAINT "homes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."house_vibe_versions"
    ADD CONSTRAINT "house_vibe_versions_pkey" PRIMARY KEY ("mapping_version");



ALTER TABLE ONLY "public"."house_vibes"
    ADD CONSTRAINT "house_vibes_pkey" PRIMARY KEY ("home_id", "mapping_version");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leads_rate_limits"
    ADD CONSTRAINT "leads_rate_limits_pkey" PRIMARY KEY ("k");



ALTER TABLE ONLY "public"."member_cap_join_requests"
    ADD CONSTRAINT "member_cap_join_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "no_overlap_per_user_home" EXCLUDE USING "gist" ("user_id" WITH =, "home_id" WITH =, "validity" WITH &&);



COMMENT ON CONSTRAINT "no_overlap_per_user_home" ON "public"."memberships" IS 'Prevents overlapping validity windows for the same user in the same home.';



ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."notification_sends"
    ADD CONSTRAINT "notification_sends_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."paywall_events"
    ADD CONSTRAINT "paywall_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expense_plan_debtors"
    ADD CONSTRAINT "pk_expense_plan_debtors" PRIMARY KEY ("plan_id", "debtor_user_id");



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "pk_expense_splits" PRIMARY KEY ("expense_id", "debtor_user_id");



ALTER TABLE ONLY "public"."gratitude_wall_mentions"
    ADD CONSTRAINT "pk_gratitude_wall_mentions" PRIMARY KEY ("post_id", "mentioned_user_id");



ALTER TABLE ONLY "public"."gratitude_wall_reads"
    ADD CONSTRAINT "pk_gratitude_wall_reads" PRIMARY KEY ("home_id", "user_id");



ALTER TABLE ONLY "public"."home_mood_feedback_counters"
    ADD CONSTRAINT "pk_home_mood_feedback_counters" PRIMARY KEY ("home_id", "user_id");



ALTER TABLE ONLY "public"."house_pulse_labels"
    ADD CONSTRAINT "pk_house_pulse_labels" PRIMARY KEY ("contract_version", "pulse_state");



ALTER TABLE ONLY "public"."house_pulse_reads"
    ADD CONSTRAINT "pk_house_pulse_reads" PRIMARY KEY ("home_id", "user_id", "iso_week_year", "iso_week", "contract_version");



ALTER TABLE ONLY "public"."house_pulse_weekly"
    ADD CONSTRAINT "pk_house_pulse_weekly" PRIMARY KEY ("home_id", "iso_week_year", "iso_week", "contract_version");



ALTER TABLE ONLY "public"."house_vibe_labels"
    ADD CONSTRAINT "pk_house_vibe_labels" PRIMARY KEY ("mapping_version", "label_id");



ALTER TABLE ONLY "public"."house_vibe_mapping_effects"
    ADD CONSTRAINT "pk_house_vibe_mapping_effects" PRIMARY KEY ("mapping_version", "preference_id", "option_index", "axis");



ALTER TABLE ONLY "public"."preference_responses"
    ADD CONSTRAINT "pk_preference_responses" PRIMARY KEY ("user_id", "preference_id");



ALTER TABLE ONLY "public"."shared_preferences"
    ADD CONSTRAINT "pk_shared_preferences" PRIMARY KEY ("user_id", "pref_key");



ALTER TABLE ONLY "public"."preference_report_acknowledgements"
    ADD CONSTRAINT "preference_report_acknowledgements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preference_report_revisions"
    ADD CONSTRAINT "preference_report_revisions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preference_report_templates"
    ADD CONSTRAINT "preference_report_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preference_reports"
    ADD CONSTRAINT "preference_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preference_taxonomy_defs"
    ADD CONSTRAINT "preference_taxonomy_defs_pkey" PRIMARY KEY ("preference_id");



ALTER TABLE ONLY "public"."preference_taxonomy"
    ADD CONSTRAINT "preference_taxonomy_pkey" PRIMARY KEY ("preference_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reserved_usernames"
    ADD CONSTRAINT "reserved_usernames_pkey" PRIMARY KEY ("name");



ALTER TABLE ONLY "public"."revenuecat_event_processing"
    ADD CONSTRAINT "revenuecat_event_processing_pkey" PRIMARY KEY ("environment", "idempotency_key");



ALTER TABLE ONLY "public"."revenuecat_webhook_events"
    ADD CONSTRAINT "revenuecat_webhook_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."share_events"
    ADD CONSTRAINT "share_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_version"
    ADD CONSTRAINT "uq_app_version" UNIQUE ("version_number");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "uq_device_tokens_token" UNIQUE ("token");



ALTER TABLE ONLY "public"."home_mood_entries"
    ADD CONSTRAINT "uq_home_mood_entries_user_week" UNIQUE ("user_id", "iso_week_year", "iso_week");



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "uq_personal_items_recipient_entry" UNIQUE ("recipient_user_id", "source_entry_id");



ALTER TABLE ONLY "public"."preference_report_acknowledgements"
    ADD CONSTRAINT "uq_preference_report_ack" UNIQUE ("report_id", "viewer_user_id");



ALTER TABLE ONLY "public"."preference_report_templates"
    ADD CONSTRAINT "uq_preference_report_templates" UNIQUE ("template_key", "locale");



ALTER TABLE ONLY "public"."preference_reports"
    ADD CONSTRAINT "uq_preference_reports_subject_tpl_locale" UNIQUE ("subject_user_id", "template_key", "locale");



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_pkey" PRIMARY KEY ("id");



CREATE INDEX "house_vibe_mapping_effects_lookup_idx" ON "public"."house_vibe_mapping_effects" USING "btree" ("mapping_version", "preference_id", "option_index");



CREATE INDEX "house_vibe_memberships_home_current_user_idx" ON "public"."memberships" USING "btree" ("home_id", "user_id") WHERE ("is_current" = true);



CREATE INDEX "house_vibe_memberships_user_current_idx" ON "public"."memberships" USING "btree" ("user_id") WHERE ("is_current" = true);



CREATE INDEX "house_vibe_preference_responses_user_pref_opt_idx" ON "public"."preference_responses" USING "btree" ("user_id", "preference_id", "option_index");



CREATE INDEX "idx_analytics_events_home_event_time" ON "public"."analytics_events" USING "btree" ("home_id", "event_type", "occurred_at");



CREATE INDEX "idx_analytics_events_user_event_time" ON "public"."analytics_events" USING "btree" ("user_id", "event_type", "occurred_at");



CREATE INDEX "idx_chore_events_chore" ON "public"."chore_events" USING "btree" ("chore_id", "occurred_at" DESC);



CREATE INDEX "idx_chore_events_event_type" ON "public"."chore_events" USING "btree" ("event_type", "occurred_at" DESC);



CREATE INDEX "idx_chore_events_home" ON "public"."chore_events" USING "btree" ("home_id", "occurred_at" DESC);



CREATE INDEX "idx_chores_home_due_cursor" ON "public"."chores" USING "btree" ("home_id", "recurrence_cursor", "created_at" DESC);



CREATE INDEX "idx_device_tokens_user_status" ON "public"."device_tokens" USING "btree" ("user_id", "status");



CREATE INDEX "idx_expense_plans_home_created_at" ON "public"."expense_plans" USING "btree" ("home_id", "created_at" DESC);



CREATE INDEX "idx_expense_plans_home_status_next_date" ON "public"."expense_plans" USING "btree" ("home_id", "status", "next_cycle_date");



CREATE INDEX "idx_expense_splits_debtor_status" ON "public"."expense_splits" USING "btree" ("debtor_user_id", "status");



CREATE INDEX "idx_expense_splits_expense" ON "public"."expense_splits" USING "btree" ("expense_id");



CREATE INDEX "idx_expense_splits_expense_status" ON "public"."expense_splits" USING "btree" ("expense_id", "status");



CREATE INDEX "idx_expenses_active_unpaid" ON "public"."expenses" USING "btree" ("home_id", "created_at" DESC) WHERE (("status" = 'active'::"public"."expense_status") AND ("fully_paid_at" IS NULL));



CREATE INDEX "idx_expenses_creator_created_at" ON "public"."expenses" USING "btree" ("created_by_user_id", "home_id", "created_at" DESC);



CREATE INDEX "idx_expenses_home_status_created_at" ON "public"."expenses" USING "btree" ("home_id", "status", "created_at" DESC);



CREATE INDEX "idx_expenses_plan_id" ON "public"."expenses" USING "btree" ("plan_id");



CREATE INDEX "idx_gratitude_wall_mentions_home_post" ON "public"."gratitude_wall_mentions" USING "btree" ("home_id", "post_id");



CREATE INDEX "idx_gratitude_wall_mentions_user_created_desc" ON "public"."gratitude_wall_mentions" USING "btree" ("mentioned_user_id", "created_at" DESC);



CREATE INDEX "idx_gratitude_wall_posts_home_created_desc" ON "public"."gratitude_wall_posts" USING "btree" ("home_id", "created_at" DESC, "id" DESC);



CREATE INDEX "idx_home_mood_entries_home_user" ON "public"."home_mood_entries" USING "btree" ("home_id", "user_id");



CREATE INDEX "idx_home_mood_entries_home_week" ON "public"."home_mood_entries" USING "btree" ("home_id", "iso_week_year", "iso_week");



CREATE INDEX "idx_home_mood_entries_home_week_user" ON "public"."home_mood_entries" USING "btree" ("home_id", "iso_week_year", "iso_week", "user_id");



CREATE INDEX "idx_home_mood_entries_user_week" ON "public"."home_mood_entries" USING "btree" ("user_id", "iso_week_year", "iso_week");



CREATE INDEX "idx_home_nps_home_created_desc" ON "public"."home_nps" USING "btree" ("home_id", "created_at" DESC, "id" DESC);



CREATE INDEX "idx_house_pulse_weekly_home_week" ON "public"."house_pulse_weekly" USING "btree" ("home_id", "iso_week_year", "iso_week");



CREATE INDEX "idx_invites_code_active" ON "public"."invites" USING "btree" ("code") WHERE ("revoked_at" IS NULL);



COMMENT ON INDEX "public"."idx_invites_code_active" IS 'Optimizes lookups for active (non-revoked) invite codes.';



CREATE INDEX "idx_memberships_home_current" ON "public"."memberships" USING "btree" ("home_id", "user_id") WHERE ("is_current" = true);



CREATE INDEX "idx_personal_items_home_source_entry" ON "public"."gratitude_wall_personal_items" USING "btree" ("home_id", "source_entry_id");



CREATE INDEX "idx_personal_items_recipient_author" ON "public"."gratitude_wall_personal_items" USING "btree" ("recipient_user_id", "author_user_id");



CREATE INDEX "idx_personal_items_recipient_created_desc" ON "public"."gratitude_wall_personal_items" USING "btree" ("recipient_user_id", "created_at" DESC, "id" DESC);



CREATE INDEX "idx_personal_items_recipient_home" ON "public"."gratitude_wall_personal_items" USING "btree" ("recipient_user_id", "home_id");



CREATE INDEX "idx_preference_report_revisions_report" ON "public"."preference_report_revisions" USING "btree" ("report_id", "edited_at" DESC);



CREATE INDEX "idx_preference_report_templates_lookup" ON "public"."preference_report_templates" USING "btree" ("template_key", "locale");



CREATE INDEX "idx_preference_reports_subject" ON "public"."preference_reports" USING "btree" ("subject_user_id");



CREATE INDEX "idx_preference_taxonomy_defs_domain" ON "public"."preference_taxonomy_defs" USING "btree" ("domain");



CREATE INDEX "leads_created_at_idx" ON "public"."leads" USING "btree" ("created_at" DESC);



CREATE INDEX "leads_rate_limits_updated_at_idx" ON "public"."leads_rate_limits" USING "btree" ("updated_at");



CREATE INDEX "memberships_home_user_current_idx" ON "public"."memberships" USING "btree" ("home_id", "user_id") WHERE ("is_current" = true);



CREATE UNIQUE INDEX "revenuecat_webhook_events_env_idem_unique" ON "public"."revenuecat_webhook_events" USING "btree" ("environment", "idempotency_key");



CREATE INDEX "revenuecat_webhook_events_latest_txn_idx" ON "public"."revenuecat_webhook_events" USING "btree" ("latest_transaction_id") WHERE ("latest_transaction_id" IS NOT NULL);



CREATE INDEX "revenuecat_webhook_events_orig_txn_idx" ON "public"."revenuecat_webhook_events" USING "btree" ("original_transaction_id") WHERE ("original_transaction_id" IS NOT NULL);



CREATE INDEX "revenuecat_webhook_events_rc_event_idx" ON "public"."revenuecat_webhook_events" USING "btree" ("environment", "rc_event_id") WHERE ("rc_event_id" IS NOT NULL);



CREATE UNIQUE INDEX "uq_app_version_is_current_true" ON "public"."app_version" USING "btree" ((true)) WHERE "is_current";



CREATE UNIQUE INDEX "uq_gratitude_wall_posts_source_entry_id" ON "public"."gratitude_wall_posts" USING "btree" ("source_entry_id") WHERE ("source_entry_id" IS NOT NULL);



CREATE UNIQUE INDEX "uq_invites_active_one_per_home" ON "public"."invites" USING "btree" ("home_id") WHERE ("revoked_at" IS NULL);



CREATE UNIQUE INDEX "uq_member_cap_requests_home_joiner_open" ON "public"."member_cap_join_requests" USING "btree" ("home_id", "joiner_user_id") WHERE ("resolved_at" IS NULL);



CREATE UNIQUE INDEX "uq_memberships_home_one_current_owner" ON "public"."memberships" USING "btree" ("home_id") WHERE ("is_current" AND ("role" = 'owner'::"text"));



COMMENT ON INDEX "public"."uq_memberships_home_one_current_owner" IS 'Guarantees a home has at most one current owner stint.';



CREATE UNIQUE INDEX "uq_memberships_user_one_current" ON "public"."memberships" USING "btree" ("user_id") WHERE "is_current";



COMMENT ON INDEX "public"."uq_memberships_user_one_current" IS 'Guarantees a user has at most one current membership stint across all homes.';



CREATE UNIQUE INDEX "uq_notification_sends_token_date" ON "public"."notification_sends" USING "btree" ("token_id", "local_date");



CREATE UNIQUE INDEX "uq_profiles_username" ON "public"."profiles" USING "btree" ("username");



COMMENT ON INDEX "public"."uq_profiles_username" IS 'Ensures each username is globally unique (case-insensitive).';



CREATE INDEX "user_subscriptions_by_home_status" ON "public"."user_subscriptions" USING "btree" ("home_id", "rc_entitlement_id", "status", "current_period_end_at");



CREATE UNIQUE INDEX "user_subscriptions_user_entitlement_uniq" ON "public"."user_subscriptions" USING "btree" ("user_id", "rc_entitlement_id");



CREATE UNIQUE INDEX "ux_expenses_plan_cycle_unique" ON "public"."expenses" USING "btree" ("plan_id", "start_date") WHERE (("plan_id" IS NOT NULL) AND ("status" = 'active'::"public"."expense_status"));



CREATE OR REPLACE TRIGGER "chores_events_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."chores" FOR EACH ROW EXECUTE FUNCTION "public"."chores_events_trigger"();



CREATE OR REPLACE TRIGGER "trg_home_mood_feedback_counters_inc" AFTER INSERT ON "public"."home_mood_entries" FOR EACH ROW EXECUTE FUNCTION "public"."home_mood_feedback_counters_inc"();



CREATE OR REPLACE TRIGGER "trg_house_pulse_labels_touch_updated_at" BEFORE UPDATE ON "public"."house_pulse_labels" FOR EACH ROW EXECUTE FUNCTION "public"."_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_house_vibe_labels_touch_updated_at" BEFORE UPDATE ON "public"."house_vibe_labels" FOR EACH ROW EXECUTE FUNCTION "public"."_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_house_vibes_memberships_out_of_date" AFTER INSERT OR DELETE OR UPDATE ON "public"."memberships" FOR EACH ROW EXECUTE FUNCTION "public"."_house_vibes_mark_out_of_date_memberships"();



CREATE OR REPLACE TRIGGER "trg_house_vibes_preference_responses_out_of_date" AFTER INSERT OR DELETE OR UPDATE ON "public"."preference_responses" FOR EACH ROW EXECUTE FUNCTION "public"."_house_vibes_mark_out_of_date_preferences"();



CREATE OR REPLACE TRIGGER "trg_leads_touch_updated_at" BEFORE UPDATE ON "public"."leads" FOR EACH ROW EXECUTE FUNCTION "public"."_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_preference_report_templates_touch" BEFORE UPDATE ON "public"."preference_report_templates" FOR EACH ROW EXECUTE FUNCTION "public"."_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_preference_responses_out_of_date" AFTER INSERT OR UPDATE ON "public"."preference_responses" FOR EACH ROW EXECUTE FUNCTION "public"."_preference_reports_mark_out_of_date"();



CREATE OR REPLACE TRIGGER "trg_preference_taxonomy_defs_touch" BEFORE UPDATE ON "public"."preference_taxonomy_defs" FOR EACH ROW EXECUTE FUNCTION "public"."_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_preference_templates_validate" BEFORE INSERT OR UPDATE ON "public"."preference_report_templates" FOR EACH ROW EXECUTE FUNCTION "public"."_preference_templates_validate"();



CREATE OR REPLACE TRIGGER "user_subscriptions_home_entitlements_trg" AFTER INSERT OR DELETE OR UPDATE ON "public"."user_subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."user_subscriptions_home_entitlements_trigger"();



ALTER TABLE ONLY "public"."analytics_events"
    ADD CONSTRAINT "analytics_events_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."analytics_events"
    ADD CONSTRAINT "analytics_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chore_events"
    ADD CONSTRAINT "chore_events_actor_user_id_fkey" FOREIGN KEY ("actor_user_id") REFERENCES "public"."profiles"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."chore_events"
    ADD CONSTRAINT "chore_events_chore_id_fkey" FOREIGN KEY ("chore_id") REFERENCES "public"."chores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chore_events"
    ADD CONSTRAINT "chore_events_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chores"
    ADD CONSTRAINT "chores_assignee_user_id_fkey" FOREIGN KEY ("assignee_user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."chores"
    ADD CONSTRAINT "chores_created_by_user_id_fkey" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chores"
    ADD CONSTRAINT "chores_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expense_plan_debtors"
    ADD CONSTRAINT "expense_plan_debtors_debtor_user_id_fkey" FOREIGN KEY ("debtor_user_id") REFERENCES "public"."profiles"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."expense_plan_debtors"
    ADD CONSTRAINT "expense_plan_debtors_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."expense_plans"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."expense_plans"
    ADD CONSTRAINT "expense_plans_created_by_user_id_fkey" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."profiles"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."expense_plans"
    ADD CONSTRAINT "expense_plans_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "expense_splits_debtor_user_id_fkey" FOREIGN KEY ("debtor_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "expense_splits_expense_id_fkey" FOREIGN KEY ("expense_id") REFERENCES "public"."expenses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_created_by_user_id_fkey" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "fk_expenses_plan_id_restrict" FOREIGN KEY ("plan_id") REFERENCES "public"."expense_plans"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."house_vibes"
    ADD CONSTRAINT "fk_house_vibes_label_version" FOREIGN KEY ("mapping_version", "label_id") REFERENCES "public"."house_vibe_labels"("mapping_version", "label_id");



ALTER TABLE ONLY "public"."notification_sends"
    ADD CONSTRAINT "fk_notification_sends_token_id" FOREIGN KEY ("token_id") REFERENCES "public"."device_tokens"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_mentions"
    ADD CONSTRAINT "gratitude_wall_mentions_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_mentions"
    ADD CONSTRAINT "gratitude_wall_mentions_mentioned_user_id_fkey" FOREIGN KEY ("mentioned_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_mentions"
    ADD CONSTRAINT "gratitude_wall_mentions_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."gratitude_wall_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "gratitude_wall_personal_items_author_user_id_fkey" FOREIGN KEY ("author_user_id") REFERENCES "public"."profiles"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "gratitude_wall_personal_items_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "gratitude_wall_personal_items_recipient_user_id_fkey" FOREIGN KEY ("recipient_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "gratitude_wall_personal_items_source_entry_id_fkey" FOREIGN KEY ("source_entry_id") REFERENCES "public"."home_mood_entries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_personal_items"
    ADD CONSTRAINT "gratitude_wall_personal_items_source_post_id_fkey" FOREIGN KEY ("source_post_id") REFERENCES "public"."gratitude_wall_posts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gratitude_wall_personal_reads"
    ADD CONSTRAINT "gratitude_wall_personal_reads_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_posts"
    ADD CONSTRAINT "gratitude_wall_posts_author_user_id_fkey" FOREIGN KEY ("author_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_posts"
    ADD CONSTRAINT "gratitude_wall_posts_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_posts"
    ADD CONSTRAINT "gratitude_wall_posts_source_entry_id_fkey" FOREIGN KEY ("source_entry_id") REFERENCES "public"."home_mood_entries"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gratitude_wall_reads"
    ADD CONSTRAINT "gratitude_wall_reads_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gratitude_wall_reads"
    ADD CONSTRAINT "gratitude_wall_reads_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_entitlements"
    ADD CONSTRAINT "home_entitlements_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_mood_entries"
    ADD CONSTRAINT "home_mood_entries_gratitude_post_id_fkey" FOREIGN KEY ("gratitude_post_id") REFERENCES "public"."gratitude_wall_posts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."home_mood_entries"
    ADD CONSTRAINT "home_mood_entries_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_mood_entries"
    ADD CONSTRAINT "home_mood_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_mood_feedback_counters"
    ADD CONSTRAINT "home_mood_feedback_counters_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_mood_feedback_counters"
    ADD CONSTRAINT "home_mood_feedback_counters_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_nps"
    ADD CONSTRAINT "home_nps_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_nps"
    ADD CONSTRAINT "home_nps_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."home_usage_counters"
    ADD CONSTRAINT "home_usage_counters_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."homes"
    ADD CONSTRAINT "homes_owner_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."house_pulse_reads"
    ADD CONSTRAINT "house_pulse_reads_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."house_pulse_reads"
    ADD CONSTRAINT "house_pulse_reads_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."house_pulse_weekly"
    ADD CONSTRAINT "house_pulse_weekly_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."house_vibe_labels"
    ADD CONSTRAINT "house_vibe_labels_mapping_version_fkey" FOREIGN KEY ("mapping_version") REFERENCES "public"."house_vibe_versions"("mapping_version");



ALTER TABLE ONLY "public"."house_vibe_mapping_effects"
    ADD CONSTRAINT "house_vibe_mapping_effects_mapping_version_fkey" FOREIGN KEY ("mapping_version") REFERENCES "public"."house_vibe_versions"("mapping_version");



ALTER TABLE ONLY "public"."house_vibe_mapping_effects"
    ADD CONSTRAINT "house_vibe_mapping_effects_preference_id_fkey" FOREIGN KEY ("preference_id") REFERENCES "public"."preference_taxonomy"("preference_id");



ALTER TABLE ONLY "public"."house_vibes"
    ADD CONSTRAINT "house_vibes_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."house_vibes"
    ADD CONSTRAINT "house_vibes_mapping_version_fkey" FOREIGN KEY ("mapping_version") REFERENCES "public"."house_vibe_versions"("mapping_version");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."member_cap_join_requests"
    ADD CONSTRAINT "member_cap_join_requests_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."member_cap_join_requests"
    ADD CONSTRAINT "member_cap_join_requests_joiner_user_id_fkey" FOREIGN KEY ("joiner_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_sends"
    ADD CONSTRAINT "notification_sends_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."paywall_events"
    ADD CONSTRAINT "paywall_events_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."paywall_events"
    ADD CONSTRAINT "paywall_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_report_acknowledgements"
    ADD CONSTRAINT "preference_report_acknowledgements_report_id_fkey" FOREIGN KEY ("report_id") REFERENCES "public"."preference_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_report_acknowledgements"
    ADD CONSTRAINT "preference_report_acknowledgements_viewer_user_id_fkey" FOREIGN KEY ("viewer_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_report_revisions"
    ADD CONSTRAINT "preference_report_revisions_editor_user_id_fkey" FOREIGN KEY ("editor_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_report_revisions"
    ADD CONSTRAINT "preference_report_revisions_report_id_fkey" FOREIGN KEY ("report_id") REFERENCES "public"."preference_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_reports"
    ADD CONSTRAINT "preference_reports_last_edited_by_fkey" FOREIGN KEY ("last_edited_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."preference_reports"
    ADD CONSTRAINT "preference_reports_subject_user_id_fkey" FOREIGN KEY ("subject_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_responses"
    ADD CONSTRAINT "preference_responses_preference_id_fkey" FOREIGN KEY ("preference_id") REFERENCES "public"."preference_taxonomy"("preference_id");



ALTER TABLE ONLY "public"."preference_responses"
    ADD CONSTRAINT "preference_responses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preference_taxonomy_defs"
    ADD CONSTRAINT "preference_taxonomy_defs_preference_id_fkey" FOREIGN KEY ("preference_id") REFERENCES "public"."preference_taxonomy"("preference_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_avatar_id_fkey" FOREIGN KEY ("avatar_id") REFERENCES "public"."avatars"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."revenuecat_webhook_events"
    ADD CONSTRAINT "revenuecat_webhook_events_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."share_events"
    ADD CONSTRAINT "share_events_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id");



ALTER TABLE ONLY "public"."share_events"
    ADD CONSTRAINT "share_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."shared_preferences"
    ADD CONSTRAINT "shared_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_home_id_fkey" FOREIGN KEY ("home_id") REFERENCES "public"."homes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE "public"."analytics_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_version" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."avatars" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "avatars_select_authenticated" ON "public"."avatars" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") IS NOT NULL));



ALTER TABLE "public"."chore_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."device_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expense_plan_debtors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expense_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expense_splits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expenses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gratitude_wall_mentions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gratitude_wall_personal_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gratitude_wall_personal_reads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gratitude_wall_posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gratitude_wall_reads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_entitlements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_mood_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_mood_feedback_counters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_nps" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_plan_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."home_usage_counters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."homes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_pulse_labels" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_pulse_reads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_pulse_weekly" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_vibe_labels" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_vibe_mapping_effects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_vibe_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."house_vibes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."leads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."leads_rate_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."member_cap_join_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification_sends" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."paywall_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_report_acknowledgements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_report_revisions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_report_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_responses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_taxonomy" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preference_taxonomy_defs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_select_authenticated" ON "public"."profiles" FOR SELECT USING (("id" = ( SELECT "auth"."uid"() AS "uid")));



COMMENT ON POLICY "profiles_select_authenticated" ON "public"."profiles" IS 'Allows SELECT for authenticated users only (RLS enforced).';



ALTER TABLE "public"."reserved_usernames" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."revenuecat_event_processing" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."revenuecat_webhook_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."share_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shared_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_subscriptions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";








GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(character) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"("inet") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "anon";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "service_role";




















































































































































































REVOKE ALL ON FUNCTION "public"."_assert_active_profile"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_assert_active_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."_assert_active_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_assert_active_profile"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_assert_authenticated"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_assert_authenticated"() TO "service_role";



GRANT ALL ON FUNCTION "public"."_assert_home_active"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."_assert_home_active"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_assert_home_active"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_assert_home_member"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_assert_home_member"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_assert_home_owner"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_assert_home_owner"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."_assert_home_owner"("p_home_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."_chore_recurrence_to_every_unit"("p_recurrence" "public"."recurrence_interval") TO "anon";
GRANT ALL ON FUNCTION "public"."_chore_recurrence_to_every_unit"("p_recurrence" "public"."recurrence_interval") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_chore_recurrence_to_every_unit"("p_recurrence" "public"."recurrence_interval") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_chores_base_for_home"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_chores_base_for_home"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."_chores_base_for_home"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."_current_user_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_current_user_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_ensure_unique_avatar_for_home"("p_home_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_ensure_unique_avatar_for_home"("p_home_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."_ensure_unique_avatar_for_home"("p_home_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_ensure_unique_avatar_for_home"("p_home_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."expenses" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_expense_plan_generate_cycle"("p_plan_id" "uuid", "p_cycle_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_expense_plan_generate_cycle"("p_plan_id" "uuid", "p_cycle_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."_expense_plan_next_cycle_date"("p_interval" "public"."recurrence_interval", "p_from" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."_expense_plan_next_cycle_date"("p_interval" "public"."recurrence_interval", "p_from" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_expense_plan_next_cycle_date"("p_interval" "public"."recurrence_interval", "p_from" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."_expense_plan_next_cycle_date_v2"("p_every" integer, "p_unit" "text", "p_from" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."_expense_plan_next_cycle_date_v2"("p_every" integer, "p_unit" "text", "p_from" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_expense_plan_next_cycle_date_v2"("p_every" integer, "p_unit" "text", "p_from" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_expense_plans_terminate_for_member_change"("p_home_id" "uuid", "p_affected_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_expense_plans_terminate_for_member_change"("p_home_id" "uuid", "p_affected_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_expenses_prepare_split_buffer"("p_home_id" "uuid", "p_creator_id" "uuid", "p_amount_cents" bigint, "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_expenses_prepare_split_buffer"("p_home_id" "uuid", "p_creator_id" "uuid", "p_amount_cents" bigint, "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."_expenses_prepare_split_buffer"("p_home_id" "uuid", "p_creator_id" "uuid", "p_amount_cents" bigint, "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."_gen_invite_code"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_gen_invite_code"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_gen_unique_username"("p_email" "text", "p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_gen_unique_username"("p_email" "text", "p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."_gen_unique_username"("p_email" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_gen_unique_username"("p_email" "text", "p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_home_assert_quota"("p_home_id" "uuid", "p_deltas" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_home_assert_quota"("p_home_id" "uuid", "p_deltas" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_home_attach_subscription_to_home"("_user_id" "uuid", "_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_home_attach_subscription_to_home"("_user_id" "uuid", "_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_home_detach_subscription_to_home"("_home_id" "uuid", "_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_home_detach_subscription_to_home"("_home_id" "uuid", "_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_home_effective_plan"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_home_effective_plan"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."_home_effective_plan"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_home_effective_plan"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_home_is_premium"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_home_is_premium"("p_home_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."home_usage_counters" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_home_usage_apply_delta"("p_home_id" "uuid", "p_deltas" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_home_usage_apply_delta"("p_home_id" "uuid", "p_deltas" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."_house_vibe_confidence_kind"("p_label_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_house_vibe_confidence_kind"("p_label_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_house_vibe_confidence_kind"("p_label_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_house_vibes_mark_out_of_date"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_house_vibes_mark_out_of_date"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_house_vibes_mark_out_of_date_memberships"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_house_vibes_mark_out_of_date_memberships"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_house_vibes_mark_out_of_date_preferences"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_house_vibes_mark_out_of_date_preferences"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_iso_week_utc"("p_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_iso_week_utc"("p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."_iso_week_utc"("p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."_iso_week_utc"("p_at" timestamp with time zone) TO "service_role";



GRANT ALL ON TABLE "public"."member_cap_join_requests" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_member_cap_enqueue_request"("p_home_id" "uuid", "p_joiner_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_member_cap_enqueue_request"("p_home_id" "uuid", "p_joiner_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_member_cap_resolve_requests"("p_home_id" "uuid", "p_reason" "text", "p_request_ids" "uuid"[], "p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_member_cap_resolve_requests"("p_home_id" "uuid", "p_reason" "text", "p_request_ids" "uuid"[], "p_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."_preference_reports_mark_out_of_date"() TO "anon";
GRANT ALL ON FUNCTION "public"."_preference_reports_mark_out_of_date"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_preference_reports_mark_out_of_date"() TO "service_role";



GRANT ALL ON FUNCTION "public"."_preference_templates_validate"() TO "anon";
GRANT ALL ON FUNCTION "public"."_preference_templates_validate"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_preference_templates_validate"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_sha256_hex"("p_input" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_sha256_hex"("p_input" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_sha256_hex"("p_input" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_sha256_hex"("p_input" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_share_log_event_internal"("p_user_id" "uuid", "p_home_id" "uuid", "p_feature" "text", "p_channel" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_share_log_event_internal"("p_user_id" "uuid", "p_home_id" "uuid", "p_feature" "text", "p_channel" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_share_log_event_internal"("p_user_id" "uuid", "p_home_id" "uuid", "p_feature" "text", "p_channel" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."_touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."api_assert"("p_condition" boolean, "p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."api_assert"("p_condition" boolean, "p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_assert"("p_condition" boolean, "p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_assert"("p_condition" boolean, "p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."api_error"("p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."api_error"("p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."api_error"("p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."api_error"("p_code" "text", "p_msg" "text", "p_sqlstate" "text", "p_details" "jsonb", "p_hint" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."avatars_list_for_home"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."avatars_list_for_home"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."avatars_list_for_home"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avatars_list_for_home"("p_home_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "postgres";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "anon";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_app_version"("client_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_app_version"("client_version" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_app_version"("client_version" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_app_version"("client_version" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."chore_complete"("_chore_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chore_complete"("_chore_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."chore_complete"("_chore_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_cancel"("p_chore_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_cancel"("p_chore_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_cancel"("p_chore_id" "uuid") TO "authenticated";



GRANT ALL ON TABLE "public"."chores" TO "service_role";



REVOKE ALL ON FUNCTION "public"."chores_create"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_create"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_create"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_create_v2"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_create_v2"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_create_v2"("p_home_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_how_to_video_url" "text", "p_notes" "text", "p_expectation_photo_path" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_events_trigger"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_events_trigger"() TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_events_trigger"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_get_for_home"("p_home_id" "uuid", "p_chore_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_get_for_home"("p_home_id" "uuid", "p_chore_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_get_for_home"("p_home_id" "uuid", "p_chore_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_list_for_home"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_list_for_home"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_list_for_home"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_reassign_on_member_leave"("v_home_id" "uuid", "v_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_reassign_on_member_leave"("v_home_id" "uuid", "v_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."chores_update"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_update"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_update"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence" "public"."recurrence_interval", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."chores_update_v2"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chores_update_v2"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."chores_update_v2"("p_chore_id" "uuid", "p_name" "text", "p_assignee_user_id" "uuid", "p_start_date" "date", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_expectation_photo_path" "text", "p_how_to_video_url" "text", "p_notes" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "postgres";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "anon";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."expense_plans_generate_due_cycles"() TO "anon";
GRANT ALL ON FUNCTION "public"."expense_plans_generate_due_cycles"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."expense_plans_generate_due_cycles"() TO "service_role";



GRANT ALL ON TABLE "public"."expense_plans" TO "service_role";



REVOKE ALL ON FUNCTION "public"."expense_plans_terminate"("p_plan_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expense_plans_terminate"("p_plan_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expense_plans_terminate"("p_plan_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_cancel"("p_expense_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_cancel"("p_expense_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_cancel"("p_expense_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_create"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_create_v2"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_create_v2"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_create_v2"("p_home_id" "uuid", "p_description" "text", "p_amount_cents" bigint, "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_edit"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence" "public"."recurrence_interval", "p_start_date" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_edit_v2"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_edit_v2"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_edit_v2"("p_expense_id" "uuid", "p_amount_cents" bigint, "p_description" "text", "p_notes" "text", "p_split_mode" "public"."expense_split_type", "p_member_ids" "uuid"[], "p_splits" "jsonb", "p_recurrence_every" integer, "p_recurrence_unit" "text", "p_start_date" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_get_created_by_me"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_get_created_by_me"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_get_created_by_me"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_get_current_owed"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_get_current_owed"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_get_current_owed"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_get_current_paid_to_me_by_debtor_details"("p_home_id" "uuid", "p_debtor_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_get_current_paid_to_me_by_debtor_details"("p_home_id" "uuid", "p_debtor_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_get_current_paid_to_me_by_debtor_details"("p_home_id" "uuid", "p_debtor_user_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_get_current_paid_to_me_debtors"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_get_current_paid_to_me_debtors"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_get_current_paid_to_me_debtors"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_get_for_edit"("p_expense_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_get_for_edit"("p_expense_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_get_for_edit"("p_expense_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_mark_paid_received_viewed_for_debtor"("p_home_id" "uuid", "p_debtor_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_mark_paid_received_viewed_for_debtor"("p_home_id" "uuid", "p_debtor_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_mark_paid_received_viewed_for_debtor"("p_home_id" "uuid", "p_debtor_user_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."expenses_pay_my_due"("p_recipient_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."expenses_pay_my_due"("p_recipient_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."expenses_pay_my_due"("p_recipient_user_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "postgres";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "anon";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "service_role";



GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_plan_status"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_plan_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_plan_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_plan_status"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."gratitude_wall_list"("p_home_id" "uuid", "p_limit" integer, "p_cursor_created_at" timestamp with time zone, "p_cursor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gratitude_wall_list"("p_home_id" "uuid", "p_limit" integer, "p_cursor_created_at" timestamp with time zone, "p_cursor_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."gratitude_wall_list"("p_home_id" "uuid", "p_limit" integer, "p_cursor_created_at" timestamp with time zone, "p_cursor_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."gratitude_wall_mark_read"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gratitude_wall_mark_read"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."gratitude_wall_mark_read"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gratitude_wall_stats"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gratitude_wall_status"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."home_assignees_list"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_assignees_list"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."home_assignees_list"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."home_entitlements_refresh"("_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_entitlements_refresh"("_home_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."home_mood_feedback_counters_inc"() TO "anon";
GRANT ALL ON FUNCTION "public"."home_mood_feedback_counters_inc"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."home_mood_feedback_counters_inc"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."home_nps_get_status"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_nps_get_status"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."home_nps_get_status"("p_home_id" "uuid") TO "authenticated";



GRANT ALL ON TABLE "public"."home_nps" TO "service_role";



REVOKE ALL ON FUNCTION "public"."home_nps_submit"("p_home_id" "uuid", "p_score" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_nps_submit"("p_home_id" "uuid", "p_score" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."home_nps_submit"("p_home_id" "uuid", "p_score" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."homes_create_with_invite"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."homes_create_with_invite"() TO "service_role";
GRANT ALL ON FUNCTION "public"."homes_create_with_invite"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."homes_join"("p_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."homes_join"("p_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."homes_join"("p_code" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."homes_leave"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."homes_leave"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."homes_leave"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."homes_transfer_owner"("p_home_id" "uuid", "p_new_owner_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."homes_transfer_owner"("p_home_id" "uuid", "p_new_owner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."homes_transfer_owner"("p_home_id" "uuid", "p_new_owner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."homes_transfer_owner"("p_home_id" "uuid", "p_new_owner_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."house_pulse_weekly" TO "service_role";



REVOKE ALL ON FUNCTION "public"."house_pulse_compute_week"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."house_pulse_compute_week"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."house_pulse_compute_week"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."house_pulse_compute_week"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."house_pulse_label_get_v1"("p_pulse_state" "public"."house_pulse_state", "p_contract_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."house_pulse_label_get_v1"("p_pulse_state" "public"."house_pulse_state", "p_contract_version" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."house_pulse_label_get_v1"("p_pulse_state" "public"."house_pulse_state", "p_contract_version" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."house_pulse_label_get_v1"("p_pulse_state" "public"."house_pulse_state", "p_contract_version" "text") TO "service_role";



GRANT ALL ON TABLE "public"."house_pulse_reads" TO "service_role";



REVOKE ALL ON FUNCTION "public"."house_pulse_mark_seen"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."house_pulse_mark_seen"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."house_pulse_mark_seen"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."house_pulse_mark_seen"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."house_pulse_weekly_get"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."house_pulse_weekly_get"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."house_pulse_weekly_get"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."house_pulse_weekly_get"("p_home_id" "uuid", "p_iso_week_year" integer, "p_iso_week" integer, "p_contract_version" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."house_vibe_compute"("p_home_id" "uuid", "p_force" boolean, "p_include_axes" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."house_vibe_compute"("p_home_id" "uuid", "p_force" boolean, "p_include_axes" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."house_vibe_compute"("p_home_id" "uuid", "p_force" boolean, "p_include_axes" boolean) TO "authenticated";



GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "postgres";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "anon";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "service_role";



GRANT ALL ON TABLE "public"."invites" TO "service_role";



REVOKE ALL ON FUNCTION "public"."invites_get_active"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invites_get_active"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."invites_get_active"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invites_get_active"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."invites_revoke"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invites_revoke"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."invites_revoke"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invites_revoke"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."invites_rotate"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invites_rotate"("p_home_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."invites_rotate"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invites_rotate"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_home_owner"("p_home_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_home_owner"("p_home_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."leads_rate_limits_cleanup"() TO "anon";
GRANT ALL ON FUNCTION "public"."leads_rate_limits_cleanup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."leads_rate_limits_cleanup"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."leads_upsert_v1"("p_email" "text", "p_country_code" "text", "p_ui_locale" "text", "p_source" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."leads_upsert_v1"("p_email" "text", "p_country_code" "text", "p_ui_locale" "text", "p_source" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."leads_upsert_v1"("p_email" "text", "p_country_code" "text", "p_ui_locale" "text", "p_source" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."leads_upsert_v1"("p_email" "text", "p_country_code" "text", "p_ui_locale" "text", "p_source" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."locale_base"("p_locale" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."locale_base"("p_locale" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."locale_base"("p_locale" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."member_cap_owner_dismiss"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."member_cap_owner_dismiss"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."member_cap_owner_dismiss"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."member_cap_process_pending"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."member_cap_process_pending"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."members_kick"("p_home_id" "uuid", "p_target_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."members_kick"("p_home_id" "uuid", "p_target_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."members_kick"("p_home_id" "uuid", "p_target_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."members_kick"("p_home_id" "uuid", "p_target_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."members_list_active_by_home"("p_home_id" "uuid", "p_exclude_self" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."members_list_active_by_home"("p_home_id" "uuid", "p_exclude_self" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."members_list_active_by_home"("p_home_id" "uuid", "p_exclude_self" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."members_list_active_by_home"("p_home_id" "uuid", "p_exclude_self" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."membership_me_current"() TO "anon";
GRANT ALL ON FUNCTION "public"."membership_me_current"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."membership_me_current"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."mood_get_current_weekly"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mood_get_current_weekly"("p_home_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."mood_get_current_weekly"("p_home_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."mood_submit"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_add_to_wall" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mood_submit"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_add_to_wall" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."mood_submit"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_add_to_wall" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."mood_submit_v2"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_public_wall" boolean, "p_mentions" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mood_submit_v2"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_public_wall" boolean, "p_mentions" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."mood_submit_v2"("p_home_id" "uuid", "p_mood" "public"."mood_scale", "p_comment" "text", "p_public_wall" boolean, "p_mentions" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."notifications_daily_candidates"("p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_daily_candidates"("p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_daily_candidates"("p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_daily_candidates"("p_limit" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_mark_send_success"("p_send_id" "uuid", "p_user_id" "uuid", "p_local_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_mark_send_success"("p_send_id" "uuid", "p_user_id" "uuid", "p_local_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_mark_send_success"("p_send_id" "uuid", "p_user_id" "uuid", "p_local_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_mark_send_success"("p_send_id" "uuid", "p_user_id" "uuid", "p_local_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_mark_token_status"("p_token_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_mark_token_status"("p_token_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_mark_token_status"("p_token_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_mark_token_status"("p_token_id" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_reserve_send"("p_user_id" "uuid", "p_token_id" "uuid", "p_local_date" "date", "p_job_run_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_reserve_send"("p_user_id" "uuid", "p_token_id" "uuid", "p_local_date" "date", "p_job_run_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_reserve_send"("p_user_id" "uuid", "p_token_id" "uuid", "p_local_date" "date", "p_job_run_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_reserve_send"("p_user_id" "uuid", "p_token_id" "uuid", "p_local_date" "date", "p_job_run_id" "text") TO "service_role";



GRANT ALL ON TABLE "public"."notification_preferences" TO "anon";
GRANT ALL ON TABLE "public"."notification_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_preferences" TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_sync_client_state"("p_token" "text", "p_platform" "text", "p_locale" "text", "p_timezone" "text", "p_os_permission" "text", "p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_sync_client_state"("p_token" "text", "p_platform" "text", "p_locale" "text", "p_timezone" "text", "p_os_permission" "text", "p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_sync_client_state"("p_token" "text", "p_platform" "text", "p_locale" "text", "p_timezone" "text", "p_os_permission" "text", "p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_sync_client_state"("p_token" "text", "p_platform" "text", "p_locale" "text", "p_timezone" "text", "p_os_permission" "text", "p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_update_preferences"("p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_update_preferences"("p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_update_preferences"("p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_update_preferences"("p_wants_daily" boolean, "p_preferred_hour" integer, "p_preferred_minute" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."notifications_update_send_status"("p_send_id" "uuid", "p_status" "text", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notifications_update_send_status"("p_send_id" "uuid", "p_status" "text", "p_error" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_update_send_status"("p_send_id" "uuid", "p_status" "text", "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_update_send_status"("p_send_id" "uuid", "p_status" "text", "p_error" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "postgres";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "anon";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."paywall_log_event"("p_home_id" "uuid", "p_event_type" "text", "p_source" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[], "p_event_timestamp" timestamp with time zone, "p_environment" "text", "p_rc_event_id" "text", "p_original_transaction_id" "text", "p_raw_event" "jsonb", "p_warnings" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[], "p_event_timestamp" timestamp with time zone, "p_environment" "text", "p_rc_event_id" "text", "p_original_transaction_id" "text", "p_raw_event" "jsonb", "p_warnings" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[], "p_event_timestamp" timestamp with time zone, "p_environment" "text", "p_rc_event_id" "text", "p_original_transaction_id" "text", "p_raw_event" "jsonb", "p_warnings" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."paywall_record_subscription"("p_idempotency_key" "text", "p_user_id" "uuid", "p_home_id" "uuid", "p_store" "public"."subscription_store", "p_rc_app_user_id" "text", "p_entitlement_id" "text", "p_product_id" "text", "p_status" "public"."subscription_status", "p_current_period_end_at" timestamp with time zone, "p_original_purchase_at" timestamp with time zone, "p_last_purchase_at" timestamp with time zone, "p_latest_transaction_id" "text", "p_entitlement_ids" "text"[], "p_event_timestamp" timestamp with time zone, "p_environment" "text", "p_rc_event_id" "text", "p_original_transaction_id" "text", "p_raw_event" "jsonb", "p_warnings" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."paywall_status_get"("p_home_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."paywall_status_get"("p_home_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."paywall_status_get"("p_home_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."personal_gratitude_inbox_list_v1"("p_limit" integer, "p_before_at" timestamp with time zone, "p_before_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_gratitude_inbox_list_v1"("p_limit" integer, "p_before_at" timestamp with time zone, "p_before_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_gratitude_inbox_list_v1"("p_limit" integer, "p_before_at" timestamp with time zone, "p_before_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."personal_gratitude_showcase_stats_v1"("p_exclude_self" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_gratitude_showcase_stats_v1"("p_exclude_self" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_gratitude_showcase_stats_v1"("p_exclude_self" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."personal_gratitude_wall_mark_read_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_gratitude_wall_mark_read_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_gratitude_wall_mark_read_v1"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."personal_gratitude_wall_status_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_gratitude_wall_status_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_gratitude_wall_status_v1"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_reports_acknowledge"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_reports_acknowledge"("p_report_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_reports_acknowledge"("p_report_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_reports_edit_section_text"("p_template_key" "text", "p_locale" "text", "p_section_key" "text", "p_new_text" "text", "p_change_summary" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_reports_edit_section_text"("p_template_key" "text", "p_locale" "text", "p_section_key" "text", "p_new_text" "text", "p_change_summary" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_reports_edit_section_text"("p_template_key" "text", "p_locale" "text", "p_section_key" "text", "p_new_text" "text", "p_change_summary" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_reports_generate"("p_template_key" "text", "p_locale" "text", "p_force" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_reports_generate"("p_template_key" "text", "p_locale" "text", "p_force" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_reports_generate"("p_template_key" "text", "p_locale" "text", "p_force" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_reports_get_for_home"("p_home_id" "uuid", "p_subject_user_id" "uuid", "p_template_key" "text", "p_locale" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_reports_get_for_home"("p_home_id" "uuid", "p_subject_user_id" "uuid", "p_template_key" "text", "p_locale" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_reports_get_for_home"("p_home_id" "uuid", "p_subject_user_id" "uuid", "p_template_key" "text", "p_locale" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_reports_get_personal_v1"("p_template_key" "text", "p_locale" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_reports_get_personal_v1"("p_template_key" "text", "p_locale" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_reports_get_personal_v1"("p_template_key" "text", "p_locale" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_reports_list_for_home"("p_home_id" "uuid", "p_template_key" "text", "p_locale" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_reports_list_for_home"("p_home_id" "uuid", "p_template_key" "text", "p_locale" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_reports_list_for_home"("p_home_id" "uuid", "p_template_key" "text", "p_locale" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_responses_submit"("p_answers" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_responses_submit"("p_answers" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_responses_submit"("p_answers" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preference_templates_get_for_user"("p_template_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_templates_get_for_user"("p_template_key" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."preference_templates_get_for_user"("p_template_key" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."profile_identity_update"("p_username" "public"."citext", "p_avatar_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."profile_identity_update"("p_username" "public"."citext", "p_avatar_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."profile_identity_update"("p_username" "public"."citext", "p_avatar_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."profile_identity_update"("p_username" "public"."citext", "p_avatar_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."profile_me"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."profile_me"() TO "anon";
GRANT ALL ON FUNCTION "public"."profile_me"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."profile_me"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."profiles_request_deactivation"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."profiles_request_deactivation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."profiles_request_deactivation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "service_role";



REVOKE ALL ON FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."share_log_event"("p_home_id" "uuid", "p_feature" "text", "p_channel" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."today_flow_list"("p_home_id" "uuid", "p_state" "public"."chore_state", "p_local_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."today_flow_list"("p_home_id" "uuid", "p_state" "public"."chore_state", "p_local_date" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."today_flow_list"("p_home_id" "uuid", "p_state" "public"."chore_state", "p_local_date" "date") TO "authenticated";



GRANT ALL ON FUNCTION "public"."today_has_content"("p_user_id" "uuid", "p_timezone" "text", "p_local_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."today_has_content"("p_user_id" "uuid", "p_timezone" "text", "p_local_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."today_has_content"("p_user_id" "uuid", "p_timezone" "text", "p_local_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."today_onboarding_hints"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."today_onboarding_hints"() TO "anon";
GRANT ALL ON FUNCTION "public"."today_onboarding_hints"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."today_onboarding_hints"() TO "service_role";



GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."user_context_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_context_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."user_context_v1"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."user_subscriptions_home_entitlements_trigger"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_subscriptions_home_entitlements_trigger"() TO "service_role";












GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "service_role";















GRANT ALL ON TABLE "public"."analytics_events" TO "service_role";



GRANT ALL ON TABLE "public"."app_version" TO "service_role";



GRANT ALL ON TABLE "public"."avatars" TO "anon";
GRANT ALL ON TABLE "public"."avatars" TO "authenticated";
GRANT ALL ON TABLE "public"."avatars" TO "service_role";



GRANT ALL ON TABLE "public"."chore_events" TO "service_role";



GRANT ALL ON TABLE "public"."device_tokens" TO "anon";
GRANT ALL ON TABLE "public"."device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."expense_plan_debtors" TO "service_role";



GRANT ALL ON TABLE "public"."expense_splits" TO "service_role";



GRANT ALL ON TABLE "public"."gratitude_wall_mentions" TO "service_role";



GRANT ALL ON TABLE "public"."gratitude_wall_personal_items" TO "service_role";



GRANT ALL ON TABLE "public"."gratitude_wall_personal_reads" TO "service_role";



GRANT ALL ON TABLE "public"."gratitude_wall_posts" TO "service_role";



GRANT ALL ON TABLE "public"."gratitude_wall_reads" TO "service_role";



GRANT ALL ON TABLE "public"."home_entitlements" TO "service_role";



GRANT ALL ON TABLE "public"."home_mood_entries" TO "service_role";



GRANT ALL ON TABLE "public"."home_mood_feedback_counters" TO "service_role";



GRANT ALL ON TABLE "public"."home_plan_limits" TO "service_role";



GRANT ALL ON TABLE "public"."homes" TO "service_role";



GRANT ALL ON TABLE "public"."house_pulse_labels" TO "service_role";



GRANT ALL ON TABLE "public"."house_vibe_labels" TO "service_role";



GRANT ALL ON TABLE "public"."house_vibe_mapping_effects" TO "service_role";



GRANT ALL ON TABLE "public"."house_vibe_versions" TO "service_role";



GRANT ALL ON TABLE "public"."house_vibes" TO "service_role";



GRANT ALL ON TABLE "public"."leads" TO "service_role";



GRANT ALL ON TABLE "public"."leads_rate_limits" TO "service_role";



GRANT ALL ON TABLE "public"."memberships" TO "service_role";



GRANT ALL ON TABLE "public"."notification_sends" TO "anon";
GRANT ALL ON TABLE "public"."notification_sends" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_sends" TO "service_role";



GRANT ALL ON TABLE "public"."paywall_events" TO "service_role";



GRANT ALL ON TABLE "public"."preference_report_acknowledgements" TO "service_role";



GRANT ALL ON TABLE "public"."preference_report_revisions" TO "service_role";



GRANT ALL ON TABLE "public"."preference_report_templates" TO "service_role";



GRANT ALL ON TABLE "public"."preference_reports" TO "service_role";



GRANT ALL ON TABLE "public"."preference_responses" TO "service_role";



GRANT ALL ON TABLE "public"."preference_taxonomy" TO "service_role";



GRANT ALL ON TABLE "public"."preference_taxonomy_defs" TO "service_role";



GRANT ALL ON TABLE "public"."preference_taxonomy_active_defs" TO "anon";
GRANT ALL ON TABLE "public"."preference_taxonomy_active_defs" TO "authenticated";
GRANT ALL ON TABLE "public"."preference_taxonomy_active_defs" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profiles" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."reserved_usernames" TO "service_role";



GRANT ALL ON TABLE "public"."revenuecat_event_processing" TO "anon";
GRANT ALL ON TABLE "public"."revenuecat_event_processing" TO "authenticated";
GRANT ALL ON TABLE "public"."revenuecat_event_processing" TO "service_role";



GRANT ALL ON TABLE "public"."revenuecat_webhook_events" TO "service_role";



GRANT ALL ON TABLE "public"."share_events" TO "anon";
GRANT ALL ON TABLE "public"."share_events" TO "service_role";



GRANT ALL ON TABLE "public"."shared_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."user_subscriptions" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































