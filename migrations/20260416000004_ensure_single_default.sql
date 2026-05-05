-- Cash & Bank Module - Single Default Account Enforcement
-- Migration: 20260416000004
-- Purpose: Ensure strictly only one account is marked as default at any time

CREATE OR REPLACE FUNCTION public.fn_ensure_single_default_account()
RETURNS TRIGGER AS $$
BEGIN
  -- Only trigger if is_default is being set to true
  IF NEW.is_default = true AND (OLD.is_default = false OR OLD.is_default IS NULL) THEN
    -- Unset is_default for all other active accounts
    UPDATE public.bank_accounts
    SET is_default = false
    WHERE id != NEW.id 
      AND is_default = true 
      AND deleted_at IS NULL;
  END IF;
  
  -- Prevent unsetting the ONLY default account? 
  -- Actually, the user should be able to have NO default if they want, 
  -- but the requirement was "Only one", so we allow setting but handle resetting others.
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for single default enforcement
DROP TRIGGER IF EXISTS trigger_single_default_account ON public.bank_accounts;
CREATE TRIGGER trigger_single_default_account
BEFORE UPDATE ON public.bank_accounts
FOR EACH ROW
EXECUTE FUNCTION public.fn_ensure_single_default_account();

COMMENT ON FUNCTION public.fn_ensure_single_default_account() IS 'Automatically unsets previous default accounts when a new one is designated.';
