-- Frame.io-style folder structure for the library, org-scoped + nestable.
CREATE TABLE public.folders (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    parent_id uuid REFERENCES public.folders(id) ON DELETE CASCADE,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX folders_org_parent_idx ON public.folders (org_id, parent_id);

ALTER TABLE public.folders ENABLE ROW LEVEL SECURITY;

CREATE POLICY folders_all ON public.folders
    FOR ALL TO authenticated
    USING (org_id = public.current_org_id())
    WITH CHECK (org_id = public.current_org_id());

-- Clips can live in a folder (null = library root). Deleting a folder leaves the
-- clips in place at root rather than destroying them.
ALTER TABLE public.clips
    ADD COLUMN folder_id uuid REFERENCES public.folders(id) ON DELETE SET NULL,
    ADD COLUMN thumb_key text;

CREATE INDEX clips_folder_idx ON public.clips (folder_id);

-- Keep updated_at fresh on folder edits, reusing the existing helper if present.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'set_updated_at'
    ) THEN
        CREATE TRIGGER folders_set_updated_at
            BEFORE UPDATE ON public.folders
            FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
    END IF;
END $$;
