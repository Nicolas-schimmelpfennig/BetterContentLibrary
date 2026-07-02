-- Per-schedule caption: the post text itself, written at scheduling time and
-- copied at post time (per-platform, so IG and TikTok captions can differ).
-- Distinct from `notes`, which stays internal and is never pasted into a post.
alter table public.schedules add column if not exists caption text;
