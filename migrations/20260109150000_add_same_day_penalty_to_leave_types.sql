-- Add same-day leave penalty columns to leave_types table
-- This allows configuring penalties for employees who apply for leave on the same day

-- Add columns to leave_types table
ALTER TABLE public.leave_types
ADD COLUMN IF NOT EXISTS same_day_penalty_enabled BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS same_day_penalty_amount NUMERIC(10,2) DEFAULT 0;

-- Add comment for documentation
COMMENT ON COLUMN public.leave_types.same_day_penalty_enabled IS 'Flag to enable/disable penalty for same-day leave applications';
COMMENT ON COLUMN public.leave_types.same_day_penalty_amount IS 'Fixed penalty amount to be deducted when leave is applied on the same day';

-- Create salary component for same-day penalty deductions
INSERT INTO public.salary_components (
  name,
  code,
  component_type,
  calculation_type,
  is_variable,
  description,
  is_active,
  is_deleted
)
VALUES (
  'Same Day Leave Penalty',
  'SAME_DAY_PENALTY',
  'deduction',
  'fixed',
  false,
  'Penalty deducted for applying leave on the same day',
  true,
  false
)
ON CONFLICT (code) DO NOTHING;

-- Create index for better query performance
CREATE INDEX IF NOT EXISTS idx_leave_types_penalty_enabled 
ON public.leave_types(same_day_penalty_enabled) 
WHERE same_day_penalty_enabled = true;
