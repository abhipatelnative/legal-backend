-- Cash & Bank Integration - Payroll Bank Account Tracking
-- Migration: 20260411000011
-- Purpose: Add bank_account_id to payroll table to track which account was used for salary disbursement

-- Add bank_account_id to payroll table
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payroll'
      AND column_name = 'bank_account_id'
  ) THEN
    ALTER TABLE public.payroll
    ADD COLUMN bank_account_id UUID REFERENCES public.bank_accounts(id);

    CREATE INDEX IF NOT EXISTS idx_payroll_bank_account ON public.payroll(bank_account_id);

    RAISE NOTICE 'Added bank_account_id to payroll table';
  ELSE
    RAISE NOTICE 'bank_account_id already exists in payroll table';
  END IF;
END $$;

-- Add comment to the column
COMMENT ON COLUMN public.payroll.bank_account_id IS 'Bank or cash account from which salary was disbursed';

-- ============================================
-- Verification Query
-- ============================================
-- SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'payroll' AND column_name = 'bank_account_id';
