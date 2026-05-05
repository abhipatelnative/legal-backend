-- ============================================================================
-- Add max_present_days policy columns to leave_types table
-- ============================================================================
-- When max_present_days_enabled is true, payroll deducts either a full or
-- half day of salary if the employee's actual present days in the period are
-- <= max_present_days_count.
-- ============================================================================

ALTER TABLE public.leave_types
  ADD COLUMN IF NOT EXISTS max_present_days_enabled BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS max_present_days_count INTEGER NULL,
  ADD COLUMN IF NOT EXISTS max_present_days_deduction_type TEXT DEFAULT 'full';

ALTER TABLE public.leave_types
  DROP CONSTRAINT IF EXISTS leave_types_max_present_days_deduction_type_check;
ALTER TABLE public.leave_types
  ADD CONSTRAINT leave_types_max_present_days_deduction_type_check
  CHECK (max_present_days_deduction_type IN ('full', 'half'));

ALTER TABLE public.leave_types
  DROP CONSTRAINT IF EXISTS leave_types_max_present_days_count_positive;
ALTER TABLE public.leave_types
  ADD CONSTRAINT leave_types_max_present_days_count_positive
  CHECK (max_present_days_count IS NULL OR max_present_days_count >= 0);

CREATE INDEX IF NOT EXISTS idx_leave_types_max_present_days_enabled
  ON public.leave_types(max_present_days_enabled)
  WHERE max_present_days_enabled = true;

COMMENT ON COLUMN public.leave_types.max_present_days_enabled IS 'When true, payroll deducts if employee present days <= max_present_days_count';
COMMENT ON COLUMN public.leave_types.max_present_days_count IS 'Threshold of present days; <= this triggers the deduction';
COMMENT ON COLUMN public.leave_types.max_present_days_deduction_type IS 'full = 1 day salary, half = 0.5 day salary';
