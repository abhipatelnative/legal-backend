-- Migration: Phase 1 of Option A — JSONB payload column for cms_homepage
--
-- Adds a `payload` JSONB column to public.cms_homepage. The CMS editor will
-- start writing the entire section as a single JSON blob into `payload`.
-- A BEFORE INSERT/UPDATE trigger keeps the existing flat columns in sync by
-- copying matching keys from `payload` into their columns (unknown keys in
-- the JSON are silently ignored by jsonb_populate_record). This lets every
-- existing template renderer keep reading the legacy columns unchanged
-- while new fields (e.g. `slides`) ride along inside `payload` without
-- needing per-field ALTER TABLE migrations.
--
-- Phase 2 (later) will switch renderers to read `payload` directly and
-- finally drop the legacy columns.

BEGIN;

-- 1. Add the payload column + GIN index for future jsonb querying.
ALTER TABLE public.cms_homepage
  ADD COLUMN IF NOT EXISTS payload JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS cms_homepage_payload_gin
  ON public.cms_homepage USING GIN (payload);

-- 2. Backfill payload from the existing flat columns. Strip metadata keys
--    and NULLs so the JSONB only carries actual content.
UPDATE public.cms_homepage AS c
SET payload = jsonb_strip_nulls(
        to_jsonb(c)
        - 'id'
        - 'template_id'
        - 'section_name'
        - 'payload'
        - 'created_at'
        - 'updated_at'
        - 'created_by'
        - 'updated_by'
    )
WHERE payload IS NULL OR payload = '{}'::jsonb;

-- 3. Trigger: when payload changes, copy matching keys back into legacy
--    columns. jsonb_populate_record ignores keys that don't exist as
--    columns, so new fields like `slides` simply stay inside payload
--    without breaking the write.
CREATE OR REPLACE FUNCTION public.cms_homepage_sync_payload()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.payload IS NOT NULL AND NEW.payload <> '{}'::jsonb THEN
        NEW := jsonb_populate_record(NEW, NEW.payload);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS cms_homepage_sync_payload_trg ON public.cms_homepage;

CREATE TRIGGER cms_homepage_sync_payload_trg
BEFORE INSERT OR UPDATE ON public.cms_homepage
FOR EACH ROW
EXECUTE FUNCTION public.cms_homepage_sync_payload();

COMMIT;
