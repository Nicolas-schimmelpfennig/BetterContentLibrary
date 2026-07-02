-- The video's original creation/recording date (from file metadata), distinct
-- from created_at (when the row was inserted). Nullable and user-editable.
ALTER TABLE public.clips ADD COLUMN captured_at timestamptz;
