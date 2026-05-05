-- Cash & Bank Module - Fix Date Type Casting Issue
-- Migration: 20260411000012
-- Purpose: Fix functions to accept TIMESTAMP and cast to DATE internally to avoid type mismatch errors

-- ============================================
-- Function: Calculate Account Balance (Fixed)
-- ============================================

CREATE OR REPLACE FUNCTION public.calculate_account_balance(
  p_account_id UUID,
  p_as_of_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
RETURNS DECIMAL(15,2)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_opening_balance DECIMAL(15,2);
  v_total_received DECIMAL(15,2);
  v_total_given DECIMAL(15,2);
  v_balance DECIMAL(15,2);
  v_date DATE := DATE(p_as_of_date);
BEGIN
  -- Get opening balance from bank_accounts
  SELECT opening_balance INTO v_opening_balance
  FROM public.bank_accounts
  WHERE id = p_account_id AND deleted_at IS NULL;

  IF v_opening_balance IS NULL THEN
    RETURN 0;
  END IF;

  -- Calculate total received before/as of date
  SELECT COALESCE(SUM(ptd.amount), 0) INTO v_total_received
  FROM public.payment_transaction_details ptd
  INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
  WHERE ptd.bank_account_id = p_account_id
    AND ptr.direction = 'RECEIVED'
    AND ptr.status = 'completed'
    AND ptr.transaction_date <= v_date;

  -- Calculate total given before/as of date
  SELECT COALESCE(SUM(ptd.amount), 0) INTO v_total_given
  FROM public.payment_transaction_details ptd
  INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
  WHERE ptd.bank_account_id = p_account_id
    AND ptr.direction = 'GIVEN'
    AND ptr.status = 'completed'
    AND ptr.transaction_date <= v_date;

  -- Calculate balance
  v_balance := v_opening_balance + v_total_received - v_total_given;

  RETURN v_balance;
END;
$$;

COMMENT ON FUNCTION public.calculate_account_balance IS 'Calculate account balance as of a specific date. Formula: opening_balance + total_received - total_given. Accepts TIMESTAMP and casts to DATE internally.';

-- ============================================
-- Function: Get Account Ledger with Running Balance (Fixed)
-- ============================================

CREATE OR REPLACE FUNCTION public.get_account_ledger(
  p_account_id UUID,
  p_start_date TIMESTAMP,
  p_end_date TIMESTAMP
)
RETURNS TABLE (
  transaction_date DATE,
  description TEXT,
  received_amount DECIMAL(15,2),
  given_amount DECIMAL(15,2),
  running_balance DECIMAL(15,2)
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_opening_balance DECIMAL(15,2);
  v_start_date DATE := DATE(p_start_date);
  v_end_date DATE := DATE(p_end_date);
BEGIN
  -- Calculate opening balance before start_date
  SELECT public.calculate_account_balance(p_account_id, v_start_date - INTERVAL '1 day') INTO v_opening_balance;

  RETURN QUERY
  WITH transactions AS (
    SELECT
      ptr.transaction_date,
      CASE
        WHEN ptr.transaction_type = 'OPENING_BALANCE' THEN 'Opening Balance'
        WHEN ptr.transaction_type = 'TRANSFER' AND ptr.direction = 'RECEIVED' THEN 'Transfer In'
        WHEN ptr.transaction_type = 'TRANSFER' AND ptr.direction = 'GIVEN' THEN 'Transfer Out'
        WHEN ptr.transaction_type = 'BALANCE_ADJUSTMENT' AND ptr.direction = 'RECEIVED' THEN 'Balance Adjustment (Add)'
        WHEN ptr.transaction_type = 'BALANCE_ADJUSTMENT' AND ptr.direction = 'GIVEN' THEN 'Balance Adjustment (Reduce)'
        WHEN ptr.transaction_type = 'EXPENSE' AND ptr.direction = 'GIVEN' THEN 'Expense Payment'
        WHEN ptr.transaction_type = 'SERVICE_ORDER' AND ptr.direction = 'RECEIVED' THEN 'Service Order Payment'
        WHEN ptr.transaction_type = 'PAYROLL' AND ptr.direction = 'GIVEN' THEN 'Salary Payment'
        WHEN ptr.transaction_type = 'PURCHASE_ORDER' AND ptr.direction = 'GIVEN' THEN 'PO Payment'
        ELSE ptr.transaction_type || ' - ' || ptr.direction
      END AS description,
      CASE WHEN ptr.direction = 'RECEIVED' THEN ptd.amount ELSE 0 END AS received_amount,
      CASE WHEN ptr.direction = 'GIVEN' THEN ptd.amount ELSE 0 END AS given_amount,
      ptr.id AS txn_id
    FROM public.payment_transaction_details ptd
    INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
    WHERE ptd.bank_account_id = p_account_id
      AND ptr.status = 'completed'
      AND ptr.transaction_date BETWEEN v_start_date AND v_end_date
    ORDER BY ptr.transaction_date ASC, ptr.id ASC
  )
  SELECT
    t.transaction_date,
    t.description,
    t.received_amount,
    t.given_amount,
    (v_opening_balance + SUM(t.received_amount - t.given_amount) OVER (ORDER BY t.transaction_date ASC, t.txn_id ASC)) AS running_balance
  FROM transactions t;
END;
$$;

COMMENT ON FUNCTION public.get_account_ledger IS 'Get account transaction history with running balance for a date range. Accepts TIMESTAMP and casts to DATE internally.';
