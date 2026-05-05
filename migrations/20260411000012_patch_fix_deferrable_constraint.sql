-- Cash & Bank Module - Patch: Fix Deferrable Constraint
-- Migration: 20260411000012
-- Purpose: Remove DEFERRABLE INITIALLY DEFERRED from bank_accounts unique constraint
--          to fix ON CONFLICT / WHERE NOT EXISTS compatibility issues

-- Drop the deferrable constraint
ALTER TABLE public.bank_accounts 
DROP CONSTRAINT IF EXISTS bank_accounts_account_number_unique;

-- Add standard unique constraint (non-deferrable)
ALTER TABLE public.bank_accounts 
ADD CONSTRAINT bank_accounts_account_number_unique UNIQUE (account_number);

-- Verify the fix
SELECT conname, contype, condeferrable, condeferred 
FROM pg_constraint 
WHERE conname = 'bank_accounts_account_number_unique';
-- Expected: condeferrable = false, condeferred = false
