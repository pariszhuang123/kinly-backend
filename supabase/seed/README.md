# Supabase Seed Data

This folder contains seed SQL for local development.

## Apply seeds locally

1) Ensure your local Supabase stack is running.
2) Apply a seed file with the Supabase CLI:

```bash
supabase db reset --seed supabase/seed/preference_report_templates.sql
```

## Notes
- Seed files are optional for CI and tests unless a test explicitly requires them.
- Use seed files to load reference data (templates, lookup tables).
