-- Who to notify for a scheduled post (null = no notification).
alter table public.schedules
  add column if not exists notify_profile_id uuid references public.profiles(id) on delete set null;

-- Speeds the cron "due & unsent" scan.
-- NOTE: this never took effect — an index named schedules_due_idx already
-- existed (0001), so `if not exists` no-opped. Fixed in 0010 under a new name.
create index if not exists schedules_due_idx
  on public.schedules (scheduled_at)
  where notified_at is null and notify_profile_id is not null;

-- One row per device token, so the app can upsert on conflict.
create unique index if not exists devices_apns_token_key on public.devices (apns_token);

-- Scheduling + outbound HTTP for the notification cron.
create extension if not exists pg_cron;
create extension if not exists pg_net;
