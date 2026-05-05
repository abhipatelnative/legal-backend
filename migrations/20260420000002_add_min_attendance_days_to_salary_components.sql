-- Add min_attendance_days to salary_components for variable-component attendance gating
ALTER TABLE public.salary_components
  ADD COLUMN IF NOT EXISTS min_attendance_days INTEGER DEFAULT NULL;

COMMENT ON COLUMN public.salary_components.min_attendance_days IS
  'For variable earning components: employee must have at least this many present days in the payroll period for the component to be paid. NULL or 0 = no attendance gate.';
