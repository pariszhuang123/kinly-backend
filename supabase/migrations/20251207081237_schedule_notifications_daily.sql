select cron.schedule(
  'notifications_daily_every_15m',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'SUPABASE_URL'
    ) || '/functions/v1/notifications_daily',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'SUPABASE_ANON_KEY'
      )
    ),
    body := jsonb_build_object(
      'scheduled_at', now()
    ),
    timeout_milliseconds := 8000
  );
  $$
);
