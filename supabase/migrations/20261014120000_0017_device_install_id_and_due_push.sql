-- 0017: one device row per install, and a second push at post time.
--
-- 1. Device identity. `devices` was unique on `apns_token` alone, so every
--    token a phone ever minted (reinstall, restore, dev build vs TestFlight)
--    kept its own row forever. The sender treats "any row accepted" as
--    delivered, and the sandbox gateway answers 200 for tokens whose install
--    is long gone — so a push that reached nobody could stamp as delivered.
--    Rows are now keyed on a stable per-install id the app keeps in its
--    Keychain (survives reinstalls): a rotated token *replaces* its row.
--    Registration goes through `register_device`, which also clears legacy
--    rows (no install id) for the caller, and any other row still holding
--    the same token.
--
-- 2. Due push. The only push used to fire NOTIFY_LEAD_SECONDS (15 min) early.
--    If that one alert was summarized, held by a Focus, or missed, nothing
--    arrived at post time. `due_notified_at` tracks a second "Time to post"
--    push at scheduled_at; both share an apns-collapse-id, so the second
--    replaces the first in Notification Center instead of stacking.

-- ---------------------------------------------------------------------------
-- 1. devices.install_id + registration RPCs
-- ---------------------------------------------------------------------------

alter table public.devices add column if not exists install_id text;

-- Plain (non-partial) unique index so `on conflict (install_id)` can infer it;
-- legacy rows keep a null install_id, and nulls never collide.
create unique index if not exists devices_install_id_key on public.devices (install_id);

create or replace function public.register_device(
  p_install_id  text,
  p_token       text,
  p_environment text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid := auth.uid();
  v_org     uuid;
begin
  if v_profile is null then
    raise exception 'not signed in';
  end if;
  if coalesce(p_install_id, '') = '' or coalesce(p_token, '') = '' then
    raise exception 'install id and token are required';
  end if;
  if p_environment not in ('sandbox', 'production') then
    raise exception 'unknown APNs environment %', p_environment;
  end if;

  select org_id into v_org from public.profiles where id = v_profile;
  if v_org is null then
    raise exception 'no profile for caller';
  end if;

  -- A token belongs to exactly one install. If another row still holds it
  -- (a pre-0017 row, or the same phone under a different account), it is
  -- superseded by this registration.
  delete from public.devices
   where apns_token = p_token
     and install_id is distinct from p_install_id;

  -- Rows written before install ids existed can't be matched to an install,
  -- so they are the stale-token pile this migration is about. Any install of
  -- this user registering replaces them; another still-live legacy install
  -- (e.g. an iPad on an old build) re-registers on its next launch.
  delete from public.devices
   where profile_id = v_profile
     and install_id is null;

  insert into public.devices (org_id, profile_id, apns_token, environment, install_id, updated_at)
  values (v_org, v_profile, p_token, p_environment, p_install_id, now())
  on conflict (install_id) do update
     set org_id      = excluded.org_id,
         profile_id  = excluded.profile_id,
         apns_token  = excluded.apns_token,
         environment = excluded.environment,
         updated_at  = now();
end $$;

-- Sign-out: stop pushing the previous user's posts to this phone.
create or replace function public.unregister_device(p_install_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.devices
   where install_id = p_install_id
     and profile_id = auth.uid();
end $$;

revoke all on function public.register_device(text, text, text) from public, anon;
revoke all on function public.unregister_device(text) from public, anon;
grant execute on function public.register_device(text, text, text) to authenticated;
grant execute on function public.unregister_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. schedules.due_notified_at + re-arm
-- ---------------------------------------------------------------------------

alter table public.schedules add column if not exists due_notified_at timestamptz;

-- Everything already at or past its time counts as handled, so the new column
-- can't fire a burst of "Time to post" pushes for old rows the moment the
-- sender starts reading it.
update public.schedules
   set due_notified_at = coalesce(notified_at, now())
 where due_notified_at is null
   and scheduled_at <= now();

-- Same scan shape as the lead push's partial index (schedules_notify_due_idx,
-- 0010); named apart from it on purpose — 0007's index silently no-opped on a
-- name collision.
create index if not exists schedules_post_time_notify_idx
  on public.schedules (scheduled_at)
  where due_notified_at is null and notify_profile_id is not null;

-- Moving a post to a future time re-arms both pushes (was: only the lead).
create or replace function public.reset_notified_on_reschedule()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.scheduled_at is distinct from old.scheduled_at
     and new.scheduled_at > now() then
    new.notified_at := null;
    new.due_notified_at := null;
    new.notify_attempts := 0;
  end if;
  return new;
end;
$$;
