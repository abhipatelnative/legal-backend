-- ============================================================================
-- Migration: 20260430000003 - Purchase Order Refund Linkage
-- Purpose: Allow refund transactions (recorded via record_payment_v2 with
--          source_type = 'INCOME') to be associated with a specific Purchase
--          Order, so they can be displayed / edited / deleted on the PO page.
--
-- Approach: Add a nullable purchase_order_id column on
--          payment_transactions_registry. The frontend sets it via a follow-up
--          UPDATE right after record_payment_v2 returns, mirroring the pattern
--          used for service_order_payment_id on payment_transactions_service_orders.
--          No new RPCs.
-- ============================================================================

ALTER TABLE public.payment_transactions_registry
  ADD COLUMN IF NOT EXISTS purchase_order_id UUID
  REFERENCES public.purchase_orders(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ptr_purchase_order_id
  ON public.payment_transactions_registry(purchase_order_id)
  WHERE purchase_order_id IS NOT NULL;

COMMENT ON COLUMN public.payment_transactions_registry.purchase_order_id IS
  'Optional link to the Purchase Order this transaction is associated with. '
  'Used primarily for refund (INCOME) entries that originated from a PO close-out '
  'with overpayment, so they can be shown alongside the PO''s payment history.';
