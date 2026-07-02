-- On new signup: create an organization and an owner profile for the user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org_id uuid;
begin
  insert into public.organizations (name)
  values (coalesce(new.raw_user_meta_data->>'org_name', 'My Organization'))
  returning id into new_org_id;

  insert into public.profiles (id, org_id, display_name, role)
  values (
    new.id,
    new_org_id,
    coalesce(new.raw_user_meta_data->>'display_name', new.email),
    'owner'
  );

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep clips.updated_at fresh
create extension if not exists moddatetime schema extensions;

create trigger clips_set_updated_at
  before update on clips
  for each row execute function extensions.moddatetime(updated_at);

-- Realtime: stream clip + schedule changes to subscribed clients
alter publication supabase_realtime add table clips;
alter publication supabase_realtime add table schedules;
