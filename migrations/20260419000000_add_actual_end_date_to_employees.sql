-- Migration: Add Actual End Date to Employees
-- Description: Adds actual end date tracking to employee records and indexes the new column.
-- Date: 2026-04-19

ALTER TABLE public.employees
ADD COLUMN IF NOT EXISTS actual_end_date DATE NULL;

CREATE INDEX IF NOT EXISTS idx_employees_actual_end_date
ON public.employees USING btree (actual_end_date)
TABLESPACE pg_default;

COMMENT ON COLUMN public.employees.actual_end_date IS 'Actual employment end date used for deactivation and payroll closing';
