-- Migration to add provisioning fields to expenses for automated payout on approval
ALTER TABLE public.expenses 
ADD COLUMN IF NOT EXISTS provisioned_bank_account_id UUID REFERENCES public.bank_accounts(id),
ADD COLUMN IF NOT EXISTS provisioned_payment_method TEXT,
ADD COLUMN IF NOT EXISTS provisioned_notes TEXT,
ADD COLUMN IF NOT EXISTS auto_payout_on_approval BOOLEAN DEFAULT FALSE;

COMMENT ON COLUMN public.expenses.provisioned_bank_account_id IS 'Pre-selected bank account for automated payout upon approval';
COMMENT ON COLUMN public.expenses.provisioned_payment_method IS 'Pre-selected payment method for automated payout upon approval';
COMMENT ON COLUMN public.expenses.auto_payout_on_approval IS 'If true, the system will automatically process the payout when the status changes to approved';
