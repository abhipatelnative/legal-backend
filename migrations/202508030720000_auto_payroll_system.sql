-- Function to auto-create current month payroll period
CREATE OR REPLACE FUNCTION public.auto_create_current_month_period()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE);
  current_month INTEGER := EXTRACT(MONTH FROM CURRENT_DATE);
  period_name VARCHAR(255);
  start_date DATE;
  end_date DATE;
  existing_period UUID;
  month_names TEXT[] := ARRAY['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
BEGIN
  -- Check if period already exists
  SELECT id INTO existing_period
  FROM public.payroll_periods
  WHERE year = current_year 
    AND month = current_month
    AND is_active = true
    AND is_deleted = false;
  
  -- If period doesn't exist, create it
  IF existing_period IS NULL THEN
    -- Generate period name
    period_name := month_names[current_month] || ' ' || current_year;
    
    -- Calculate dates
    start_date := DATE_TRUNC('month', CURRENT_DATE)::DATE;
    end_date := (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month - 1 day')::DATE;
    
    -- Insert new period
    INSERT INTO public.payroll_periods (
      name,
      start_date,
      end_date,
      year,
      month,
      status
    ) VALUES (
      period_name,
      start_date,
      end_date,
      current_year,
      current_month,
      'draft'
    );
    
    RETURN TRUE;
  END IF;
  
  RETURN FALSE;
END;
$$;

-- Function to calculate payroll up to current date
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
  attendance_record RECORD;
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
    -- Calculate attendance for this employee up to current date
    SELECT 
      COUNT(*) FILTER (WHERE status = 'present') as present_count
    INTO attendance_record
    FROM public.attendance a
    WHERE a.employee_id = employee_record.id
      AND a.date BETWEEN period_record.start_date AND LEAST(CURRENT_DATE, period_record.end_date);
    
    present_days := COALESCE(attendance_record.present_count, days_to_calculate);
    
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
    pro_rated_gross := (gross_salary * present_days) / total_days;
    pro_rated_deductions := (total_deductions * present_days) / total_days;
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

-- Auto-create current month period on system startup
SELECT public.auto_create_current_month_period();