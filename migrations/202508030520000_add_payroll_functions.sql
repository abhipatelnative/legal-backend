-- Function to generate payroll for a specific period
CREATE OR REPLACE FUNCTION public.generate_payroll_for_period(
  p_payroll_period_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  period_record RECORD;
  employee_record RECORD;
  attendance_record RECORD;
  salary_components RECORD;
  gross_salary DECIMAL(15,2);
  total_deductions DECIMAL(15,2);
  net_salary DECIMAL(15,2);
  working_days INTEGER;
  present_days INTEGER;
BEGIN
  -- Get period details
  SELECT * INTO period_record 
  FROM public.payroll_periods 
  WHERE id = p_payroll_period_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll period not found';
  END IF;
  
  -- Calculate working days for the period
  working_days := (period_record.end_date - period_record.start_date) + 1;
  
  -- Loop through all active employees
  FOR employee_record IN
    SELECT e.id, e.employee_code, e.user_id
    FROM public.employees e
    WHERE e.is_active = true 
      AND e.is_deleted = false
  LOOP
    -- Calculate attendance for this employee in this period
    SELECT 
      COUNT(*) FILTER (WHERE status = 'present') as present_count,
      COUNT(*) as total_count
    INTO attendance_record
    FROM public.attendance a
    WHERE a.employee_id = employee_record.id
      AND a.date BETWEEN period_record.start_date AND period_record.end_date;
    
    present_days := COALESCE(attendance_record.present_count, working_days);
    
    -- Calculate salary components
    SELECT 
      SUM(CASE WHEN sc.component_type = 'earning' THEN esc.value ELSE 0 END) as earnings,
      SUM(CASE WHEN sc.component_type = 'deduction' THEN esc.value ELSE 0 END) as deductions
    INTO salary_components
    FROM public.employee_salary_components esc
    JOIN public.salary_components sc ON esc.salary_component_id = sc.id
    WHERE esc.employee_id = employee_record.id
      AND esc.is_active = true
      AND esc.is_deleted = false
      AND (esc.effective_to IS NULL OR esc.effective_to >= period_record.end_date);
    
    gross_salary := COALESCE(salary_components.earnings, 0);
    total_deductions := COALESCE(salary_components.deductions, 0);
    net_salary := gross_salary - total_deductions;
    
    -- Insert or update payroll record
    INSERT INTO public.payroll (
      payroll_period_id,
      employee_id,
      basic_salary,
      gross_salary,
      total_deductions,
      net_salary,
      working_days,
      present_days,
      status
    ) VALUES (
      p_payroll_period_id,
      employee_record.id,
      gross_salary,
      gross_salary,
      total_deductions,
      net_salary,
      working_days,
      present_days,
      'draft'
    )
    ON CONFLICT (payroll_period_id, employee_id)
    DO UPDATE SET
      basic_salary = EXCLUDED.basic_salary,
      gross_salary = EXCLUDED.gross_salary,
      total_deductions = EXCLUDED.total_deductions,
      net_salary = EXCLUDED.net_salary,
      working_days = EXCLUDED.working_days,
      present_days = EXCLUDED.present_days,
      updated_at = CURRENT_TIMESTAMP;
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- Function to calculate employee payroll
CREATE OR REPLACE FUNCTION public.calculate_employee_payroll(
  p_employee_id UUID,
  p_payroll_period_id UUID
)
RETURNS TABLE(
  basic_salary DECIMAL(15,2),
  gross_salary DECIMAL(15,2),
  total_deductions DECIMAL(15,2),
  net_salary DECIMAL(15,2),
  working_days INTEGER,
  present_days INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  period_record RECORD;
  attendance_count INTEGER;
  salary_components RECORD;
  calculated_working_days INTEGER;
BEGIN
  -- Get period details
  SELECT * INTO period_record 
  FROM public.payroll_periods 
  WHERE id = p_payroll_period_id;
  
  -- Calculate working days
  calculated_working_days := (period_record.end_date - period_record.start_date) + 1;
  
  -- Get attendance count
  SELECT COUNT(*) FILTER (WHERE status = 'present')
  INTO attendance_count
  FROM public.attendance a
  WHERE a.employee_id = p_employee_id
    AND a.date BETWEEN period_record.start_date AND period_record.end_date;
  
  -- Get salary components
  SELECT 
    SUM(CASE WHEN sc.component_type = 'earning' THEN esc.value ELSE 0 END) as earnings,
    SUM(CASE WHEN sc.component_type = 'deduction' THEN esc.value ELSE 0 END) as deductions
  INTO salary_components
  FROM public.employee_salary_components esc
  JOIN public.salary_components sc ON esc.salary_component_id = sc.id
  WHERE esc.employee_id = p_employee_id
    AND esc.is_active = true
    AND esc.is_deleted = false;
  
  RETURN QUERY SELECT 
    COALESCE(salary_components.earnings, 0)::DECIMAL(15,2),
    COALESCE(salary_components.earnings, 0)::DECIMAL(15,2),
    COALESCE(salary_components.deductions, 0)::DECIMAL(15,2),
    (COALESCE(salary_components.earnings, 0) - COALESCE(salary_components.deductions, 0))::DECIMAL(15,2),
    calculated_working_days,
    COALESCE(attendance_count, calculated_working_days);
END;
$$;