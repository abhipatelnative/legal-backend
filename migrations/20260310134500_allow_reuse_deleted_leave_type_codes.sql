-- Allow reusing leave type codes when old rows are soft-deleted.
-- Current unique constraint blocks duplicates even when is_deleted = true.
-- Replace it with partial uniqueness for active (non-deleted) rows only.

DO $$
BEGIN
  -- Drop legacy table-level unique constraint.
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'leave_types_code_key'
      AND conrelid = 'public.leave_types'::regclass
  ) THEN
    ALTER TABLE public.leave_types
      DROP CONSTRAINT leave_types_code_key;
  END IF;
END $$;

-- Enforce uniqueness only for rows that are not soft-deleted.
CREATE UNIQUE INDEX IF NOT EXISTS ux_leave_types_code_not_deleted
ON public.leave_types (code)
WHERE is_deleted = false;

COMMENT ON INDEX public.ux_leave_types_code_not_deleted IS
'Ensures leave type codes are unique only among non-deleted records.';

