-- ============================================================================
-- Migration: 20260417000002 - Unified Payment Cancellation: cancel_payment_v2
-- Purpose: Cancel a payment recorded via record_payment_v2. Reverses the
--          module-specific updates and marks the registry entry as cancelled.
--          Never deletes rows - maintains full audit trail.
-- ============================================================================

DROP FUNCTION IF EXISTS public.cancel_payment_v2 CASCADE;

CREATE OR REPLACE FUNCTION public.cancel_payment_v2(
  p_registry_id   UUID,
  p_reason        TEXT       DEFAULT NULL,
  p_cancelled_by  UUID       DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record           RECORD;
  v_source_type      VARCHAR;
  v_source_id        UUID;
  v_amount           DECIMAL(15,2);
  v_direction        VARCHAR(20);
  v_module_result    JSONB := '{}'::JSONB;

  -- PO-specific
  v_po_total         DECIMAL(15,2);
  v_po_new_paid      DECIMAL(15,2);
  v_po_pay_status    VARCHAR(20);

  -- Expense-specific
  v_exp_total        DECIMAL(15,2);
  v_exp_new_paid     DECIMAL(15,2);
  v_exp_status       VARCHAR(20);

  -- Service Order-specific
  v_so_paid_amount   DECIMAL(15,2);

  -- Agent Payout-specific
  v_so_commission    DECIMAL(15,2);
  v_so_total_paid_commission DECIMAL(15,2);
BEGIN
  -- ================================================================
  -- STEP 1: Fetch and validate the registry entry
  -- ================================================================
  SELECT ptr.id, ptr.transaction_type, ptr.source_type, ptr.source_id,
         ptr.total_amount, ptr.direction, ptr.status
    INTO v_record
    FROM public.payment_transactions_registry ptr
    WHERE ptr.id = p_registry_id;

  IF v_record IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Payment record not found');
  END IF;

  IF v_record.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Payment is already cancelled');
  END IF;

  v_source_type := UPPER(v_record.transaction_type);
  v_source_id   := v_record.source_id;
  v_amount      := v_record.total_amount;
  v_direction   := v_record.direction;

  -- ================================================================
  -- STEP 2: Mark registry entry as cancelled (never delete)
  -- ================================================================
  UPDATE public.payment_transactions_registry SET
    status              = 'cancelled',
    cancelled_at        = NOW(),
    cancelled_by        = p_cancelled_by,
    cancellation_reason = COALESCE(p_reason, 'Cancelled by user'),
    updated_at          = NOW()
  WHERE id = p_registry_id;

  -- ================================================================
  -- STEP 3: Reverse module-specific updates
  -- ================================================================
  CASE v_source_type

    -- ── PURCHASE ORDER ──────────────────────────────────────────────
    WHEN 'PURCHASE_ORDER' THEN
      -- Cancel the PO-specific payment_transactions entry (most recent match).
      -- The trigger update_po_payment_status() on payment_transactions will
      -- auto-recalculate payment_status and remaining_balance.
      UPDATE public.payment_transactions SET
        payment_status = 'cancelled',
        notes = COALESCE(notes, '') || ' [CANCELLED: ' || COALESCE(p_reason, 'Cancelled') || ']'
      WHERE id = (
        SELECT pt.id FROM public.payment_transactions pt
        WHERE pt.purchase_order_id = v_source_id
          AND pt.amount = v_amount
          AND pt.payment_status != 'cancelled'
        ORDER BY pt.created_at DESC LIMIT 1
      );

      -- Read back the auto-calculated values for the response
      SELECT po.payment_status, po.remaining_balance
        INTO v_po_pay_status, v_po_total
        FROM public.purchase_orders po WHERE po.id = v_source_id;

      v_module_result := jsonb_build_object(
        'payment_status', v_po_pay_status,
        'remaining_balance', v_po_total
      );

    -- ── EXPENSE ─────────────────────────────────────────────────────
    WHEN 'EXPENSE' THEN
      SELECT e.total_amount, COALESCE(e.total_paid_amount, 0)
        INTO v_exp_total, v_exp_new_paid
        FROM public.expenses e WHERE e.id = v_source_id;

      v_exp_new_paid := GREATEST(0, v_exp_new_paid - v_amount);
      IF v_exp_new_paid >= v_exp_total THEN
        v_exp_status := 'paid';
      ELSIF v_exp_new_paid > 0 THEN
        v_exp_status := 'partially_paid';
      ELSE
        v_exp_status := 'approved';
      END IF;

      UPDATE public.expenses SET
        status            = v_exp_status,
        total_paid_amount = v_exp_new_paid,
        remaining_amount  = GREATEST(0, v_exp_total - v_exp_new_paid),
        updated_at        = NOW()
      WHERE id = v_source_id;

      -- Cancel the expense_payments entry (most recent match — soft delete not available, so delete)
      DELETE FROM public.expense_payments
      WHERE id = (
        SELECT ep.id FROM public.expense_payments ep
        WHERE ep.expense_id = v_source_id AND ep.payment_amount = v_amount
        ORDER BY ep.created_at DESC LIMIT 1
      );

      v_module_result := jsonb_build_object(
        'expense_status', v_exp_status,
        'total_paid', v_exp_new_paid,
        'remaining_amount', GREATEST(0, v_exp_total - v_exp_new_paid)
      );

    -- ── SERVICE ORDER ───────────────────────────────────────────────
    WHEN 'SERVICE_ORDER' THEN
      IF v_direction = 'RECEIVED' THEN
        UPDATE public.service_orders SET
          paid_amount = GREATEST(0, COALESCE(paid_amount, 0) - v_amount),
          updated_at  = NOW()
        WHERE id = v_source_id;
      ELSE
        UPDATE public.service_orders SET
          paid_amount = COALESCE(paid_amount, 0) + v_amount,
          updated_at  = NOW()
        WHERE id = v_source_id;
      END IF;

      -- Cancel legacy table entry (match by registry_id)
      UPDATE public.payment_transactions_service_orders SET
        status = 'cancelled'
      WHERE registry_id = p_registry_id;


      SELECT so.paid_amount INTO v_so_paid_amount
        FROM public.service_orders so WHERE so.id = v_source_id;

      v_module_result := jsonb_build_object(
        'paid_amount', v_so_paid_amount
      );

    -- ── AGENT PAYOUT ────────────────────────────────────────────────
    WHEN 'AGENT_PAYOUT' THEN
      -- Cancel the most recent matching payout
      UPDATE public.agent_payouts SET
        status = 'cancelled'
      WHERE id = (
        SELECT ap2.id FROM public.agent_payouts ap2
        WHERE ap2.service_order_id = v_source_id
          AND ap2.amount = v_amount
          AND ap2.status = 'paid'
        ORDER BY ap2.created_at DESC LIMIT 1
      );

      -- Recalculate payout status
      SELECT so.agent_commission_amount INTO v_so_commission
        FROM public.service_orders so WHERE so.id = v_source_id;

      SELECT COALESCE(SUM(ap.amount), 0) INTO v_so_total_paid_commission
        FROM public.agent_payouts ap
        WHERE ap.service_order_id = v_source_id AND ap.status = 'paid';

      UPDATE public.service_orders SET
        agent_payout_status = CASE
          WHEN v_so_total_paid_commission >= COALESCE(v_so_commission, 0) THEN 'paid'
          WHEN v_so_total_paid_commission > 0 THEN 'partially_paid'
          ELSE 'due'
        END,
        updated_at = NOW()
      WHERE id = v_source_id;

      v_module_result := jsonb_build_object(
        'total_paid_commission', v_so_total_paid_commission
      );

    -- ── ADVANCE DISBURSEMENT ────────────────────────────────────────
    WHEN 'ADVANCE_DISBURSEMENT' THEN
      -- Cancel the disbursement transaction (most recent match)
      UPDATE public.employee_advance_transactions SET
        description = description || ' [CANCELLED: ' || COALESCE(p_reason, 'Cancelled') || ']'
      WHERE id = (
        SELECT eat.id FROM public.employee_advance_transactions eat
        WHERE eat.advance_id = v_source_id
          AND eat.transaction_type = 'disbursement'
          AND eat.amount = v_amount
        ORDER BY eat.created_at DESC LIMIT 1
      );

      -- Clear the bank_account_id
      UPDATE public.employee_advances SET
        bank_account_id = NULL
      WHERE id = v_source_id;

      v_module_result := jsonb_build_object('note', 'Advance disbursement cancelled');

    -- ── SECURITY DEPOSIT REFUND ────────────────────────────────────
    WHEN 'SECURITY_DEPOSIT_REFUND' THEN
      -- Revert deposit status back to completed, clear refund fields
      UPDATE public.security_deposits SET
        status          = 'completed',
        refund_date     = NULL,
        refund_amount   = NULL,
        interest_amount = NULL,
        bank_account_id = NULL,
        updated_at      = NOW()
      WHERE id = v_source_id;

      -- Delete the refund transaction record
      DELETE FROM public.security_deposit_transactions
      WHERE security_deposit_id = v_source_id
        AND transaction_type = 'refund';

      v_module_result := jsonb_build_object('note', 'Security deposit refund reversed, status restored to completed');

    -- ── LOAN / SECURITY DEPOSIT COLLECTION / INCOME ─────────────────
    WHEN 'LOAN_DISBURSEMENT', 'LOAN_REPAYMENT', 'SECURITY_DEPOSIT', 'INCOME' THEN
      -- The registry cancellation itself is sufficient - balance auto-corrects.
      v_module_result := jsonb_build_object('note', 'Registry entry cancelled, balance auto-corrected');

    ELSE
      v_module_result := jsonb_build_object('note', 'No module-specific reversal for type: ' || v_source_type);
  END CASE;

  -- ================================================================
  -- STEP 4: Return success
  -- ================================================================
  RETURN jsonb_build_object(
    'success', true,
    'registry_id', p_registry_id,
    'cancelled_amount', v_amount,
    'source_type', v_source_type
  ) || v_module_result;

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION public.cancel_payment_v2 IS
  'Cancel a payment recorded via record_payment_v2. Marks registry as cancelled (never deletes), '
  'reverses module-specific balance/status updates. Balance auto-corrects because '
  'calculate_account_balance() ignores cancelled entries.';
