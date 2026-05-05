-- Cash & Bank Module - Account Transfers Table
-- Migration: 20260411000003
-- Purpose: Create account_transfers table for inter-account money transfers

-- Create account_transfers table
CREATE TABLE IF NOT EXISTS public.account_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_account_id UUID NOT NULL REFERENCES public.bank_accounts(id),
  to_account_id UUID NOT NULL REFERENCES public.bank_accounts(id),
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  transfer_date DATE NOT NULL DEFAULT CURRENT_DATE,
  remarks TEXT,
  debit_transaction_id UUID REFERENCES public.payment_transactions_registry(id),
  credit_transaction_id UUID REFERENCES public.payment_transactions_registry(id),
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  
  -- Constraints
  CONSTRAINT account_transfers_different_accounts CHECK (from_account_id != to_account_id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_at_from_account ON public.account_transfers(from_account_id);
CREATE INDEX IF NOT EXISTS idx_at_to_account ON public.account_transfers(to_account_id);
CREATE INDEX IF NOT EXISTS idx_at_transfer_date ON public.account_transfers(transfer_date);

-- Add comments
COMMENT ON TABLE public.account_transfers IS 'Record of inter-account money transfers';
COMMENT ON COLUMN public.account_transfers.from_account_id IS 'Source account (money deducted from this account)';
COMMENT ON COLUMN public.account_transfers.to_account_id IS 'Destination account (money added to this account)';
COMMENT ON COLUMN public.account_transfers.debit_transaction_id IS 'Links to the GIVEN transaction in payment_transactions_registry';
COMMENT ON COLUMN public.account_transfers.credit_transaction_id IS 'Links to the RECEIVED transaction in payment_transactions_registry';
