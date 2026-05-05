-- Add a flexible document mode for leave types:
-- hidden   -> document field is not shown
-- optional -> document field is shown but optional
-- required -> document field is shown and mandatory

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'leave_types'
      AND column_name = 'document_mode'
  ) THEN
    ALTER TABLE public.leave_types
      ADD COLUMN document_mode text;
  END IF;
END $$;

-- Backfill from legacy behavior:
-- document_required=true previously meant "visible and required".
UPDATE public.leave_types
SET document_mode = CASE
  WHEN COALESCE(document_required, false) THEN 'required'
  ELSE 'hidden'
END
WHERE document_mode IS NULL;

ALTER TABLE public.leave_types
  ALTER COLUMN document_mode SET DEFAULT 'hidden';

ALTER TABLE public.leave_types
  ALTER COLUMN document_mode SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'leave_types_document_mode_check'
  ) THEN
    ALTER TABLE public.leave_types
      ADD CONSTRAINT leave_types_document_mode_check
      CHECK (document_mode IN ('hidden', 'optional', 'required'));
  END IF;
END $$;

COMMENT ON COLUMN public.leave_types.document_mode IS
'Document policy for leave application form: hidden, optional, or required.';

