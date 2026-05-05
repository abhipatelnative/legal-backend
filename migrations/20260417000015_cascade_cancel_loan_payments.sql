-- ============================================================================
-- Migration: 20260417000015 - Auto-cancel loan disbursement/payments on deletion
-- Purpose: When a loan is soft-deleted, automatically cancel all related
--          payment_transactions_registry entries so the bank balance auto-corrects.
-- ============================================================================

-- ============================================================================
-- EMPLOYEE LOANS — soft-delete (is_deleted = true)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_loan_payments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Fire when is_deleted changes from false/null to true
  IF NEW.is_deleted = true AND (OLD.is_deleted IS NULL OR OLD.is_deleted = false) THEN
    UPDATE public.payment_transactions_registry SET
      status              = 'cancelled',
      cancelled_at        = NOW(),
      cancelled_by        = NEW.updated_by,
      cancellation_reason = 'Employee loan deleted: ' || NEW.id::TEXT,
      updated_at          = NOW()
    WHERE source_type = 'LOAN_DISBURSEMENT'
      AND source_id = NEW.id
      AND status = 'completed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_cancel_loan_payments ON public.employee_loans;
CREATE TRIGGER trg_cascade_cancel_loan_payments
  AFTER UPDATE OF is_deleted ON public.employee_loans
  FOR EACH ROW
  EXECUTE FUNCTION public.cascade_cancel_loan_payments();

-- ============================================================================
-- COMMENTS
-- ============================================================================
COMMENT ON FUNCTION public.cascade_cancel_loan_payments IS
  'Auto-cancel loan disbursement payment registry entries when a loan is soft-deleted';
