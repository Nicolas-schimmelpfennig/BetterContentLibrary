-- Every minute, ask the edge function to send any due "time to post" pushes.
-- The service-role bearer is read from Vault at run time (secret name
-- 'service_role_key'); until that secret exists the call 401s and no-ops safely.
-- NOTE: superseded by 0010, which re-creates this job authenticating with the
-- x-cron-secret header (Vault secret 'cron_secret') to match the deployed
-- function's check — the live job had drifted from this definition.
select cron.schedule(
  'send-due-notifications',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://srltmrcwpdtjiiflwwkb.supabase.co/functions/v1/send-due-notifications',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || coalesce(
        (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        ''
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  $$
);
