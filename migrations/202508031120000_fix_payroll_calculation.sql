-- Fix payroll calculation to handle employees without salary components
CREATE OR REPLACE FUNCTION public.calculate_payroll_to_date(p_payroll_period_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_period RECORD;
  v_employee RECORD;
  v_current_date INTEGER;
  v_total_days INTEGER;
  v_earnings NUMERIC(15,2);
  v_deductions NUMERIC(15,2);
  v_daily_salary NUMERIC(15,2);
  v_calculated_gross NUMERIC(15,2);
  v_calculated_deductions NUMERIC(15,2);
  v_calculated_net NUMERIC(15,2);
BEGIN
  -- Get period details
  SELECT * INTO v_period
  FROM public.payroll_periods
  WHERE id = p_payroll_period_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll period not found';
  END IF;

  -- Calculate current date and total days
  v_current_date := EXTRACT(DAY FROM CURRENT_DATE);
  v_total_days := EXTRACT(DAY FROM (DATE_TRUNC('MONTH', v_period.start_date::date) + INTERVAL '1 MONTH - 1 DAY'));

  -- Process each active employee
  FOR v_employee IN
    SELECT e.id, e.employee_code, e.user_id
    FROM public.employees e
    WHERE e.is_active = true 
      AND e.is_deleted = false
      AND EXISTS (
        SELECT 1 FROM public.contracts c
        WHERE c.employee_id = e.id
          AND c.status = 'active'
          AND c.is_active = true
          AND c.is_deleted = false
      )
  LOOP
    -- Get salary components for employee
    SELECT 
      COALESCE(SUM(CASE WHEN sc.component_type = 'earning' THEN esc.value ELSE 0 END), 0),
      COALESCE(SUM(CASE WHEN sc.component_type = 'deduction' THEN esc.value ELSE 0 END), 0)
    INTO v_earnings, v_deductions
    FROM public.employee_salary_components esc
    JOIN public.salary_components sc ON esc.salary_component_id = sc.id
    WHERE esc.employee_id = v_employee.id
      AND esc.is_active = true
      AND esc.is_deleted = false;

    -- If no salary components, get basic salary from contract
    IF v_earnings = 0 THEN
      SELECT COALESCE(c.basic_salary, 0) INTO v_earnings
      FROM public.contracts c
      WHERE c.employee_id = v_employee.id
        AND c.status = 'active'
        AND c.is_active = true
        AND c.is_deleted = false
      ORDER BY c.created_at DESC
      LIMIT 1;
    END IF;

    -- Skip if still no salary data
    IF v_earnings <= 0 THEN
      CONTINUE;
    END IF;

    -- Calculate pro-rated amounts
    v_daily_salary := v_earnings / v_total_days;
    v_calculated_gross := v_daily_salary * v_current_date;
    v_calculated_deductions := (v_deductions / v_total_days) * v_current_date;
    v_calculated_net := v_calculated_gross - v_calculated_deductions;

    -- Ensure minimum values to satisfy constraints
    v_calculated_gross := GREATEST(v_calculated_gross, 0.01);
    v_calculated_net := GREATEST(v_calculated_net, 0);

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
      leave_days,
      overtime_hours,
      overtime_amount,
      status,
      manual_adjustment_total
    ) VALUES (
      p_payroll_period_id,
      v_employee.id,
      v_earnings,
      v_calculated_gross,
      v_calculated_deductions,
      v_calculated_net,
      v_total_days,
      v_current_date,
      0,
      0,
      0,
      'draft',
      0
    )
    ON CONFLICT (payroll_period_id, employee_id)
    DO UPDATE SET
      basic_salary = v_earnings,
      gross_salary = v_calculated_gross,
      total_deductions = v_calculated_deductions,
      net_salary = v_calculated_net,
      working_days = v_total_days,
      present_days = v_current_date,
      updated_at = CURRENT_TIMESTAMP;

  END LOOP;

  RETURN TRUE;
END;
$$;

-- Also create the auto_create_current_month_period function if it doesn't exist
CREATE OR REPLACE FUNCTION public.auto_create_current_month_period()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_year INTEGER;
  v_month INTEGER;
  v_start_date DATE;
  v_end_date DATE;
  v_name TEXT;
BEGIN
  v_year := EXTRACT(YEAR FROM CURRENT_DATE);
  v_month := EXTRACT(MONTH FROM CURRENT_DATE);
  v_start_date := DATE_TRUNC('MONTH', CURRENT_DATE)::DATE;
  v_end_date := (DATE_TRUNC('MONTH', CURRENT_DATE) + INTERVAL '1 MONTH - 1 DAY')::DATE;
  v_name := TO_CHAR(CURRENT_DATE, 'Month YYYY');

  INSERT INTO public.payroll_periods (
    name,
    start_date,
    end_date,
    year,
    month,
    status
  ) VALUES (
    v_name,
    v_start_date,
    v_end_date,
    v_year,
    v_month,
    'draft'
  )
  ON CONFLICT (year, month) DO NOTHING;

  RETURN TRUE;
END;
$$;