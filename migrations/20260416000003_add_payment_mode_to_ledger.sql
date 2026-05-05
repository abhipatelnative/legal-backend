-- Cash & Bank Module - Add Payment Mode to Ledger
-- Migration: 20260416000003
-- Purpose: Update get_account_ledger RPC to include payment_mode for display

-- First drop existing to change signature
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP, TIMESTAMP) CASCADE;

-- Recreate with new column in return table
CREATE OR REPLACE FUNCTION public.get_account_ledger(
  p_account_id UUID,
  p_start_date TIMESTAMP,
  p_end_date TIMESTAMP
)
RETURNS TABLE (
  transaction_date DATE,
  description TEXT,
  payment_mode VARCHAR(50),
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
      ptr.transaction_date::DATE AS txn_date,
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
        WHEN ptr.transaction_type = 'INCOME' AND ptr.direction = 'RECEIVED' THEN 'Income'
        ELSE ptr.transaction_type || ' - ' || ptr.direction
      END AS description,
      ptd.payment_mode,
      CASE WHEN ptr.direction = 'RECEIVED' THEN ptd.amount ELSE 0 END AS received_amount,
      CASE WHEN ptr.direction = 'GIVEN' THEN ptd.amount ELSE 0 END AS given_amount,
      ptr.id AS txn_id
    FROM public.payment_transaction_details ptd
    INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
    WHERE ptd.bank_account_id = p_account_id
      AND ptr.status = 'completed'
      AND ptr.transaction_date::DATE BETWEEN v_start_date AND v_end_date
    ORDER BY ptr.transaction_date ASC, ptr.id ASC
  )
  SELECT
    t.txn_date,
    t.description,
    t.payment_mode,
    t.received_amount,
    t.given_amount,
    (v_opening_balance + SUM(t.received_amount - t.given_amount) OVER (ORDER BY t.txn_date ASC, t.txn_id ASC)) AS running_balance
  FROM transactions t;
END;
$$;

COMMENT ON FUNCTION public.get_account_ledger IS 'Get account transaction history with running balance and payment mode for a date range.';
