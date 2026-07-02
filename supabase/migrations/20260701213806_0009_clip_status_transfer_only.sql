-- clip_status now describes the transfer lifecycle only:
--   ingesting -> uploading -> ready | failed
-- The old presentation values (scheduled/downloaded/posted) were never written
-- by any client and are derivable from schedules/downloads, so they go away.
-- 'failed' is added so a dead upload is visible instead of masquerading as
-- 'ingesting' forever.
create type clip_status_new as enum ('ingesting', 'uploading', 'ready', 'failed');

alter table public.clips alter column status drop default;

-- Belt and braces: no rows carry these values today.
update public.clips set status = 'ready' where status in ('scheduled', 'downloaded', 'posted');

alter table public.clips
  alter column status type clip_status_new using status::text::clip_status_new;

alter table public.clips alter column status set default 'ingesting';

drop type clip_status;
alter type clip_status_new rename to clip_status;
