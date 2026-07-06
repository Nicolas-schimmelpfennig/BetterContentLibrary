-- 0014: org membership — standing invite codes, enforced Admin/Member roles,
-- org-level R2 storage policy, and the join/leave/remove membership RPCs.
--
-- Role model: the existing user_role enum is reused — 'owner' is displayed as
-- "Admin", 'editor' as "Member" (manager/viewer are currently unused). Every
-- org must always keep at least one owner; the RPCs below enforce that.

-- ---------------------------------------------------------------------------
-- Invite codes + org-level storage policy columns
-- ---------------------------------------------------------------------------

create extension if not exists pgcrypto with schema extensions;

-- 8 chars from a 30-char alphabet (no I/L/O/U/0/1 — unambiguous to read
-- aloud). ~30^8 = 6.5e11 keyspace; org_preview is the only oracle and it is
-- authenticated-only.
create or replace function internal.generate_invite_code()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
  code text := '';
begin
  for i in 1..8 loop
    code := code || substr(alphabet, (get_byte(extensions.gen_random_bytes(1), 0) % 30) + 1, 1);
  end loop;
  return code;
end $$;
revoke all on function internal.generate_invite_code() from public, anon, authenticated;

alter table public.organizations
  add column invite_code text unique,
  add column storage_limit_gb integer not null default 5
    check (storage_limit_gb between 1 and 2000),
  add column eviction_order text not null default 'posted,pastScheduled,unscheduled';

update public.organizations
   set invite_code = internal.generate_invite_code()
 where invite_code is null;

alter table public.organizations
  alter column invite_code set default internal.generate_invite_code(),
  alter column invite_code set not null;

-- ---------------------------------------------------------------------------
-- Admin helper + privilege lock-down
-- ---------------------------------------------------------------------------

create or replace function internal.is_org_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner');
$$;
revoke all on function internal.is_org_admin() from public, anon;
grant execute on function internal.is_org_admin() to authenticated;

-- Org settings become admin-only, and invite_code is never directly writable
-- (regeneration goes through the RPC so old codes die atomically).
drop policy org_update on public.organizations;
create policy org_update on public.organizations
  for update using (id = internal.current_org_id() and internal.is_org_admin())
  with check (id = internal.current_org_id());
revoke update on public.organizations from anon, authenticated;
grant update (name, storage_limit_gb, eviction_order) on public.organizations to authenticated;

-- profiles: self-update shrinks to display_name. role/org_id changes only
-- happen inside the definer RPCs below; the trigger is belt-and-braces in
-- case a later migration loosens the column grants again.
revoke update on public.profiles from anon, authenticated;
grant update (display_name) on public.profiles to authenticated;

create or replace function internal.guard_profile_privileges()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.role is distinct from old.role or new.org_id is distinct from old.org_id)
     and current_user not in ('postgres', 'supabase_admin', 'supabase_auth_admin', 'service_role') then
    raise exception 'profile_privilege_change_forbidden';
  end if;
  return new;
end $$;
create trigger profiles_guard_privileges
  before update on public.profiles
  for each row execute function internal.guard_profile_privileges();

-- ---------------------------------------------------------------------------
-- Multi-user orgs are R2-only (iCloud bytes live in one person's Apple ID —
-- teammates could see the catalog row but never fetch the video)
-- ---------------------------------------------------------------------------

create or replace function internal.enforce_r2_for_teams()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.storage_provider <> 'r2'
     and (select count(*) from profiles where org_id = new.org_id) > 1 then
    raise exception 'multi_user_org_requires_r2';
  end if;
  return new;
end $$;
create trigger clips_enforce_r2
  before insert or update of storage_provider on public.clips
  for each row execute function internal.enforce_r2_for_teams();

-- ---------------------------------------------------------------------------
-- Membership RPCs. All security definer; errors use stable snake_case strings
-- the clients map to friendly messages.
-- ---------------------------------------------------------------------------

-- Join-sheet preview: lets any signed-in user resolve a code to a name +
-- member count before committing.
create or replace function public.org_preview(code text)
returns table (org_id uuid, org_name text, member_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.name, count(p.id)
    from organizations o
    left join profiles p on p.org_id = o.id
   where o.invite_code = upper(trim(code))
   group by o.id, o.name;
$$;

create or replace function public.regenerate_invite()
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  new_code text;
begin
  if not internal.is_org_admin() then
    raise exception 'not_admin';
  end if;
  loop
    new_code := internal.generate_invite_code();
    begin
      update organizations set invite_code = new_code
       where id = internal.current_org_id();
      return new_code;
    exception when unique_violation then
      -- astronomically unlikely; try another code
    end;
  end loop;
end $$;

create or replace function public.set_member_role(member uuid, new_role user_role)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  caller_org uuid := internal.current_org_id();
  target_org uuid;
  target_role user_role;
begin
  if not internal.is_org_admin() then
    raise exception 'not_admin';
  end if;
  if new_role not in ('owner', 'editor') then
    raise exception 'invalid_role';
  end if;
  select p.org_id, p.role into target_org, target_role from profiles p where p.id = member;
  if target_org is null or target_org <> caller_org then
    raise exception 'not_member';
  end if;
  if target_role = 'owner' and new_role <> 'owner'
     and (select count(*) from profiles where org_id = caller_org and role = 'owner') <= 1 then
    raise exception 'last_admin';
  end if;
  update profiles set role = new_role where id = member;
end $$;

-- Shared spin-out: park a departing member in a fresh personal org. Their
-- devices follow (RLS would block the client's own upsert across orgs), and
-- schedules in the org they left stop notifying them.
create or replace function internal.spin_out_profile(member uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  old_org uuid;
  new_org uuid;
begin
  select org_id into old_org from profiles where id = member;
  insert into organizations (name) values ('My Organization') returning id into new_org;
  update schedules set notify_profile_id = null
   where org_id = old_org and notify_profile_id = member;
  update profiles set org_id = new_org, role = 'owner' where id = member;
  update devices set org_id = new_org where profile_id = member;
  return new_org;
end $$;
revoke all on function internal.spin_out_profile(uuid) from public, anon, authenticated;

create or replace function public.remove_member(member uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  caller_org uuid := internal.current_org_id();
  target_org uuid;
begin
  if not internal.is_org_admin() then
    raise exception 'not_admin';
  end if;
  if member = auth.uid() then
    raise exception 'cannot_remove_self';
  end if;
  select p.org_id into target_org from profiles p where p.id = member;
  if target_org is null or target_org <> caller_org then
    raise exception 'not_member';
  end if;
  perform internal.spin_out_profile(member);
end $$;

create or replace function public.leave_org()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  caller_org uuid := internal.current_org_id();
  members int;
  admins int;
  my_role user_role;
begin
  select count(*) into members from profiles where org_id = caller_org;
  if members <= 1 then
    raise exception 'sole_member';
  end if;
  select p.role into my_role from profiles p where p.id = caller;
  select count(*) into admins from profiles where org_id = caller_org and role = 'owner';
  if my_role = 'owner' and admins <= 1 then
    raise exception 'last_admin';
  end if;
  perform internal.spin_out_profile(caller);
end $$;

-- The big one. "Bring my clips" is pure row moves: r2-sign presigns download/
-- delete on whatever key the row holds, so R2 bytes stay playable under their
-- old orgs/<uuid>/ prefix. Duplicates (content hash already in the target)
-- stay parked in the caller's old org rather than being destroyed.
create or replace function public.join_org(code text, bring_library boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  old_org uuid;
  my_role user_role;
  target uuid;
  old_members int;
  old_admins int;
  moved int := 0;
  skipped int := 0;
begin
  select p.org_id, p.role into old_org, my_role from profiles p where p.id = caller;
  if old_org is null then
    raise exception 'not_member';
  end if;

  select o.id into target from organizations o where o.invite_code = upper(trim(code));
  if target is null then
    raise exception 'invalid_code';
  end if;
  if target = old_org then
    raise exception 'already_member';
  end if;

  -- Can't abandon an org you solely administer while others remain in it.
  select count(*) into old_members from profiles where org_id = old_org;
  select count(*) into old_admins from profiles where org_id = old_org and role = 'owner';
  if old_members > 1 and my_role = 'owner' and old_admins <= 1 then
    raise exception 'last_admin';
  end if;

  -- The target must be collaborative (all-R2): iCloud bytes would be
  -- unreachable for the newcomer.
  if exists (select 1 from clips where org_id = target and storage_provider <> 'r2') then
    raise exception 'target_org_not_r2';
  end if;

  if bring_library then
    -- The caller converts iCloud clips to R2 first, while they still can.
    if exists (select 1 from clips where org_id = old_org and storage_provider <> 'r2') then
      raise exception 'icloud_clips_present';
    end if;

    select count(*) into skipped
      from clips c
     where c.org_id = old_org
       and c.content_hash is not null
       and exists (select 1 from clips t
                    where t.org_id = target and t.content_hash = c.content_hash);

    -- Folders move first so moved clips keep their folder references.
    update folders set org_id = target where org_id = old_org;

    update clips c set org_id = target
     where c.org_id = old_org
       and (c.content_hash is null
            or not exists (select 1 from clips t
                            where t.org_id = target and t.content_hash = c.content_hash));
    get diagnostics moved = row_count;

    -- Parked duplicates lost their folders to the move.
    update clips set folder_id = null where org_id = old_org;

    -- Schedules and download history follow their clip.
    update schedules s set org_id = target
      from clips c
     where s.clip_id = c.id and c.org_id = target and s.org_id = old_org;
    update downloads d set org_id = target
      from clips c
     where d.clip_id = c.id and c.org_id = target and d.org_id = old_org;

    -- Tags: move names that are free in the target, remap links onto existing
    -- same-name tags, drop links that could do neither.
    update tags set org_id = target
     where org_id = old_org
       and not exists (select 1 from tags t where t.org_id = target and t.name = tags.name);
    update clip_tags ct set tag_id = t2.id
      from tags t1, tags t2, clips c
     where ct.tag_id = t1.id and t1.org_id = old_org
       and t2.org_id = target and t2.name = t1.name
       and ct.clip_id = c.id and c.org_id = target
       and not exists (select 1 from clip_tags x
                        where x.clip_id = ct.clip_id and x.tag_id = t2.id);
    delete from clip_tags ct
     using tags t1, clips c
     where ct.tag_id = t1.id and t1.org_id = old_org
       and ct.clip_id = c.id and c.org_id = target;
  end if;

  -- Anything left behind stops notifying the departing member.
  update schedules set notify_profile_id = null
   where org_id = old_org and notify_profile_id = caller;

  update profiles set org_id = target, role = 'editor' where id = caller;
  update devices set org_id = target where profile_id = caller;

  return jsonb_build_object(
    'org_id', target,
    'moved_clips', moved,
    'skipped_duplicates', skipped
  );
end $$;

-- API exposure: signed-in users only.
revoke all on function public.org_preview(text) from public, anon;
revoke all on function public.regenerate_invite() from public, anon;
revoke all on function public.set_member_role(uuid, user_role) from public, anon;
revoke all on function public.remove_member(uuid) from public, anon;
revoke all on function public.leave_org() from public, anon;
revoke all on function public.join_org(text, boolean) from public, anon;
grant execute on function public.org_preview(text) to authenticated;
grant execute on function public.regenerate_invite() to authenticated;
grant execute on function public.set_member_role(uuid, user_role) to authenticated;
grant execute on function public.remove_member(uuid) to authenticated;
grant execute on function public.leave_org() to authenticated;
grant execute on function public.join_org(text, boolean) to authenticated;
