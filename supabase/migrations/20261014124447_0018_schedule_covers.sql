-- 0018: custom thumbnails ("covers") on scheduled posts.
--
-- A cover is the image uploaded alongside a scheduled video — the custom
-- thumbnail to set on the platform at post time. It belongs to the schedule,
-- not the clip: the same video posted to YouTube and Instagram usually wants
-- different covers. It's a separate file from the clip's auto-generated
-- poster (`clips.thumb_key`), which keeps driving the library grid.
--
-- The bytes live with a storage provider like clip bytes do (0013), recorded
-- per row so a cover stays reachable even if its clip is later migrated to
-- another provider:
--   r2     -> orgs/<org>/covers/<schedule_id>-<nonce>.<jpg|png>   (r2-sign kind "cover")
--   icloud -> Covers/<schedule_id>-<nonce>.<jpg|png>              (iCloud Drive container)
-- A fresh nonce per upload means replacing a cover always yields a new key,
-- so clients can cache cover bytes by key without ever going stale.

alter table public.schedules
  add column if not exists cover_key text,
  add column if not exists cover_provider text;

alter table public.schedules
  drop constraint if exists schedules_cover_provider_check;
alter table public.schedules
  add constraint schedules_cover_provider_check
  check (cover_provider in ('r2', 'icloud', 'gdrive'));

-- A key without a provider (or vice versa) can't be resolved; keep them paired.
alter table public.schedules
  drop constraint if exists schedules_cover_pair_check;
alter table public.schedules
  add constraint schedules_cover_pair_check
  check ((cover_key is null) = (cover_provider is null));
