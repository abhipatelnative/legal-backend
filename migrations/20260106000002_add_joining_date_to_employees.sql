-- Migration: Add joining_date column to employees table
-- Description: Adds a new joining_date field for tracking when an employee officially joined the company

-- Add the joining_date column to employees table
ALTER TABLE employees 
ADD COLUMN IF NOT EXISTS joining_date DATE;

-- Add a comment to explain the field
COMMENT ON COLUMN employees.joining_date IS 'The official date when the employee joined the company. Used for referral bonus calculations and anniversary tracking.';

-- Create an index for faster lookups by joining date
CREATE INDEX IF NOT EXISTS idx_employees_joining_date ON employees(joining_date);

-- Backfill joining_date from hire_date for existing records only
UPDATE employees
SET joining_date = hire_date
WHERE joining_date IS NULL;
