-- Migration to remove unique constraints on template_name
-- This makes the system more flexible by relying on application-level checks 
-- and allows names of soft-deleted templates to be reused easily.

DO $$ 
BEGIN
    -- 1. Drop the existing unique constraint if it exists
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'document_templates_unique_name') THEN
        ALTER TABLE public.document_templates DROP CONSTRAINT document_templates_unique_name;
    END IF;

    -- 2. Drop the existing unique index if it exists (standard key name)
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = 'document_templates_template_name_key' AND n.nspname = 'public') THEN
        DROP INDEX IF EXISTS public.document_templates_template_name_key;
    END IF;

    -- 3. Drop our previously attempted partial index if it was already run
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = 'document_templates_unique_name' AND n.nspname = 'public') THEN
        DROP INDEX IF EXISTS public.document_templates_unique_name;
    END IF;
END $$;

COMMENT ON COLUMN public.document_templates.template_name IS 'Name of the template. Unique constraint removed to support flexible soft-deletion workflows; uniqueness is now managed at the application level.';
