-- ============================================================================
-- Migration: 20260430000002 - Sync service_order_payments.paid_amount
-- Purpose: Single source of truth for per-item paid_amount on
--          service_order_payments. Previously the frontend updated it on
--          create but not on cancel/edit, leaving stale paid_amount when a
--          payment was cancelled or replaced via edit.
--
-- Approach: Persist the link between a payment transaction and the service
--           item it was paid against, by adding a service_order_payment_id
--           column to payment_transactions_service_orders. A trigger on
--           that table then keeps service_order_payments.paid_amount and
--           is_paid in sync on link, cancel and replay (edit = cancel+new).
--
--           This avoids touching record_payment_v2 / cancel_payment_v2,
--           which both already write to / update payment_transactions_service_orders.
-- ============================================================================

-- 1. Add the link column (nullable, no default — set by frontend after recording).
ALTER TABLE public.payment_transactions_service_orders
  ADD COLUMN IF NOT EXISTS service_order_payment_id UUID
  REFERENCES public.service_order_payments(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ptso_service_order_payment_id
  ON public.payment_transactions_service_orders(service_order_payment_id)
  WHERE service_order_payment_id IS NOT NULL;

COMMENT ON COLUMN public.payment_transactions_service_orders.service_order_payment_id IS
  'Optional link to the specific service_order_payments item this transaction paid against. '
  'When set, sync_service_order_payment_paid trigger keeps the per-item paid_amount in sync.';


-- 2. Backfill the link for existing rows by matching the stored item name
--    (income_expense_name for incoming, expense_name for outgoing) against
--    service_order_payments.name within the same service_order. Runs BEFORE
--    the trigger is created so it does not double-count paid_amount.
UPDATE public.payment_transactions_service_orders ptso
SET service_order_payment_id = sop.id
FROM public.service_order_payments sop
WHERE ptso.service_order_payment_id IS NULL
  AND sop.service_order_id = ptso.service_order_id
  AND sop.name = COALESCE(NULLIF(ptso.income_expense_name, ''), NULLIF(ptso.expense_name, ''));


-- 3. Trigger function: applies a +/- delta to the linked item's paid_amount.
CREATE OR REPLACE FUNCTION public.sync_service_order_payment_paid()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_sop_id     UUID;
  v_delta      DECIMAL(15,2);
  v_sop_amount DECIMAL(15,2);
  v_sop_paid   DECIMAL(15,2);
BEGIN
  -- INSERT path: link was set up-front (rare today, but supported).
  IF TG_OP = 'INSERT' THEN
    IF NEW.service_order_payment_id IS NULL OR NEW.status = 'cancelled' THEN
      RETURN NEW;
    END IF;
    v_sop_id := NEW.service_order_payment_id;
    v_delta  := NEW.amount;

  -- UPDATE path:
  --   (a) link transitions from NULL to a value → +amount  (frontend follow-up wire-up)
  --   (b) status transitions completed→cancelled → -amount (delete / edit-cancel)
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.service_order_payment_id IS NULL
       AND NEW.service_order_payment_id IS NOT NULL
       AND NEW.status <> 'cancelled' THEN
      v_sop_id := NEW.service_order_payment_id;
      v_delta  := NEW.amount;
    ELSIF OLD.status <> 'cancelled'
          AND NEW.status = 'cancelled'
          AND NEW.service_order_payment_id IS NOT NULL THEN
      v_sop_id := NEW.service_order_payment_id;
      v_delta  := -NEW.amount;
    ELSE
      RETURN NEW;
    END IF;

  ELSE
    RETURN NEW;
  END IF;

  -- Apply, clamped to [0, item.amount].
  SELECT amount, COALESCE(paid_amount, 0)
    INTO v_sop_amount, v_sop_paid
    FROM public.service_order_payments WHERE id = v_sop_id;

  IF v_sop_amount IS NULL THEN
    RETURN NEW;  -- linked item gone; ignore
  END IF;

  v_sop_paid := GREATEST(0, LEAST(v_sop_paid + v_delta, v_sop_amount));

  UPDATE public.service_order_payments SET
    paid_amount = v_sop_paid,
    is_paid     = (v_sop_amount > 0 AND v_sop_paid >= v_sop_amount),
    updated_at  = NOW()
  WHERE id = v_sop_id;

  RETURN NEW;
END;
$$;


-- 4. Drop old trigger from earlier failed attempt, install the corrected one.
DROP TRIGGER IF EXISTS trigger_sync_service_order_payment_paid
  ON public.payment_transactions_registry;

DROP TRIGGER IF EXISTS trigger_sync_service_order_payment_paid
  ON public.payment_transactions_service_orders;

CREATE TRIGGER trigger_sync_service_order_payment_paid
AFTER INSERT OR UPDATE OF status, service_order_payment_id
  ON public.payment_transactions_service_orders
FOR EACH ROW
EXECUTE FUNCTION public.sync_service_order_payment_paid();

COMMENT ON FUNCTION public.sync_service_order_payment_paid IS
  'Keeps service_order_payments.paid_amount and is_paid in sync. Fires on '
  'payment_transactions_service_orders changes: increments when a service item '
  'link is established (NULL -> value), decrements when status flips to cancelled.';
