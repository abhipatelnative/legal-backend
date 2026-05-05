-- Keep legacy boolean and trigger validation aligned with document_mode.
-- This prevents "Visible (Optional)" from being treated as required.

-- 1) Sync existing leave types so legacy field matches mode.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'leave_types'
      AND column_name = 'document_mode'
  ) THEN
    UPDATE public.leave_types
    SET document_required = CASE
      WHEN document_mode = 'required' THEN TRUE
      ELSE FALSE
    END
    WHERE document_required IS DISTINCT FROM CASE
      WHEN document_mode = 'required' THEN TRUE
      ELSE FALSE
    END;
  END IF;
END $$;

-- 2) Validate documents using document_mode when available; fallback to legacy boolean.
CREATE OR REPLACE FUNCTION public.validate_leave_documents()
RETURNS TRIGGER AS $$
DECLARE
  leave_type_record RECORD;
  document_mode_value TEXT;
  is_document_required BOOLEAN;
BEGIN
  SELECT * INTO leave_type_record
  FROM public.leave_types
  WHERE id = NEW.leave_type_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  document_mode_value := to_jsonb(leave_type_record) ->> 'document_mode';

  is_document_required := CASE
    WHEN document_mode_value = 'required' THEN TRUE
    WHEN document_mode_value IN ('hidden', 'optional') THEN FALSE
    ELSE COALESCE(leave_type_record.document_required, FALSE)
  END;

  IF is_document_required AND (NEW.document_urls IS NULL OR array_length(NEW.document_urls, 1) = 0) THEN
    RAISE EXCEPTION 'Documents are required for this leave type: %',
      COALESCE(leave_type_record.document_description, 'Supporting documents required');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3) Ensure trigger points to latest function.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'leave_requests'
  ) THEN
    DROP TRIGGER IF EXISTS validate_leave_documents_trigger ON public.leave_requests;
    CREATE TRIGGER validate_leave_documents_trigger
      BEFORE INSERT OR UPDATE ON public.leave_requests
      FOR EACH ROW
      EXECUTE FUNCTION public.validate_leave_documents();
  END IF;
END $$;

