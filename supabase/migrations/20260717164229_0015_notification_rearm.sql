-- Notification delivery fixes (see send-due-notifications v7, deployed together):
-- rescheduling re-arms the push, and the sender only stamps notified_at after a
-- successful send (with a retry cap tracked in notify_attempts).

-- How many cron passes have tried and failed to deliver this schedule's push;
-- the sender gives up and stamps notified_at once a cap is reached, so a dead
-- token or APNs outage can't make a row retry forever.
alter table public.schedules
  add column if not exists notify_attempts int not null default 0;

-- Moving a post to a new future time clears notified_at so the new time gets
-- its own push. Guarded to future times: backdating a row (e.g. recording that
-- something already went out yesterday) must not fire a surprise "time to
-- post" push for the past slot.
create or replace function public.reset_notified_on_reschedule()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.scheduled_at is distinct from old.scheduled_at
     and new.scheduled_at > now() then
    new.notified_at := null;
    new.notify_attempts := 0;
  end if;
  return new;
end;
$$;

-- Trigger-only function; nobody should call it via RPC.
revoke all on function public.reset_notified_on_reschedule() from public, anon, authenticated;

drop trigger if exists schedules_reset_notified on public.schedules;
create trigger schedules_reset_notified
  before update of scheduled_at on public.schedules
  for each row
  execute function public.reset_notified_on_reschedule();
