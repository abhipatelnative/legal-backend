-- Expense Module - Atomic Approval With Payment
-- Migration: 20260430000002
-- Purpose: New flow couples approval with payment. An expense can only be approved
--          if a payment for the full amount is recorded simultaneously. This RPC
--          enforces that contract atomically — money cut, ledger entries created,
--          expense flipped to paid + approved_by/approved_at stamped, all-or-nothing.

CREATE OR REPLACE FUNCTION public.approve_expense_with_payment(
  p_expense_id        UUID,
  p_bank_account_id   UUID,
  p_payment_method    VARCHAR,
  p_payment_date      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  p_reference_number  VARCHAR DEFAULT NULL,
  p_notes             TEXT DEFAULT NULL,
  p_metadata          JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id      UUID := auth.uid();
  v_status       VARCHAR(50);
  v_total        DECIMAL(15,2);
  v_payment      JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Authentication required');
  END IF;

  -- Lock the expense row to prevent concurrent approvals
  SELECT status, total_amount
    INTO v_status, v_total
  FROM public.expenses
  WHERE id = p_expense_id
  FOR UPDATE;

  IF v_total IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Expense not found');
  END IF;

  IF v_status <> 'submitted' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Only submitted expenses can be approved. Current status: ' || v_status
    );
  END IF;

  -- Delegate to record_payment_v2: cuts money from chosen account, creates
  -- ledger entries, inserts into expense_payments, and updates the expense
  -- status to 'paid' (since this payment covers the full total).
  SELECT public.record_payment_v2(
    p_source_type      := 'EXPENSE',
    p_source_id        := p_expense_id,
    p_amount           := v_total,
    p_payment_method   := p_payment_method,
    p_bank_account_id  := p_bank_account_id,
    p_reference_number := p_reference_number,
    p_notes            := p_notes,
    p_metadata         := p_metadata,
    p_created_by       := v_user_id,
    p_payment_date     := p_payment_date
  ) INTO v_payment;

  -- Bubble up failure (e.g., insufficient balance) without touching the expense
  IF NOT COALESCE((v_payment->>'success')::BOOLEAN, false) THEN
    RETURN v_payment;
  END IF;

  -- Stamp approval metadata. record_payment_v2 already set status='paid'
  -- and updated total_paid_amount/remaining_amount.
  UPDATE public.expenses
     SET approved_by = v_user_id,
         approved_at = p_payment_date,
         updated_at  = NOW()
   WHERE id = p_expense_id;

  RETURN v_payment || jsonb_build_object('approved_at', p_payment_date, 'approved_by', v_user_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION public.approve_expense_with_payment IS
  'Atomically approves a submitted expense by recording a full payment. '
  'Money is deducted from the chosen bank account, ledger entries are created, '
  'and the expense moves submitted -> paid in one transaction.';
