-- Function to sync leave balances when contract leaves are updated
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
  -- Get all contract leaves for the contract
  FOR contract_leave IN
    SELECT cl.leave_type_id, cl.days_allowed
    FROM public.contract_leaves cl
    WHERE cl.contract_id = p_contract_id
      AND cl.is_active = true
      AND cl.is_deleted = false
  LOOP
    -- Insert or update leave balance
    INSERT INTO public.leave_balances (
      employee_id,
      leave_type_id,
      year,
      allocated_days,
      used_days,
      carried_forward,
      encashed_days
    ) VALUES (
      p_employee_id,
      contract_leave.leave_type_id,
      p_year,
      contract_leave.days_allowed,
      0,
      0,
      0
    )
    ON CONFLICT (employee_id, leave_type_id, year)
    DO UPDATE SET
      allocated_days = contract_leave.days_allowed,
      updated_at = CURRENT_TIMESTAMP;
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- Function to initialize leave balances for all employees with active contracts
CREATE OR REPLACE FUNCTION public.initialize_all_leave_balances(
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  employee_contract RECORD;
BEGIN
  -- Get all employees with active contracts
  FOR employee_contract IN
    SELECT DISTINCT c.employee_id, c.id as contract_id
    FROM public.contracts c
    WHERE c.status = 'active'
      AND c.is_active = true
      AND c.is_deleted = false
  LOOP
    -- Sync leave balances for each employee
    PERFORM public.sync_leave_balances_from_contract(
      employee_contract.employee_id,
      employee_contract.contract_id,
      p_year
    );
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- Trigger function to automatically sync leave balances when contract leaves are modified
CREATE OR REPLACE FUNCTION public.trigger_sync_leave_balances()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  employee_id_val UUID;
BEGIN
  -- Get employee_id from the contract
  SELECT c.employee_id INTO employee_id_val
  FROM public.contracts c
  WHERE c.id = COALESCE(NEW.contract_id, OLD.contract_id);
  
  -- Sync leave balances
  IF employee_id_val IS NOT NULL THEN
    PERFORM public.sync_leave_balances_from_contract(
      employee_id_val,
      COALESCE(NEW.contract_id, OLD.contract_id),
      EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    );
  END IF;
  
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Create trigger on contract_leaves table
DROP TRIGGER IF EXISTS trigger_sync_leave_balances_on_contract_leaves ON public.contract_leaves;
CREATE TRIGGER trigger_sync_leave_balances_on_contract_leaves
  AFTER INSERT OR UPDATE OR DELETE ON public.contract_leaves
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_sync_leave_balances();

-- Initialize leave balances for current year for all existing employees
SELECT public.initialize_all_leave_balances();