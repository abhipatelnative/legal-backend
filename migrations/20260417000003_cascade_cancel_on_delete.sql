-- ============================================================================
-- Migration: 20260417000003 - Auto-cancel registry entries on source deletion
-- Purpose: When a source record (PO, expense, service order, etc.) is
--          soft-deleted or hard-deleted, automatically cancel all related
--          payment_transactions_registry entries so the bank balance auto-corrects.
-- ============================================================================

-- ============================================================================
-- 1. PURCHASE ORDERS — soft-delete (is_deleted = true)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_po_payments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Only fire when is_deleted changes from false/null to true
  IF NEW.is_deleted = true AND (OLD.is_deleted IS NULL OR OLD.is_deleted = false) THEN
    UPDATE public.payment_transactions_registry SET
      status              = 'cancelled',
      cancelled_at        = NOW(),
      cancelled_by        = NEW.deleted_by,
      cancellation_reason = 'Source purchase order deleted: ' || COALESCE(NEW.po_number, NEW.id::TEXT),
      updated_at          = NOW()
    WHERE source_type = 'purchase_order'
      AND source_id = NEW.id
      AND status = 'completed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_cancel_po_payments ON public.purchase_orders;
CREATE TRIGGER trg_cascade_cancel_po_payments
  AFTER UPDATE OF is_deleted ON public.purchase_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.cascade_cancel_po_payments();

-- ============================================================================
-- 2. SERVICE ORDERS — soft-delete (is_deleted = true)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_so_payments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NEW.is_deleted = true AND (OLD.is_deleted IS NULL OR OLD.is_deleted = false) THEN
    UPDATE public.payment_transactions_registry SET
      status              = 'cancelled',
      cancelled_at        = NOW(),
      cancelled_by        = NEW.deleted_by,
      cancellation_reason = 'Source service order deleted: ' || COALESCE(NEW.order_number, NEW.id::TEXT),
      updated_at          = NOW()
    WHERE source_type = 'service_order'
      AND source_id = NEW.id
      AND status = 'completed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_cancel_so_payments ON public.service_orders;
CREATE TRIGGER trg_cascade_cancel_so_payments
  AFTER UPDATE OF is_deleted ON public.service_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.cascade_cancel_so_payments();

-- ============================================================================
-- 3. EXPENSES — already handled in frontend, but add trigger as safety net
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_expense_payments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NEW.is_deleted = true AND (OLD.is_deleted IS NULL OR OLD.is_deleted = false) THEN
    UPDATE public.payment_transactions_registry SET
      status              = 'cancelled',
      cancelled_at        = NOW(),
      cancelled_by        = NEW.deleted_by,
      cancellation_reason = 'Source expense deleted: ' || COALESCE(NEW.expense_number, NEW.id::TEXT),
      updated_at          = NOW()
    WHERE source_type = 'expense'
      AND source_id = NEW.id
      AND status = 'completed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_cancel_expense_payments ON public.expenses;
CREATE TRIGGER trg_cascade_cancel_expense_payments
  AFTER UPDATE OF is_deleted ON public.expenses
  FOR EACH ROW
  EXECUTE FUNCTION public.cascade_cancel_expense_payments();

-- ============================================================================
-- 4. AGENT PAYOUTS — hard-delete (DELETE FROM agent_payouts)
--    On hard-delete, cancel matching registry entry by amount + service_order_id
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_agent_payout_payments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- When an agent_payouts row is hard-deleted, cancel the registry entry
  -- Match by source_id (service_order_id) + amount + agent party_id
  UPDATE public.payment_transactions_registry SET
    status              = 'cancelled',
    cancelled_at        = NOW(),
    cancellation_reason = 'Agent payout record deleted',
    updated_at          = NOW()
  WHERE source_type = 'agent_payout'
    AND source_id = OLD.service_order_id
    AND total_amount = OLD.amount
    AND party_id = OLD.agent_id
    AND status = 'completed';
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_cancel_agent_payout_payments ON public.agent_payouts;
CREATE TRIGGER trg_cascade_cancel_agent_payout_payments
  BEFORE DELETE ON public.agent_payouts
  FOR EACH ROW
  EXECUTE FUNCTION public.cascade_cancel_agent_payout_payments();

-- ============================================================================
-- 5. EMPLOYEE ADVANCES — if advance is deleted/cancelled
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_advance_payments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Fire when status changes to 'rejected' or 'cancelled', or if soft-deleted
  IF (NEW.status IN ('rejected', 'cancelled') AND OLD.status NOT IN ('rejected', 'cancelled'))
     OR (NEW.is_deleted = true AND (OLD.is_deleted IS NULL OR OLD.is_deleted = false)) THEN
    UPDATE public.payment_transactions_registry SET
      status              = 'cancelled',
      cancelled_at        = NOW(),
      cancellation_reason = 'Employee advance ' || NEW.status || ': ' || NEW.id::TEXT,
      updated_at          = NOW()
    WHERE source_type = 'advance_disbursement'
      AND source_id = NEW.id
      AND status = 'completed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_cancel_advance_payments ON public.employee_advances;
CREATE TRIGGER trg_cascade_cancel_advance_payments
  AFTER UPDATE ON public.employee_advances
  FOR EACH ROW
  EXECUTE FUNCTION public.cascade_cancel_advance_payments();

-- ============================================================================
-- COMMENTS
-- ============================================================================
COMMENT ON FUNCTION public.cascade_cancel_po_payments IS
  'Auto-cancel payment registry entries when a purchase order is soft-deleted';
COMMENT ON FUNCTION public.cascade_cancel_so_payments IS
  'Auto-cancel payment registry entries when a service order is soft-deleted';
COMMENT ON FUNCTION public.cascade_cancel_expense_payments IS
  'Auto-cancel payment registry entries when an expense is soft-deleted (safety net)';
COMMENT ON FUNCTION public.cascade_cancel_agent_payout_payments IS
  'Auto-cancel payment registry entries when an agent payout record is hard-deleted';
COMMENT ON FUNCTION public.cascade_cancel_advance_payments IS
  'Auto-cancel payment registry entries when an employee advance is rejected/cancelled';
