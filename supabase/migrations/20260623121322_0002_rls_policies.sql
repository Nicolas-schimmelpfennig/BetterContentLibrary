-- Helper: the org_id of the currently authenticated user.
-- SECURITY DEFINER so it reads profiles without triggering RLS recursion.
create or replace function public.current_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select org_id from public.profiles where id = auth.uid();
$$;

-- Enable RLS everywhere
alter table organizations enable row level security;
alter table profiles      enable row level security;
alter table clips         enable row level security;
alter table schedules     enable row level security;
alter table tags          enable row level security;
alter table clip_tags     enable row level security;
alter table downloads     enable row level security;
alter table devices       enable row level security;

-- Organizations: members can see/update their own org
create policy org_select on organizations
  for select using (id = public.current_org_id());
create policy org_update on organizations
  for update using (id = public.current_org_id());

-- Profiles: members can see all profiles in their org; can update their own row
create policy profiles_select on profiles
  for select using (org_id = public.current_org_id());
create policy profiles_update_self on profiles
  for update using (id = auth.uid());

-- Generic org-scoped full access for the core content tables
create policy clips_all on clips
  for all using (org_id = public.current_org_id())
  with check (org_id = public.current_org_id());

create policy schedules_all on schedules
  for all using (org_id = public.current_org_id())
  with check (org_id = public.current_org_id());

create policy tags_all on tags
  for all using (org_id = public.current_org_id())
  with check (org_id = public.current_org_id());

create policy downloads_all on downloads
  for all using (org_id = public.current_org_id())
  with check (org_id = public.current_org_id());

create policy devices_all on devices
  for all using (org_id = public.current_org_id())
  with check (org_id = public.current_org_id());

-- clip_tags has no org_id; gate via the parent clip's org
create policy clip_tags_all on clip_tags
  for all using (
    exists (select 1 from clips c where c.id = clip_tags.clip_id and c.org_id = public.current_org_id())
  )
  with check (
    exists (select 1 from clips c where c.id = clip_tags.clip_id and c.org_id = public.current_org_id())
  );
