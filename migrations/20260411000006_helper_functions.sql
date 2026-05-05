-- Cash & Bank Module - Helper Functions
-- Migration: 20260411000006
-- Purpose: Create helper functions for balance calculation and ledger retrieval

-- Drop all existing versions to avoid signature conflicts
DROP FUNCTION IF EXISTS public.calculate_account_balance(UUID, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.calculate_account_balance(UUID, TIMESTAMP) CASCADE;
DROP FUNCTION IF EXISTS public.calculate_account_balance(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP, TIMESTAMP) CASCADE;

-- ============================================
-- Function: Calculate Account Balance
-- ============================================
-- Calculates the balance of an account as of a specific date
-- Formula: opening_balance + total_received - total_given
-- Note: Accepts TIMESTAMP and casts to DATE internally to avoid type mismatch errors from Supabase RPC

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
-- Function: Get Account Ledger with Running Balance
-- ============================================
-- Returns transaction history for an account with running balance column
-- Note: Accepts TIMESTAMP and casts to DATE internally to avoid type mismatch errors from Supabase RPC

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
      ptr.transaction_date::DATE AS txn_date,
      CASE
        WHEN ptr.transaction_type = 'OPENING_BALANCE' THEN 'Opening Balance'
        WHEN ptr.transaction_type = 'TRANSFER' AND ptr.direction = 'RECEIVED' THEN 'Transfer In'
        WHEN ptr.transaction_type = 'TRANSFER' AND ptr.direction = 'GIVEN' THEN 'Transfer Out'
        WHEN ptr.transaction_type = 'BALANCE_ADJUSTMENT' AND ptr.direction = 'RECEIVED' THEN 'Balance Adjustment (Add)'
        WHEN ptr.transaction_type = 'BALANCE_ADJUSTMENT' AND ptr.direction = 'GIVEN' THEN 'Balance Adjustment (Reduce)'
        WHEN ptr.transaction_type = 'EXPENSE' AND ptr.direction = 'GIVEN' THEN 'Expense Payment'
        WHEN ptr.transaction_type = 'SERVICE_ORDER' AND ptr.direction = 'RECEIVED' THEN 'Service Order Payment'
        WHEN ptr.transaction_type = 'PAYROLL' AND ptr.direction = 'GIVEN' THEN COALESCE(ptr.remarks, 'Salary Payment')
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
      AND ptr.transaction_date::DATE BETWEEN v_start_date AND v_end_date
    ORDER BY ptr.transaction_date ASC, ptr.id ASC
  )
  SELECT
    t.txn_date,
    t.description,
    t.received_amount,
    t.given_amount,
    (v_opening_balance + SUM(t.received_amount - t.given_amount) OVER (ORDER BY t.txn_date ASC, t.txn_id ASC)) AS running_balance
  FROM transactions t;
END;
$$;

COMMENT ON FUNCTION public.get_account_ledger IS 'Get account transaction history with running balance for a date range. Accepts TIMESTAMP and casts to DATE internally.';

-- ============================================
-- Function: Get All Account Balances As Of Date
-- ============================================
-- Returns all active accounts with their balances as of a specific date

CREATE OR REPLACE FUNCTION public.get_all_account_balances_as_of_date(
  p_as_of_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
RETURNS TABLE (
  account_id UUID,
  account_name VARCHAR,
  account_type VARCHAR,
  is_default BOOLEAN,
  current_balance DECIMAL(15,2)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ba.id AS account_id,
    ba.account_name,
    ba.account_type,
    ba.is_default,
    public.calculate_account_balance(ba.id, p_as_of_date) AS current_balance
  FROM public.bank_accounts ba
  WHERE ba.deleted_at IS NULL
    AND ba.is_active = true
  ORDER BY ba.is_default DESC, ba.account_type ASC, ba.account_name ASC;
END;
$$;

COMMENT ON FUNCTION public.get_all_account_balances_as_of_date IS 'Get all active accounts with their balances as of a specific date. Accepts TIMESTAMP.';

-- ============================================
-- Function: Get All Account Balances (Current Date)
-- ============================================
-- Returns all active accounts with their current balances (legacy function)

CREATE OR REPLACE FUNCTION public.get_all_account_balances()
RETURNS TABLE (
  account_id UUID,
  account_name VARCHAR,
  account_type VARCHAR,
  is_default BOOLEAN,
  current_balance DECIMAL(15,2)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ba.id AS account_id,
    ba.account_name,
    ba.account_type,
    ba.is_default,
    public.calculate_account_balance(ba.id) AS current_balance
  FROM public.bank_accounts ba
  WHERE ba.deleted_at IS NULL
    AND ba.is_active = true
  ORDER BY ba.is_default DESC, ba.account_type ASC, ba.account_name ASC;
END;
$$;

COMMENT ON FUNCTION public.get_all_account_balances IS 'Get all active accounts with their current balances';

-- ============================================
-- Function: Validate Transfer
-- ============================================
-- Validates if a transfer can be executed (sufficient balance check)

CREATE OR REPLACE FUNCTION public.validate_transfer(
  p_from_account_id UUID,
  p_to_account_id UUID,
  p_amount DECIMAL(15,2)
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_from_balance DECIMAL(15,2);
  v_from_account_exists BOOLEAN;
  v_to_account_exists BOOLEAN;
BEGIN
  -- Check if accounts exist
  SELECT EXISTS(SELECT 1 FROM public.bank_accounts WHERE id = p_from_account_id AND deleted_at IS NULL) INTO v_from_account_exists;
  SELECT EXISTS(SELECT 1 FROM public.bank_accounts WHERE id = p_to_account_id AND deleted_at IS NULL) INTO v_to_account_exists;

  IF NOT v_from_account_exists THEN
    RETURN jsonb_build_object('valid', false, 'error', 'Source account not found');
  END IF;

  IF NOT v_to_account_exists THEN
    RETURN jsonb_build_object('valid', false, 'error', 'Destination account not found');
  END IF;

  IF p_from_account_id = p_to_account_id THEN
    RETURN jsonb_build_object('valid', false, 'error', 'Source and destination accounts cannot be the same');
  END IF;

  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('valid', false, 'error', 'Amount must be greater than zero');
  END IF;

  -- Check balance
  SELECT public.calculate_account_balance(p_from_account_id) INTO v_from_balance;

  IF v_from_balance < p_amount THEN
    RETURN jsonb_build_object(
      'valid', false, 
      'error', 'Insufficient balance',
      'current_balance', v_from_balance,
      'required_amount', p_amount
    );
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'current_balance', v_from_balance,
    'balance_after_transfer', v_from_balance - p_amount
  );
END;
$$;

COMMENT ON FUNCTION public.validate_transfer IS 'Validate if a transfer can be executed. Returns JSON with validation result and balance info';
