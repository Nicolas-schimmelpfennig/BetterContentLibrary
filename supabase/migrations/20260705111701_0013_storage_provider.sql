-- 0013: pluggable byte storage. Each clip records which provider holds its
-- video/thumbnail bytes; Supabase remains the catalog for all providers.
-- 'r2' = Cloudflare R2 via the r2-sign edge function (org-shared);
-- 'icloud' = the uploader's iCloud Drive (personal; r2_key is a relative
--            path inside the app's ubiquity container);
-- 'gdrive' = the uploader's Google Drive (personal; r2_key will be the
--            Drive file id — backend lands in a later release).
-- r2_key therefore now reads as "storage key within the clip's provider".
alter table public.clips
  add column storage_provider text not null default 'r2'
  check (storage_provider in ('r2', 'icloud', 'gdrive'));
