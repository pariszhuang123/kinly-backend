# Interest Capture v1 — Backend Implementation Draft

## 1. Database Schema (PostgreSQL)

```sql
-- Enable UUID extension if not already enabled
create extension if not exists "pgcrypto";

-- 1. Table: leads
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  country_code text not null,
  ui_locale text not null,
  source text not null default 'kinly_web_get',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  
  constraint leads_email_key unique (email),
  constraint leads_country_code_check check (country_code ~ '^[A-Z]{2}$'),
  constraint leads_ui_locale_check check (position(' ' in ui_locale) = 0)
);

-- 2. Security: Enable RLS
alter table public.leads enable row level security;

-- Policy: No public access directly (only via RPC with security definer)
-- We strictly deny all operations to anon/authenticated roles directly on the table for now.
-- Ideally, create a specific policy if partial access is needed, 
-- but "deny all unless via function" is the default state if no policies exist 
-- and RLS is enabled. Providing an explicit empty policy for clarity:
create policy "No direct access to leads"
  on public.leads
  for all
  using (false);

-- 3. Indexing
create index if not exists leads_created_at_idx on public.leads (created_at desc);

-- 4. RPC: leads_upsert_v1
create or replace function public.leads_upsert_v1(
  p_email text,
  p_country_code text,
  p_ui_locale text,
  p_source text default 'kinly_web_get'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead_id uuid;
  v_deduped boolean;
begin
  -- Normalize inputs inside DB as a safety net (though Edge should handle it)
  p_email := lower(trim(p_email));
  p_country_code := upper(trim(p_country_code));
  p_ui_locale := trim(p_ui_locale);

  -- Try to insert
  insert into public.leads (email, country_code, ui_locale, source)
  values (p_email, p_country_code, p_ui_locale, p_source)
  on conflict (email) do update
  set
    country_code = excluded.country_code,
    ui_locale = excluded.ui_locale,
    updated_at = now()
  returning id, (xmax <> 0) as deduped -- xmax <> 0 checks if it was an update
  into v_lead_id, v_deduped;

  -- If it was an update, v_deduped will be true. If insert, false (effectively).
  -- Note: on conflict update logic in Postgres:
  -- If row exists, it updates. We consider this 'deduped'.
  
  -- However, constructing the true boolean from standard plpgsql patterns:
  if found then
     -- The insert ... returning ... works for both insert and update cases in modern PG
     -- checking system columns xmax is a bit low-level but effective for upserts.
     -- Alternatively, we can check if created_at changes, but let's stick to the flow.
     null; 
  end if;

  return jsonb_build_object(
    'lead_id', v_lead_id,
    'deduped', (v_deduped is not null and v_deduped) -- Ensure boolean
  );
end;
$$;
```

## 2. Edge Function (TypeScript)

**Path**: `supabase/functions/interest_capture_v1/index.ts` (Example)

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
        "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
    // 1. CORS Preflight
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: corsHeaders });
    }

    try {
        // 2. Input Parsing
        const { email, country_code, ui_locale } = await req.json();

        // 3. Validation
        const errors: Record<string, string> = {};

        // Email
        if (!email || typeof email !== "string") {
            errors.email = "missing";
        } else {
            const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
            if (!email.trim() || !emailRegex.test(email.trim())) {
                errors.email = "invalid_format";
            }
        }

        // Country Code
        if (!country_code || typeof country_code !== "string") {
            errors.country_code = "missing";
        } else if (!/^[A-Z]{2}$/.test(country_code.toUpperCase().trim())) {
            errors.country_code = "invalid_format_iso2";
        }

        // Locale
        if (!ui_locale || typeof ui_locale !== "string") {
            errors.ui_locale = "missing";
        } else {
            const trimmedLocale = ui_locale.trim();
            if (
                trimmedLocale.length < 2 || trimmedLocale.length > 35 ||
                /\s/.test(trimmedLocale)
            ) {
                errors.ui_locale = "invalid_format";
            }
        }

        if (Object.keys(errors).length > 0) {
            return new Response(
                JSON.stringify({
                    ok: false,
                    error: "validation_failed",
                    fields: errors,
                }),
                {
                    status: 400,
                    headers: {
                        ...corsHeaders,
                        "Content-Type": "application/json",
                    },
                },
            );
        }

        // 4. Normalization
        const normalizedEmail = email.trim().toLowerCase();
        const normalizedCountry = country_code.trim().toUpperCase();
        const normalizedLocale = ui_locale.trim(); // Further casing normalization could happen here

        // 5. RPC Call
        const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
        const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""; // Must use service role to bypass policies if needed, or anon if RPC is public and secure.
        // Contract says "RPC MUST NOT require user authentication".
        // Using ANON key is safer if RPC is truly public, but if RLS prevents direct access,
        // and RPC has 'security definer', ANON key is fine.

        // However, usually Edge Functions have a service role available.
        // Let's use the Client injected from Auth context if possible, or create a client.
        // For a public non-auth endpoint, we create a client with ANON key usually,
        // but here we are acting as the backend.

        const supabase = createClient(supabaseUrl, supabaseKey);

        const { data, error } = await supabase.rpc("leads_upsert_v1", {
            p_email: normalizedEmail,
            p_country_code: normalizedCountry,
            p_ui_locale: normalizedLocale,
            p_source: "kinly_web_get",
        });

        if (error) {
            console.error("RPC Error:", error);
            return new Response(
                JSON.stringify({ ok: false, error: "internal_error" }),
                {
                    status: 500,
                    headers: {
                        ...corsHeaders,
                        "Content-Type": "application/json",
                    },
                },
            );
        }

        // 6. Success Response
        return new Response(JSON.stringify({ ok: true, ...data }), {
            status: 200,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    } catch (error) {
        console.error("Handler Error:", error);
        return new Response(
            JSON.stringify({ ok: false, error: "bad_request" }),
            {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            },
        );
    }
});
```
