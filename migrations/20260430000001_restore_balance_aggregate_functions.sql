-- Cash & Bank Module - Restore Balance Aggregate Functions
-- Migration: 20260430000001
-- Purpose: Re-create get_all_account_balances and get_all_account_balances_as_of_date
--          which were silently dropped when calculate_account_balance(UUID) was dropped
--          with CASCADE in migration 20260417000011.

-- ============================================
-- Function: Get All Account Balances (current moment)
-- ============================================
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
    public.calculate_account_balance(ba.id, CURRENT_TIMESTAMP) AS current_balance
  FROM public.bank_accounts ba
  WHERE ba.deleted_at IS NULL
    AND ba.is_active = true
  ORDER BY ba.is_default DESC, ba.account_type ASC, ba.account_name ASC;
END;
$$;

COMMENT ON FUNCTION public.get_all_account_balances IS 'Get all active accounts with their current balances. Uses TIMESTAMPTZ-aware calculate_account_balance.';

-- ============================================
-- Function: Get All Account Balances (as of date)
-- ============================================
-- Drop the old TIMESTAMP (no timezone) overload that causes ambiguity
DROP FUNCTION IF EXISTS public.get_all_account_balances_as_of_date(TIMESTAMP WITHOUT TIME ZONE);

CREATE OR REPLACE FUNCTION public.get_all_account_balances_as_of_date(
  p_as_of_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
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

COMMENT ON FUNCTION public.get_all_account_balances_as_of_date IS 'Get all active accounts with their balances as of a specific timestamp. Uses TIMESTAMPTZ for precision.';
