-- Cash & Bank Module - Edge Case Hardening
-- Migration: 20260416000002
-- Purpose: Add database-level safeguards for dates, default accounts, and cheque requirements

-- 1. Function: Validate Transaction Date vs Opening Date
CREATE OR REPLACE FUNCTION public.fn_validate_transaction_date()
RETURNS TRIGGER AS $$
DECLARE
  v_opening_date DATE;
  v_transaction_date DATE;
BEGIN
  -- Get the transaction date from the registry
  SELECT transaction_date INTO v_transaction_date
  FROM public.payment_transactions_registry
  WHERE id = NEW.payment_id;

  -- Get the opening date of the account
  SELECT opening_date INTO v_opening_date
  FROM public.bank_accounts
  WHERE id = NEW.bank_account_id;

  IF v_transaction_date < v_opening_date THEN
    RAISE EXCEPTION 'Transaction date (%) cannot be earlier than account opening date (%)', 
      v_transaction_date, v_opening_date;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for date validation
DROP TRIGGER IF EXISTS trigger_validate_transaction_date ON public.payment_transaction_details;
CREATE TRIGGER trigger_validate_transaction_date
BEFORE INSERT OR UPDATE ON public.payment_transaction_details
FOR EACH ROW
EXECUTE FUNCTION public.fn_validate_transaction_date();


-- 2. Function: Protect Default Account from Deletion
CREATE OR REPLACE FUNCTION public.fn_protect_default_account()
RETURNS TRIGGER AS $$
BEGIN
  -- If trying to soft-delete (deleted_at is not null) an account that is default
  IF (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) AND OLD.is_default = true THEN
    RAISE EXCEPTION 'Cannot delete the default bank account. Please assign another account as default first.';
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for default account protection
DROP TRIGGER IF EXISTS trigger_protect_default_account ON public.bank_accounts;
CREATE TRIGGER trigger_protect_default_account
BEFORE UPDATE ON public.bank_accounts
FOR EACH ROW
EXECUTE FUNCTION public.fn_protect_default_account();


-- 3. Function: Validate Cheque Details
CREATE OR REPLACE FUNCTION public.fn_validate_cheque_details()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.payment_mode = 'cheque' THEN
    IF NEW.cheque_number IS NULL OR NEW.cheque_number = '' THEN
      RAISE EXCEPTION 'Cheque number is required for cheque payments';
    END IF;
    IF NEW.cheque_date IS NULL THEN
      RAISE EXCEPTION 'Cheque date is required for cheque payments';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for cheque validation
DROP TRIGGER IF EXISTS trigger_validate_cheque_details ON public.payment_transaction_details;
CREATE TRIGGER trigger_validate_cheque_details
BEFORE INSERT OR UPDATE ON public.payment_transaction_details
FOR EACH ROW
EXECUTE FUNCTION public.fn_validate_cheque_details();

COMMENT ON FUNCTION public.fn_validate_transaction_date() IS 'Prevents back-dated transactions before account opening date.';
COMMENT ON FUNCTION public.fn_protect_default_account() IS 'Prevents deletion of the primary default account.';
COMMENT ON FUNCTION public.fn_validate_cheque_details() IS 'Ensures mandatory cheque fields are populated.';
