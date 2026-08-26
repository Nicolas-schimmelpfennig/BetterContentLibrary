-- 0016: make the pg_cron -> pg_net -> edge function hop observable.
--
-- Everything between the cron job and APNs was silent. `net.http_post` is
-- fire-and-forget: it enqueues a request, returns an id, and pg_cron records
-- the job as succeeded — whether or not the HTTP call ever went out or came
-- back 200. Nothing in the project has ever read `net._http_response`, so two
-- total-outage failure modes could (and did) run for weeks looking healthy:
--
--   * pg_net's background worker not draining the queue. 0011 did
--     `drop extension pg_net; create extension pg_net ...` on a live database;
--     a recreated extension leaves the worker attached to the old state, so
--     requests queue forever and are never dispatched. Remedy once seen:
--     `select net.worker_restart();`
--   * the platform gateway 401ing every call, because the function was
--     redeployed without `--no-verify-jwt` (the cron job sends only
--     `x-cron-secret`, no Authorization header). Now pinned in
--     supabase/config.toml so the deploy flag can't drift again.
--
-- This migration records the request id of every dispatch, then checks the
-- outcomes every 15 minutes and writes a verdict you can query:
--
--   select * from internal.notification_delivery_log order by checked_at desc limit 20;
--   select internal.check_notification_delivery();   -- on demand
--
-- Note the dispatch table only starts filling when this migration is applied,
-- so the first reading is 'no_data' until a couple of cron minutes have run.

-- ---------------------------------------------------------------------------
-- Dispatch ledger: which pg_net request id belongs to the notification job
-- ---------------------------------------------------------------------------

-- `net._http_response` records no URL, so a request id is the only way to tell
-- this job's calls apart from any other pg_net traffic (r2-sign, future jobs).
create table if not exists internal.notification_dispatch (
  request_id  bigint primary key,
  enqueued_at timestamptz not null default now()
);
create index if not exists notification_dispatch_enqueued_idx
  on internal.notification_dispatch (enqueued_at);

-- Re-assert the sender job so it records the id it enqueued. Unchanged
-- otherwise: same schedule, same URL, same x-cron-secret auth as 0010.
-- cron.schedule upserts by job name.
select cron.schedule(
  'send-due-notifications',
  '* * * * *',
  $job$
  insert into internal.notification_dispatch (request_id)
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

-- ---------------------------------------------------------------------------
-- Health log + the check that writes it
-- ---------------------------------------------------------------------------

create table if not exists internal.notification_delivery_log (
  id           bigserial primary key,
  checked_at   timestamptz not null default now(),
  window_start timestamptz not null,
  window_end   timestamptz not null,
  dispatched   int not null,   -- requests the cron job enqueued in the window
  responded    int not null,   -- of those, how many pg_net has a response for
  succeeded    int not null,   -- of those responses, 2xx
  failed       int not null,   -- non-2xx, or a transport error with no status
  undispatched int not null,   -- enqueued but never dispatched (worker stalled)
  verdict      text not null,
  detail       text
);
create index if not exists notification_delivery_log_checked_idx
  on internal.notification_delivery_log (checked_at desc);

create or replace function internal.check_notification_delivery()
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  -- Old enough that a response should have landed by now, young enough to be
  -- inside pg_net's response retention (~6 h by default).
  w_end        timestamptz := now() - interval '2 minutes';
  w_start      timestamptz := now() - interval '32 minutes';
  ever         boolean;
  dispatched   int;
  responded    int;
  succeeded    int;
  failed       int;
  undispatched int;
  verdict      text;
  detail       text;
begin
  select exists (select 1 from internal.notification_dispatch) into ever;

  select count(*) into dispatched
    from internal.notification_dispatch d
   where d.enqueued_at >= w_start and d.enqueued_at < w_end;

  select count(*),
         count(*) filter (where r.status_code between 200 and 299),
         count(*) filter (where r.status_code is null or r.status_code not between 200 and 299)
    into responded, succeeded, failed
    from internal.notification_dispatch d
    join net._http_response r on r.id = d.request_id
   where d.enqueued_at >= w_start and d.enqueued_at < w_end;

  undispatched := dispatched - responded;

  -- What the failures actually said, deduped (e.g. '401', '500', 'no status …').
  select string_agg(distinct
           coalesce(r.status_code::text, 'no status')
           || coalesce(' ' || nullif(btrim(r.error_msg), ''), '')
           || case when r.timed_out then ' (timed out)' else '' end,
           '; ')
    into detail
    from internal.notification_dispatch d
    join net._http_response r on r.id = d.request_id
   where d.enqueued_at >= w_start and d.enqueued_at < w_end
     and (r.status_code is null or r.status_code not between 200 and 299);

  verdict := case
    when not ever                       then 'no_data'
    when dispatched = 0                 then 'no_dispatch'
    when undispatched = dispatched      then 'worker_stalled'
    when succeeded = 0                  then 'all_failed'
    when undispatched > 0 or failed > 0 then 'degraded'
    else 'ok'
  end;

  -- Name the remedy in the log line, so whoever reads it doesn't have to
  -- rediscover which of the two silent hops broke.
  if verdict = 'worker_stalled' then
    detail := format(
      '%s request(s) enqueued, none dispatched — pg_net''s background worker is not draining the queue. Remedy: select net.worker_restart();',
      dispatched);
  elsif verdict = 'no_dispatch' then
    detail := 'the send-due-notifications cron job enqueued nothing this window — check: select * from cron.job where jobname = ''send-due-notifications'';';
  else
    if undispatched > 0 then
      detail := format('%s of %s request(s) never dispatched (pg_net worker stalling or falling behind)',
                       undispatched, dispatched)
                || coalesce('; ' || detail, '');
    end if;
    if verdict = 'all_failed' then
      detail := coalesce(detail, 'no response detail') || ' — every call rejected.';
    end if;
    -- Only volunteer the verify_jwt remedy when a 401 was actually seen; a
    -- timeout or a 5xx has nothing to do with the gateway's JWT check.
    if detail like '%401%' then
      detail := detail || ' A 401 means the function is deployed with verify_jwt on; redeploy with the setting in supabase/config.toml.';
    end if;
  end if;

  insert into internal.notification_delivery_log (
    window_start, window_end, dispatched, responded, succeeded, failed, undispatched, verdict, detail
  ) values (w_start, w_end, dispatched, responded, succeeded, failed, undispatched, verdict, detail);

  if verdict not in ('ok', 'no_data') then
    raise warning 'push delivery %: % (dispatched=% ok=% failed=% undispatched=%)',
      verdict, coalesce(detail, ''), dispatched, succeeded, failed, undispatched;
  end if;

  -- Keep both tables bounded: the ledger accrues ~1440 rows/day.
  delete from internal.notification_dispatch    where enqueued_at < now() - interval '2 days';
  delete from internal.notification_delivery_log where checked_at  < now() - interval '90 days';

  return verdict;
end $$;

-- Diagnostic helper; nothing should reach it over the API. (The `internal`
-- schema is already unserved by PostgREST since 0011 — belt and braces.)
revoke all on function internal.check_notification_delivery() from public, anon, authenticated;

select cron.schedule(
  'check-notification-delivery',
  '*/15 * * * *',
  $job$ select internal.check_notification_delivery(); $job$
);
