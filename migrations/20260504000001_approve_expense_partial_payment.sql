-- Migration: 20260504000001
-- Purpose: Allow approve_expense_with_payment to record a PARTIAL payment.
--          Previously the RPC always charged the full v_total, ignoring the
--          amount the user typed in the dialog. This caused a bug where
--          entering ₹10 for a ₹1,100 bill would still pay ₹1,100.
--
--          New signature accepts p_amount (defaults to NULL = pay full) and
--          delegates that amount to record_payment_v2. Status transitions
--          (paid / partially_paid) are handled inside record_payment_v2.

DROP FUNCTION IF EXISTS public.approve_expense_with_payment(UUID, UUID, VARCHAR, TIMESTAMP WITH TIME ZONE, VARCHAR, TEXT, JSONB) CASCADE;

CREATE OR REPLACE FUNCTION public.approve_expense_with_payment(
  p_expense_id        UUID,
  p_bank_account_id   UUID,
  p_payment_method    VARCHAR,
  p_payment_date      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  p_reference_number  VARCHAR DEFAULT NULL,
  p_notes             TEXT DEFAULT NULL,
  p_metadata          JSONB DEFAULT '{}'::JSONB,
  p_amount            DECIMAL(15,2) DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id      UUID := auth.uid();
  v_status       VARCHAR(50);
  v_total        DECIMAL(15,2);
  v_paid         DECIMAL(15,2);
  v_remaining    DECIMAL(15,2);
  v_charge       DECIMAL(15,2);
  v_payment      JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Authentication required');
  END IF;

  -- Lock the expense row to prevent concurrent approvals
  SELECT status, total_amount, COALESCE(total_paid_amount, 0)
    INTO v_status, v_total, v_paid
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

  v_remaining := v_total - v_paid;
  -- Default: pay the full remaining amount (matches the old all-or-nothing flow).
  v_charge := COALESCE(p_amount, v_remaining);

  IF v_charge <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Payment amount must be greater than zero');
  END IF;

  IF v_charge > v_remaining THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Payment exceeds remaining amount of ' || v_remaining::TEXT
    );
  END IF;

  -- Delegate to record_payment_v2: it cuts money, creates ledger + expense_payments,
  -- and updates expense status (paid if fully covered, partially_paid otherwise).
  SELECT public.record_payment_v2(
    p_source_type      := 'EXPENSE',
    p_source_id        := p_expense_id,
    p_amount           := v_charge,
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

  -- Stamp approval metadata. record_payment_v2 already updated paid amount and
  -- status. Even on partial payment the expense is approved here.
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
  'Atomically approves a submitted expense by recording a payment of p_amount '
  '(defaults to the full remaining amount). Money is deducted from the chosen '
  'bank account, ledger entries are created, and the expense moves submitted -> '
  'paid (full) or partially_paid (partial) in one transaction.';
