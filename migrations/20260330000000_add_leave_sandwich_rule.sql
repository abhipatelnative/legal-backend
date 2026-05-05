-- Migration: Add sandwich rule support for leave calculation
-- This is separate from the existing 'apply_sandwich_rule' payroll penalty column.
-- is_sandwich_leave stores the rule state AT THE TIME of leave application
-- for historical consistency.

-- Persist rule-state per leave record (DEFAULT true = existing leaves counted all days, matching old behavior)
ALTER TABLE public.leave_requests
  ADD COLUMN IF NOT EXISTS is_sandwich_leave BOOLEAN DEFAULT true;

-- Comment to clarify usage
COMMENT ON COLUMN public.leave_requests.is_sandwich_leave IS
  'Stores the company sandwich rule state at the time of leave application. TRUE = all days counted (week-offs/holidays included). FALSE = only working days counted. Defaults to TRUE for historical records.';
