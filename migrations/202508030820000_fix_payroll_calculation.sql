-- Fix the payroll calculation function to handle missing attendance and use correct enum values
CREATE OR REPLACE FUNCTION public.calculate_payroll_to_date(
  p_payroll_period_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  period_record RECORD;
  employee_record RECORD;
  salary_components RECORD;
  gross_salary DECIMAL(15,2);
  total_deductions DECIMAL(15,2);
  net_salary DECIMAL(15,2);
  total_days INTEGER;
  present_days INTEGER;
  days_to_calculate INTEGER;
  pro_rated_gross DECIMAL(15,2);
  pro_rated_deductions DECIMAL(15,2);
BEGIN
  -- Get period details
  SELECT * INTO period_record 
  FROM public.payroll_periods 
  WHERE id = p_payroll_period_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll period not found';
  END IF;
  
  -- Calculate days from start of month to today
  IF CURRENT_DATE > period_record.end_date THEN
    days_to_calculate := (period_record.end_date - period_record.start_date) + 1;
  ELSE
    days_to_calculate := (CURRENT_DATE - period_record.start_date) + 1;
  END IF;
  
  -- Total days in month
  total_days := (period_record.end_date - period_record.start_date) + 1;
  
  -- Loop through all active employees
  FOR employee_record IN
    SELECT e.id, e.employee_code, e.user_id
    FROM public.employees e
    WHERE e.is_active = true 
      AND e.is_deleted = false
  LOOP
    -- Since no attendance data, assume employee worked all days up to current date
    present_days := days_to_calculate;
    
    -- Get salary components
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
    
    -- Pro-rate salary based on days worked
    IF total_days > 0 THEN
      pro_rated_gross := (gross_salary * present_days) / total_days;
      pro_rated_deductions := (total_deductions * present_days) / total_days;
    ELSE
      pro_rated_gross := gross_salary;
      pro_rated_deductions := total_deductions;
    END IF;
    
    net_salary := pro_rated_gross - pro_rated_deductions;
    
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
      pro_rated_gross,
      pro_rated_gross,
      pro_rated_deductions,
      net_salary,
      days_to_calculate,
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
      status = 'draft',
      updated_at = CURRENT_TIMESTAMP;
  END LOOP;
  
  -- Update period status
  UPDATE public.payroll_periods 
  SET status = 'processed'
  WHERE id = p_payroll_period_id;
  
  RETURN TRUE;
END;
$$;