-- Migration: Add Referral Bonus Payroll Integration
-- Description: Adds resignation date tracking and referral bonus payment tracking for payroll integration
-- Date: 2025-12-25

-- ============================================================================
-- 1. Add resignation_date to employees table
-- ============================================================================

-- Add resignation date column
ALTER TABLE public.employees
ADD COLUMN IF NOT EXISTS resignation_date DATE NULL;

-- Add index for better query performance
CREATE INDEX IF NOT EXISTS idx_employees_resignation_date 
ON public.employees USING btree (resignation_date) 
TABLESPACE pg_default;

-- Add comment for documentation
COMMENT ON COLUMN public.employees.resignation_date IS 'Date when employee resigned/left the company';

-- ============================================================================
-- 2. Add payment tracking columns to employee_referrals table
-- ============================================================================

-- Add columns to track monthly bonus payments
ALTER TABLE public.employee_referrals
ADD COLUMN IF NOT EXISTS months_paid INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_paid_month DATE NULL,
ADD COLUMN IF NOT EXISTS next_payment_due DATE NULL;

-- Add index for payment tracking queries
CREATE INDEX IF NOT EXISTS idx_employee_referrals_payment_tracking 
ON public.employee_referrals USING btree (next_payment_due, status) 
TABLESPACE pg_default;

-- Add comments for documentation
COMMENT ON COLUMN public.employee_referrals.months_paid IS 'Number of months bonus has been paid';
COMMENT ON COLUMN public.employee_referrals.last_paid_month IS 'Last month for which bonus was paid (YYYY-MM-01 format)';
COMMENT ON COLUMN public.employee_referrals.next_payment_due IS 'Next month when payment is due (YYYY-MM-01 format)';