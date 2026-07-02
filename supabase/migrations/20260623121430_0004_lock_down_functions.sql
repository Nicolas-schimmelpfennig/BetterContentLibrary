-- handle_new_user is invoked only by the auth trigger (runs as definer regardless),
-- so no role should be able to call it via RPC.
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- current_org_id is needed by RLS for signed-in users, but not by anonymous callers.
revoke all on function public.current_org_id() from public, anon;
grant execute on function public.current_org_id() to authenticated;
