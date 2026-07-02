-- Advisor 0014: extensions don't belong in the public schema. pg_net is not
-- relocatable, so drop and recreate it registered under `extensions`. Its API
-- (net.http_post etc.) lives in the dedicated `net` schema either way, so the
-- notification cron job is unaffected.
drop extension if exists pg_net;
create extension pg_net with schema extensions;

-- Advisor 0029: current_org_id() is SECURITY DEFINER and was callable by
-- signed-in users via /rest/v1/rpc. It only returns the caller's own org id,
-- but it has no business being API-exposed. Move it to a schema PostgREST
-- doesn't serve; RLS policies reference it by OID, so they keep working.
-- `authenticated` keeps EXECUTE (granted in 0004) since RLS evaluation runs
-- the function as the querying role.
create schema if not exists internal;
alter function public.current_org_id() set schema internal;
grant usage on schema internal to authenticated;
