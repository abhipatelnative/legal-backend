-- Add is_employee_role column to roles table
-- This flag determines if a user with this role should also have an associated employee record.

ALTER TABLE IF EXISTS public.roles 
ADD COLUMN IF NOT EXISTS is_employee_role BOOLEAN DEFAULT false;

-- Force refresh of any views that might be using this table
-- Note: Replace with specific views if any depend on 'roles' structure.
