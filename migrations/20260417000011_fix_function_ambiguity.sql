-- Cash & Bank Module - Fix Function Ambiguity
-- Migration: 20260417000011
-- Purpose: Resolve ambiguity by dropping old versions of functions that use TIMESTAMP (without time zone)
--          since we have migrated to TIMESTAMP WITH TIME ZONE.

-- 1. Drop old versions of calculate_account_balance
DROP FUNCTION IF EXISTS public.calculate_account_balance(UUID, TIMESTAMP WITHOUT TIME ZONE) CASCADE;
DROP FUNCTION IF EXISTS public.calculate_account_balance(UUID, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.calculate_account_balance(UUID) CASCADE;

-- 2. Drop old versions of get_account_ledger
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP WITHOUT TIME ZONE, TIMESTAMP WITHOUT TIME ZONE) CASCADE;
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP WITHOUT TIME ZONE, TIMESTAMP WITHOUT TIME ZONE, VARCHAR, VARCHAR, VARCHAR) CASCADE;

-- 3. Re-verify that our new TIMESTAMPTZ version of calculate_account_balance remains the primary candidate
-- (It was already created in 20260417000010, so it should be fine, but we can recreate it to be safe)

CREATE OR REPLACE FUNCTION public.calculate_account_balance(
  p_account_id UUID,
  p_as_of_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
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
BEGIN
  -- Get opening balance from bank_accounts
  SELECT opening_balance INTO v_opening_balance
  FROM public.bank_accounts
  WHERE id = p_account_id AND deleted_at IS NULL;

  IF v_opening_balance IS NULL THEN
    RETURN 0;
  END IF;

  -- Calculate total received as of the exact timestamp
  SELECT COALESCE(SUM(ptd.amount), 0) INTO v_total_received
  FROM public.payment_transaction_details ptd
  INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
  WHERE ptd.bank_account_id = p_account_id
    AND ptr.direction = 'RECEIVED'
    AND ptr.status = 'completed'
    AND ptr.transaction_date <= p_as_of_date;

  -- Calculate total given as of the exact timestamp
  SELECT COALESCE(SUM(ptd.amount), 0) INTO v_total_given
  FROM public.payment_transaction_details ptd
  INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
  WHERE ptd.bank_account_id = p_account_id
    AND ptr.direction = 'GIVEN'
    AND ptr.status = 'completed'
    AND ptr.transaction_date <= p_as_of_date;

  -- Calculate balance
  v_balance := v_opening_balance + v_total_received - v_total_given;

  RETURN v_balance;
END;
$$;

COMMENT ON FUNCTION public.calculate_account_balance IS 'Calculate account balance as of a specific date/time. Uses TIMESTAMPTZ for precision.';
