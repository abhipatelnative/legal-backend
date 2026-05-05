-- Cash & Bank Module - Payment Transaction Details Table
-- Migration: 20260411000002
-- Purpose: Create payment_transaction_details table for payment breakdown by mode and account

-- Create payment_transaction_details table
CREATE TABLE IF NOT EXISTS public.payment_transaction_details (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id UUID NOT NULL REFERENCES public.payment_transactions_registry(id) ON DELETE CASCADE,
  bank_account_id UUID NOT NULL REFERENCES public.bank_accounts(id),
  payment_mode VARCHAR(50) NOT NULL CHECK (payment_mode IN (
    'cash', 'cheque', 'card', 'upi', 'bank_transfer', 'online'
  )),
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  cheque_number VARCHAR(50),
  cheque_date DATE,
  cheque_bank_name VARCHAR(255),
  transaction_reference VARCHAR(100),
  remarks TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_ptd_payment_id ON public.payment_transaction_details(payment_id);
CREATE INDEX IF NOT EXISTS idx_ptd_bank_account_id ON public.payment_transaction_details(bank_account_id);
CREATE INDEX IF NOT EXISTS idx_ptd_payment_mode ON public.payment_transaction_details(payment_mode);

-- Add comments
COMMENT ON TABLE public.payment_transaction_details IS 'Breakdown of payment by mode and account';
COMMENT ON COLUMN public.payment_transaction_details.payment_mode IS 'cash, cheque, card, upi, bank_transfer, online';
COMMENT ON COLUMN public.payment_transaction_details.cheque_number IS 'Populated only for cheque payments';
COMMENT ON COLUMN public.payment_transaction_details.cheque_date IS 'Date on the cheque';
COMMENT ON COLUMN public.payment_transaction_details.cheque_bank_name IS 'Bank name on the cheque';
COMMENT ON COLUMN public.payment_transaction_details.transaction_reference IS 'UPI reference number, bank transaction ID, etc.';
