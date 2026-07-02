-- The partial index intended by 0007 never materialized: 0001 had already taken
-- the name schedules_due_idx, so its `if not exists` no-opped. Create it for real.
create index if not exists schedules_notify_due_idx
  on public.schedules (scheduled_at)
  where notified_at is null and notify_profile_id is not null;

-- Re-assert the notification cron job in its current, working form: the deployed
-- edge function authenticates via the x-cron-secret header (Vault secret
-- 'cron_secret'), not the service-role bearer that 0008 originally set up.
-- cron.schedule upserts by job name, so this replaces the drifted definition.
select cron.schedule(
  'send-due-notifications',
  '* * * * *',
  $job$
  select net.http_post(
    url := 'https://srltmrcwpdtjiiflwwkb.supabase.co/functions/v1/send-due-notifications',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret'), '')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  $job$
);
