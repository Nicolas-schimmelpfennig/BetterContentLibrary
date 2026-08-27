-- Push delivery triage — paste into the Supabase dashboard SQL editor.
--
-- Run this when "time to post" pushes stop arriving. It walks the pipeline
-- backwards from APNs and tells you which hop is broken. It needs no
-- migration and writes nothing, so it is safe to run at any time.
--
--   schedules ──> pg_cron ──> pg_net ──> edge function ──> APNs ──> iPhone
--                    §1         §2           §3            §4
--
-- Migration 0016 automates §2/§3 continuously; this script is the manual
-- version and covers §1 and §4 as well.

-- §1 ── Is the cron job firing at all? -------------------------------------
-- Expect one row per minute, status 'succeeded'. Note that 'succeeded' only
-- means the SQL ran — net.http_post returns an id without waiting for the
-- HTTP call, so this says nothing about whether the request went out.
select jobid, jobname, schedule, active, command
  from cron.job
 where jobname in ('send-due-notifications', 'check-notification-delivery');

select status, count(*), max(start_time) as most_recent, min(start_time) as oldest
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'send-due-notifications')
   and start_time > now() - interval '2 hours'
 group by status;

-- Recent failures in full, if any.
select start_time, status, return_message
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'send-due-notifications')
   and status <> 'succeeded'
   and start_time > now() - interval '24 hours'
 order by start_time desc
 limit 10;

-- §2 ── Did pg_net actually dispatch the requests? -------------------------
-- The failure mode migration 0011 risked: after `drop extension pg_net;
-- create extension pg_net ...` on a live database, the background worker
-- stays attached to the old state. http_post keeps returning ids, the queue
-- keeps growing, and nothing is ever sent.
--
-- The queue carries no timestamp, so read it as a depth gauge: the worker
-- drains continuously, so more than a handful of rows — and above all a depth
-- that does not fall when you re-run this — means it is not draining.
--     Remedy:  select net.worker_restart();
select count(*) as queued, min(id) as oldest_id, max(id) as newest_id
  from net.http_request_queue;

-- §3 ── What did the edge function reply? ----------------------------------
-- pg_net keeps responses for ~6 hours. An empty result here while §1 shows
-- the job succeeding is the same worker-stall signature as §2.
--
--   200  → the function ran; go to §4
--   401  → the platform gateway rejected the call before the function ran.
--          The job sends only x-cron-secret (no Authorization header), so
--          this means verify_jwt is on. Redeploy with supabase/config.toml:
--            supabase functions deploy send-due-notifications
--   5xx  → the function itself threw; read its logs in the dashboard
select status_code, count(*), max(created) as most_recent,
       (array_agg(content order by created desc))[1] as latest_body
  from net._http_response
 where created > now() - interval '6 hours'
 group by status_code
 order by count(*) desc;

-- §4 ── Is there anything to send, and anyone to send it to? ---------------
-- Schedules the sender would pick up on its next pass (planned, unnotified,
-- inside the 15-minute lead window).
select s.id, s.scheduled_at, s.platform, s.notify_profile_id, s.notify_attempts,
       (select count(*) from devices d where d.profile_id = s.notify_profile_id) as devices
  from schedules s
 where s.notified_at is null
   and s.status = 'planned'
   and s.notify_profile_id is not null
   and s.scheduled_at <= now() + interval '15 minutes'
 order by s.scheduled_at
 limit 20;

-- Registered devices. `devices = 0` above with rows here for a different
-- profile means the notify target is not the person holding the phone.
select d.id, d.profile_id, p.display_name, d.environment, d.updated_at,
       left(d.apns_token, 8) || '…' as token
  from devices d
  left join profiles p on p.id = d.profile_id
 order by d.updated_at desc;

-- Schedules that gave up (attempt cap reached) or were notified recently —
-- useful for confirming a fix took effect.
select id, scheduled_at, notified_at, notify_attempts
  from schedules
 where notified_at > now() - interval '24 hours'
 order by notified_at desc
 limit 20;
