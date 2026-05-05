-- ============================================================================
-- Migration: 20260430000004 - Add registry_id to payment_transactions (POs)
-- Purpose: Link each PO payment row back to its GL registry entry so the
--          frontend can call cancel_payment_v2(p_registry_id) on edit/delete.
--          Mirrors the pattern used for payment_transactions_service_orders.
--
-- Approach:
--   1. ALTER TABLE: add nullable registry_id column.
--   2. Backfill: pair each non-cancelled payment_transactions row with the
--      matching non-cancelled registry entry by (po id, amount, ordered by
--      created_at). Uses a window function so duplicates are handled in order.
--   3. New rows are linked by the frontend right after record_payment_v2
--      returns its registry_id + po_payment_id.
-- ============================================================================

ALTER TABLE public.payment_transactions
  ADD COLUMN IF NOT EXISTS registry_id UUID
  REFERENCES public.payment_transactions_registry(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_payment_transactions_registry_id
  ON public.payment_transactions(registry_id)
  WHERE registry_id IS NOT NULL;

COMMENT ON COLUMN public.payment_transactions.registry_id IS
  'Link back to the GL registry entry in payment_transactions_registry. '
  'Used by the UI to call cancel_payment_v2 on edit/delete.';

-- Backfill: match payment_transactions rows to registry rows by (PO, amount).
-- Pair them in created_at order in case the same amount was paid multiple times.
WITH pt_ranked AS (
  SELECT id, purchase_order_id, amount, created_at,
         ROW_NUMBER() OVER (
           PARTITION BY purchase_order_id, amount
           ORDER BY created_at ASC
         ) AS rn
  FROM public.payment_transactions
  WHERE registry_id IS NULL
    AND COALESCE(payment_status, '') <> 'cancelled'
),
ptr_ranked AS (
  SELECT id AS registry_id, source_id AS purchase_order_id, total_amount AS amount, created_at,
         ROW_NUMBER() OVER (
           PARTITION BY source_id, total_amount
           ORDER BY created_at ASC
         ) AS rn
  FROM public.payment_transactions_registry
  WHERE transaction_type = 'PURCHASE_ORDER'
    AND status <> 'cancelled'
)
UPDATE public.payment_transactions pt
SET registry_id = ptr_ranked.registry_id
FROM pt_ranked, ptr_ranked
WHERE pt.id = pt_ranked.id
  AND pt_ranked.purchase_order_id = ptr_ranked.purchase_order_id
  AND pt_ranked.amount = ptr_ranked.amount
  AND pt_ranked.rn = ptr_ranked.rn;
