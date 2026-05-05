-- Migration: 20260416000010
-- Purpose: Extend payment_transactions_registry transaction_type CHECK constraint
--          to support all modules (Agent Payouts, Advances, Loans, Security Deposits).
--          Also update get_account_ledger() to show meaningful descriptions using remarks.

-- ============================================
-- Step 1: Extend transaction_type CHECK constraint
-- ============================================

ALTER TABLE public.payment_transactions_registry
DROP CONSTRAINT IF EXISTS payment_transactions_registry_transaction_type_check;

ALTER TABLE public.payment_transactions_registry
ADD CONSTRAINT payment_transactions_registry_transaction_type_check
CHECK (transaction_type IN (
  'OPENING_BALANCE',
  'EXPENSE',
  'SERVICE_ORDER',
  'PAYROLL',
  'PURCHASE_ORDER',
  'TRANSFER',
  'BALANCE_ADJUSTMENT',
  'INCOME',
  'AGENT_PAYOUT',
  'ADVANCE_DISBURSEMENT',
  'LOAN_DISBURSEMENT',
  'LOAN_REPAYMENT',
  'SECURITY_DEPOSIT',
  'SECURITY_DEPOSIT_REFUND'
));

-- ============================================
-- Step 2: Extend party_type CHECK constraint
-- ============================================

ALTER TABLE public.payment_transactions_registry
DROP CONSTRAINT IF EXISTS payment_transactions_registry_party_type_check;

ALTER TABLE public.payment_transactions_registry
ADD CONSTRAINT payment_transactions_registry_party_type_check
CHECK (party_type IN ('employee', 'client', 'vendor', 'agent'));

-- ============================================
-- Step 3: Update get_account_ledger() with all descriptions
-- ============================================
-- Every type now uses COALESCE(NULLIF(ptr.remarks, ''), 'Fallback Label')
-- so the remarks field (which contains entity names) shows in the ledger.

DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP, TIMESTAMP) CASCADE;
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP, TIMESTAMP, VARCHAR, VARCHAR, VARCHAR) CASCADE;

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
  cheque_number TEXT,
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
  SELECT public.calculate_account_balance(p_account_id, v_start_date - INTERVAL '1 day') INTO v_opening_balance;

  RETURN QUERY
  WITH all_transactions AS (
    -- 1. Virtual Opening Balance Row
    SELECT
      v_start_date AS txn_date,
      'Opening Balance (Brought Forward)'::TEXT AS description,
      NULL::VARCHAR(50) AS payment_mode,
      NULL::TEXT AS cheque_number,
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
        WHEN ptr.transaction_type = 'EXPENSE' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Expense Payment')
        WHEN ptr.transaction_type = 'SERVICE_ORDER' AND ptr.direction = 'RECEIVED' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Service Order Payment')
        WHEN ptr.transaction_type = 'SERVICE_ORDER' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Service Order Expense')
        WHEN ptr.transaction_type = 'PAYROLL' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Salary Payment')
        WHEN ptr.transaction_type = 'PURCHASE_ORDER' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'PO Payment')
        WHEN ptr.transaction_type = 'INCOME' AND ptr.direction = 'RECEIVED' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Income')
        WHEN ptr.transaction_type = 'AGENT_PAYOUT' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Agent Commission Payout')
        WHEN ptr.transaction_type = 'ADVANCE_DISBURSEMENT' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Advance Disbursement')
        WHEN ptr.transaction_type = 'LOAN_DISBURSEMENT' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Loan Disbursement')
        WHEN ptr.transaction_type = 'LOAN_REPAYMENT' AND ptr.direction = 'RECEIVED' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Loan Repayment')
        WHEN ptr.transaction_type = 'SECURITY_DEPOSIT' AND ptr.direction = 'RECEIVED' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Security Deposit Collection')
        WHEN ptr.transaction_type = 'SECURITY_DEPOSIT_REFUND' AND ptr.direction = 'GIVEN' THEN COALESCE(NULLIF(ptr.remarks, ''), 'Security Deposit Refund')
        ELSE COALESCE(NULLIF(ptr.remarks, ''), ptr.transaction_type || ' - ' || ptr.direction)
      END AS description,
      ptd.payment_mode,
      ptd.cheque_number,
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
    SELECT
      t.txn_date,
      t.description,
      t.payment_mode,
      t.cheque_number,
      t.received_amount,
      t.given_amount,
      (v_opening_balance + SUM(t.received_amount - t.given_amount) OVER (ORDER BY t.txn_date ASC, t.txn_id ASC)) AS balance,
      t.txn_id,
      t.direction,
      t.txn_type
    FROM all_transactions t
  )
  SELECT
    c.txn_date,
    c.description,
    c.payment_mode,
    c.cheque_number,
    c.received_amount,
    c.given_amount,
    c.balance AS running_balance
  FROM computed_ledger c
  WHERE
    c.txn_id = '00000000-0000-0000-0000-000000000000'
    OR (
      (p_direction IS NULL OR c.direction = p_direction)
      AND (p_payment_mode IS NULL OR c.payment_mode = p_payment_mode)
      AND (p_transaction_type IS NULL OR c.txn_type = p_transaction_type)
    )
  ORDER BY c.txn_date DESC, c.txn_id DESC;
END;
$$;

COMMENT ON FUNCTION public.get_account_ledger IS 'Get account transactions with filters and meaningful descriptions from remarks. Supports all transaction types including agent payouts, advances, loans, and security deposits.';
