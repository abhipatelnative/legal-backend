-- Function to update leave balance when leave is approved
CREATE OR REPLACE FUNCTION public.update_leave_balance(
  p_employee_id UUID,
  p_leave_type_id UUID,
  p_year INTEGER,
  p_days_to_use DECIMAL(10,2)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Update the used_days in leave_balances
  UPDATE public.leave_balances 
  SET 
    used_days = used_days + p_days_to_use,
    updated_at = CURRENT_TIMESTAMP
  WHERE 
    employee_id = p_employee_id 
    AND leave_type_id = p_leave_type_id 
    AND year = p_year;
    
  -- If no record exists, create one (this shouldn't happen in normal flow)
  IF NOT FOUND THEN
    INSERT INTO public.leave_balances (
      employee_id, 
      leave_type_id, 
      year, 
      allocated_days, 
      used_days
    ) VALUES (
      p_employee_id, 
      p_leave_type_id, 
      p_year, 
      0, 
      p_days_to_use
    );
  END IF;
  
  RETURN TRUE;
END;
$$;

-- Function to initialize leave balances for an employee based on their contract
CREATE OR REPLACE FUNCTION public.initialize_employee_leave_balances(
  p_employee_id UUID,
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  contract_leave RECORD;
  initial_allocated_days DECIMAL(10,2);
BEGIN
  -- Get active contract for the employee
  FOR contract_leave IN
    SELECT cl.leave_type_id, cl.days_allowed, cl.salary_payable
    FROM public.contracts c
    JOIN public.contract_leaves cl ON c.id = cl.contract_id
    WHERE c.employee_id = p_employee_id
      AND c.status = 'active'
      AND c.is_active = true
      AND c.is_deleted = false
      AND cl.is_active = true
      AND cl.is_deleted = false
  LOOP
    -- Set initial allocated days based on leave type
    IF contract_leave.salary_payable THEN
      initial_allocated_days := 0; -- Payable leaves: must earn through attendance
    ELSE
      initial_allocated_days := 999999; -- Non-payable leaves: unlimited
    END IF;
    
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
      initial_allocated_days,
      0,
      0,
      0
    )
    ON CONFLICT (employee_id, leave_type_id, year)
    DO UPDATE SET
      allocated_days = initial_allocated_days,
      updated_at = CURRENT_TIMESTAMP;
  END LOOP;
  
  RETURN TRUE;
END;
$$;