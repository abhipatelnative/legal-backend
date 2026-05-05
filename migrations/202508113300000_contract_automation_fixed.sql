-- Fix contract automation to handle overdue contract endings
CREATE OR REPLACE FUNCTION public.manage_contract_lifecycle()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  contract_record RECORD;
  employee_record RECORD;
  next_contract_record RECORD;
  today_date DATE := CURRENT_DATE;
  system_user_id UUID;
BEGIN
  -- Get system user ID (first admin user)
  SELECT id INTO system_user_id 
  FROM auth.users 
  WHERE id IN (
    SELECT ur.user_id 
    FROM public.user_roles ur 
    JOIN public.roles r ON ur.role_id = r.id 
    WHERE r.name = 'Admin' AND ur.is_active = true
  ) 
  LIMIT 1;

  -- 1. Process contracts that should start today
  FOR contract_record IN 
    SELECT c.*, e.id as emp_id
    FROM public.contracts c
    JOIN public.employees e ON c.employee_id = e.id
    WHERE c.start_date = today_date
    AND c.status = 'draft'
    AND c.is_active = true
    AND c.is_deleted = false
    AND e.is_deleted = false
  LOOP
    UPDATE public.contracts 
    SET status = 'active', updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
    WHERE id = contract_record.id;

    UPDATE public.employees 
    SET is_active = true, updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
    WHERE id = contract_record.employee_id;
  END LOOP;

  -- 2. Process contracts that should end (today OR overdue)
  FOR contract_record IN 
    SELECT c.*, e.id as emp_id
    FROM public.contracts c
    JOIN public.employees e ON c.employee_id = e.id
    WHERE c.end_date <= today_date  -- Changed: <= instead of =
    AND c.status = 'active'
    AND c.is_active = true
    AND c.is_deleted = false
    AND e.is_deleted = false
  LOOP
    -- Check for next contract
    SELECT * INTO next_contract_record
    FROM public.contracts
    WHERE employee_id = contract_record.employee_id
    AND start_date >= today_date
    AND status IN ('draft', 'active')
    AND is_active = true
    AND is_deleted = false
    AND id != contract_record.id
    ORDER BY start_date ASC
    LIMIT 1;

    -- End current contract
    UPDATE public.contracts 
    SET status = 'expired', updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
    WHERE id = contract_record.id;

    IF next_contract_record.id IS NOT NULL THEN
      IF next_contract_record.start_date = today_date THEN
        UPDATE public.contracts 
        SET status = 'active', updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
        WHERE id = next_contract_record.id;
      END IF;
    ELSE
      UPDATE public.employees 
      SET is_active = false, updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
      WHERE id = contract_record.employee_id;
    END IF;
  END LOOP;

  -- 3. Handle overdue contract starts
  FOR contract_record IN 
    SELECT c.*, e.id as emp_id
    FROM public.contracts c
    JOIN public.employees e ON c.employee_id = e.id
    WHERE c.start_date < today_date
    AND c.status = 'draft'
    AND c.is_active = true
    AND c.is_deleted = false
    AND e.is_deleted = false
  LOOP
    UPDATE public.contracts 
    SET status = 'active', updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
    WHERE id = contract_record.id;

    UPDATE public.employees 
    SET is_active = true, updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
    WHERE id = contract_record.employee_id;
  END LOOP;

  -- 4. Deactivate employees with no active contracts
  FOR employee_record IN 
    SELECT e.id
    FROM public.employees e
    WHERE e.is_active = true
    AND e.is_deleted = false
    AND NOT EXISTS (
      SELECT 1 FROM public.contracts c
      WHERE c.employee_id = e.id
      AND c.status = 'active'
      AND c.is_active = true
      AND c.is_deleted = false
      AND (c.end_date IS NULL OR c.end_date >= today_date)
    )
  LOOP
    UPDATE public.employees 
    SET is_active = false, updated_at = CURRENT_TIMESTAMP, updated_by = system_user_id
    WHERE id = employee_record.id;
  END LOOP;

EXCEPTION
  WHEN OTHERS THEN
    NULL;
END;
$$;

-- Manual trigger function for testing
CREATE OR REPLACE FUNCTION public.trigger_contract_lifecycle_manually()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  PERFORM public.manage_contract_lifecycle();
  RETURN 'Contract lifecycle management executed successfully.';
END;
$$;

-- Create the cron job to run daily at 1 AM
SELECT cron.schedule(
  'daily-contract-lifecycle',
  '0 1 * * *',
  'SELECT public.manage_contract_lifecycle();'
);

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.manage_contract_lifecycle() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trigger_contract_lifecycle_manually() TO authenticated;