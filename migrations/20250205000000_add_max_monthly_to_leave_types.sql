-- ============================================================================
-- Add max_monthly column to leave_types table
-- ============================================================================
-- This migration adds a max_monthly column to limit the maximum number of
-- leave days that can be taken per month for a specific leave type.
-- ============================================================================

-- Add max_monthly column to leave_types table
ALTER TABLE public.leave_types
ADD COLUMN IF NOT EXISTS max_monthly INTEGER NULL;

-- Add check constraint to ensure max_monthly is positive if not null
ALTER TABLE public.leave_types
DROP CONSTRAINT IF EXISTS positive_max_monthly;

ALTER TABLE public.leave_types
ADD CONSTRAINT positive_max_monthly CHECK (
  (max_monthly IS NULL) OR (max_monthly > 0)
);

-- Add comment to the column
COMMENT ON COLUMN public.leave_types.max_monthly IS 'Maximum number of leave days allowed per month for this leave type. NULL means no monthly limit.';

