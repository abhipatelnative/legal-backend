-- Cash & Bank Module - Advanced Ledger Filters
-- Migration: 20260416000006
-- Purpose: Update get_account_ledger to support filtering by direction, payment mode, and transaction type while maintaining accurate running balances.

-- Drop existing to change signature
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP, TIMESTAMP) CASCADE;

-- Recreate with filter support
CREATE OR REPLACE FUNCTION public.get_account_ledger(
  p_account_id UUID,
  p_start_date TIMESTAMP,
  p_end_date TIMESTAMP,
  p_direction VARCHAR(20) DEFAULT NULL,
  p_payment_mode VARCHAR(50) DEFAULT NULL,
  p_transaction_type VARCHAR(50) DEFAULT NULL
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
  WITH all_transactions AS (
    -- 1. Virtual Opening Balance Row (Brought Forward)
    SELECT
      v_start_date AS txn_date,
      'Opening Balance (Brought Forward)'::TEXT AS description,
      NULL::VARCHAR(50) AS payment_mode,
      0::DECIMAL(15,2) AS received_amount,
      0::DECIMAL(15,2) AS given_amount,
      '00000000-0000-0000-0000-000000000000'::UUID AS txn_id,
      NULL::VARCHAR(20) AS direction,
      'OPENING'::VARCHAR(50) AS txn_type

    UNION ALL

    -- 2. Actual Transaction Rows
    SELECT
      ptr.transaction_date::DATE AS txn_date,
      CASE
        WHEN ptr.transaction_type = 'OPENING_BALANCE' THEN 'Initial Opening Balance'
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
      ptr.id AS txn_id,
      ptr.direction,
      ptr.transaction_type AS txn_type
    FROM public.payment_transaction_details ptd
    INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
    WHERE ptd.bank_account_id = p_account_id
      AND ptr.status = 'completed'
      AND ptr.transaction_date::DATE BETWEEN v_start_date AND v_end_date
  ),
  computed_ledger AS (
    -- Calculate running balance on the FULL set for the date range
    SELECT
      t.txn_date,
      t.description,
      t.payment_mode,
      t.received_amount,
      t.given_amount,
      (v_opening_balance + SUM(t.received_amount - t.given_amount) OVER (ORDER BY t.txn_date ASC, t.txn_id ASC)) AS balance,
      t.txn_id,
      t.direction,
      t.txn_type
    FROM all_transactions t
  )
  -- Finally, filter the results based on user selection
  SELECT
    c.txn_date,
    c.description,
    c.payment_mode,
    c.received_amount,
    c.given_amount,
    c.balance AS running_balance
  FROM computed_ledger c
  WHERE 
    c.txn_id = '00000000-0000-0000-0000-000000000000' -- Always keep opening balance row
    OR (
      (p_direction IS NULL OR c.direction = p_direction)
      AND (p_payment_mode IS NULL OR c.payment_mode = p_payment_mode)
      AND (p_transaction_type IS NULL OR c.txn_type = p_transaction_type)
    )
  ORDER BY c.txn_date ASC, c.txn_id ASC;
END;
$$;

COMMENT ON FUNCTION public.get_account_ledger IS 'Get account transactions with filters. Correctly maintains the actual account-level running balance even when rows are filtered.';
