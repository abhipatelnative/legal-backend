-- Migration: Update Leave Balance Functions to be Contract-Aware
-- Description: Updates the SQL functions to properly handle contract-specific leave balances.

-- First, DROP the existing functions to avoid signature/return type conflicts
DROP FUNCTION IF EXISTS public.update_leave_balance(UUID, UUID, INTEGER, DECIMAL);
DROP FUNCTION IF EXISTS public.update_leave_balance(UUID, UUID, INTEGER, NUMERIC);
DROP FUNCTION IF EXISTS public.sync_leave_balances_from_contract(UUID, UUID, INTEGER);

-- 1. Update update_leave_balance
CREATE OR REPLACE FUNCTION public.update_leave_balance(
  p_employee_id UUID,
  p_leave_type_id UUID,
  p_year INTEGER,
  p_days_to_use NUMERIC -- Use NUMERIC for consistency with common schema
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_contract_id UUID;
BEGIN
  -- Find the currently active contract for the employee
  SELECT id INTO v_contract_id
  FROM public.contracts
  WHERE employee_id = p_employee_id
    AND status = 'active'
    AND is_active = true
    AND is_deleted = false
  LIMIT 1;

  IF v_contract_id IS NULL THEN
    RAISE EXCEPTION 'No active contract found for employee %. Cannot update leave balance.', p_employee_id;
  END IF;

  -- Update the leave balance record matching the active contract
  UPDATE public.leave_balances
  SET
    used_days = COALESCE(used_days, 0) + p_days_to_use,
    updated_at = CURRENT_TIMESTAMP
  WHERE
    employee_id = p_employee_id
    AND contract_id = v_contract_id
    AND leave_type_id = p_leave_type_id
    AND year = p_year;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Leave balance for employee % (Contract %), type %, year % does not exist. Please sync balances first.', 
      p_employee_id, v_contract_id, p_leave_type_id, p_year;
  END IF;

  RETURN TRUE;
END;
$$;

-- 2. Update sync_leave_balances_from_contract
CREATE OR REPLACE FUNCTION public.sync_leave_balances_from_contract(
  p_employee_id UUID,
  p_contract_id UUID,
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  contract_leave RECORD;
BEGIN
  FOR contract_leave IN
    SELECT cl.leave_type_id, cl.days_allowed
    FROM public.contract_leaves cl
    WHERE cl.contract_id = p_contract_id
      AND cl.is_active = true
      AND cl.is_deleted = false
  LOOP
    -- Insert or update leave balance including contract_id
    INSERT INTO public.leave_balances (
      employee_id,
      leave_type_id,
      year,
      contract_id,
      allocated_days,
      used_days,
      carried_forward,
      encashed_days
    ) VALUES (
      p_employee_id,
      contract_leave.leave_type_id,
      p_year,
      p_contract_id,
      contract_leave.days_allowed,
      0,
      0,
      0
    )
    ON CONFLICT (employee_id, leave_type_id, year, contract_id)
    DO UPDATE SET
      allocated_days = EXCLUDED.allocated_days,
      updated_at = CURRENT_TIMESTAMP;
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- Grant execution permissions
GRANT EXECUTE ON FUNCTION public.update_leave_balance(UUID, UUID, INTEGER, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_leave_balance(UUID, UUID, INTEGER, NUMERIC) TO service_role;
GRANT EXECUTE ON FUNCTION public.sync_leave_balances_from_contract(UUID, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_leave_balances_from_contract(UUID, UUID, INTEGER) TO service_role;

COMMENT ON FUNCTION public.update_leave_balance(UUID, UUID, INTEGER, NUMERIC) IS 'Updates used_days for an employee based on their active contract.';
COMMENT ON FUNCTION public.sync_leave_balances_from_contract(UUID, UUID, INTEGER) IS 'Synchronizes leave balances for a specific contract and year.';
