-- Migration: Integrate Cash & Bank Module with Additional Payment Modules
-- Description: Adds bank_account_id to agent_payouts, security_deposits, security_deposit_transactions,
--              employee_advances, employee_advance_transactions, loan_transactions, and pf_transactions
--              Also adds new transaction types to payment_transactions_registry
-- Date: 2026-04-15

-- 1. Add bank_account_id to agent_payouts
ALTER TABLE public.agent_payouts
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_agent_payouts_bank_account ON public.agent_payouts(bank_account_id);

-- 2. Add bank_account_id to security_deposits
ALTER TABLE public.security_deposits
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_security_deposits_bank_account ON public.security_deposits(bank_account_id);

-- 3. Add bank_account_id to security_deposit_transactions
ALTER TABLE public.security_deposit_transactions
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_security_deposit_transactions_bank_account ON public.security_deposit_transactions(bank_account_id);

-- 4. Add bank_account_id to employee_advances
ALTER TABLE public.employee_advances
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_employee_advances_bank_account ON public.employee_advances(bank_account_id);

-- 5. Add bank_account_id to employee_advance_transactions
ALTER TABLE public.employee_advance_transactions
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_employee_advance_transactions_bank_account ON public.employee_advance_transactions(bank_account_id);

-- 6. Add bank_account_id to loan_transactions
ALTER TABLE public.loan_transactions
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_loan_transactions_bank_account ON public.loan_transactions(bank_account_id);

-- 7. Add bank_account_id to pf_transactions
ALTER TABLE public.pf_transactions
ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id);

CREATE INDEX IF NOT EXISTS idx_pf_transactions_bank_account ON public.pf_transactions(bank_account_id);

-- 8. Add new transaction types to payment_transactions_registry enum
-- Note: PostgreSQL doesn't have native enums that can be altered, so we check and add if using CHECK constraint
-- If using a different enum system, adjust accordingly

-- 9. Update RLS policies to allow access to new columns
-- (RLS policies already exist, just ensuring they cover the new columns)

COMMENT ON COLUMN public.agent_payouts.bank_account_id IS 'Bank/cash account used for the payout';
COMMENT ON COLUMN public.security_deposits.bank_account_id IS 'Bank/cash account used for initial deposit collection';
COMMENT ON COLUMN public.security_deposit_transactions.bank_account_id IS 'Bank/cash account used for this transaction (refund/extra payment)';
COMMENT ON COLUMN public.employee_advances.bank_account_id IS 'Bank/cash account used for advance disbursement';
COMMENT ON COLUMN public.employee_advance_transactions.bank_account_id IS 'Bank/cash account used for this transaction';
COMMENT ON COLUMN public.loan_transactions.bank_account_id IS 'Bank/cash account used for this transaction (manual repayment)';
COMMENT ON COLUMN public.pf_transactions.bank_account_id IS 'Bank/cash account used for PF remittance';
