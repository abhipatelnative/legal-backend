-- Cash & Bank Module - Bank Accounts Table
-- Migration: 20260411000000
-- Purpose: Create bank_accounts table for managing company bank and cash accounts

-- Create bank_accounts table
CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_name VARCHAR(255) NOT NULL,
  account_type VARCHAR(50) NOT NULL CHECK (account_type IN ('savings', 'current', 'overdraft', 'cash', 'petty_cash')),
  bank_name VARCHAR(255),
  branch_name VARCHAR(255),
  account_number VARCHAR(100),
  ifsc_code VARCHAR(20),
  micr_code VARCHAR(20),
  opening_balance DECIMAL(15,2) NOT NULL DEFAULT 0,
  opening_date DATE NOT NULL DEFAULT CURRENT_DATE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_default BOOLEAN NOT NULL DEFAULT false,
  remarks TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  deleted_at TIMESTAMP WITH TIME ZONE,
  
  -- Constraints
  CONSTRAINT bank_accounts_account_number_unique UNIQUE (account_number)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_bank_accounts_type ON public.bank_accounts(account_type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bank_accounts_active ON public.bank_accounts(is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bank_accounts_default ON public.bank_accounts(is_default) WHERE is_default = true AND deleted_at IS NULL;

-- Add comments
COMMENT ON TABLE public.bank_accounts IS 'Master list of all bank and cash accounts';
COMMENT ON COLUMN public.bank_accounts.account_type IS 'savings, current, overdraft, cash, petty_cash';
COMMENT ON COLUMN public.bank_accounts.opening_balance IS 'Initial balance when account was created';
COMMENT ON COLUMN public.bank_accounts.deleted_at IS 'Soft delete timestamp - NULL means active';

-- Create updated_at trigger
CREATE OR REPLACE FUNCTION public.update_bank_accounts_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_bank_accounts_updated_at
BEFORE UPDATE ON public.bank_accounts
FOR EACH ROW
EXECUTE FUNCTION public.update_bank_accounts_updated_at();
