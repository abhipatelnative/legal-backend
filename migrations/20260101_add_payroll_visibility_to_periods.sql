-- Migration: Add visibility control to payroll periods
-- Created: 2026-01-01
-- Purpose: Allow HR/Admin to control which payroll periods are visible to employees

-- Add visible_to_employees column to payroll_periods table
ALTER TABLE public.payroll_periods 
ADD COLUMN visible_to_employees BOOLEAN NOT NULL DEFAULT false;

-- Add comment explaining the column
COMMENT ON COLUMN public.payroll_periods.visible_to_employees IS 'Controls whether employees can view payroll data for this specific period. Default is false (hidden). HR/Admin can toggle this per period.';

-- Update all existing periods to be hidden by default (for safety)
UPDATE public.payroll_periods 
SET visible_to_employees = false 
WHERE visible_to_employees IS NULL;

-- Create index for better query performance
CREATE INDEX idx_payroll_periods_visibility ON public.payroll_periods(visible_to_employees) WHERE visible_to_employees = true;
