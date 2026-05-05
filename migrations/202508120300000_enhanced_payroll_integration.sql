-- Enhanced Payroll Integration
-- Integrate all financial and attendance rules with existing payroll system

-- Update the main payroll calculation function to include all new features
CREATE OR REPLACE FUNCTION public.calculate_comprehensive_payroll(
  p_payroll_period_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_period RECORD;
  v_employee RECORD;
  v_settings RECORD;
BEGIN
  -- Get period details
  SELECT * INTO v_period FROM public.payroll_periods WHERE id = p_payroll_period_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payroll period not found';
  END IF;
  
  -- Get relevant settings
  SELECT 
    (SELECT setting_value::BOOLEAN FROM public.system_settings WHERE setting_key = 'attendance_sandwich_rule_enabled') as sandwich_enabled,
    (SELECT setting_value::BOOLEAN FROM public.system_settings WHERE setting_key = 'financial_security_deposit_enabled') as deposit_enabled,
    (SELECT setting_value::BOOLEAN FROM public.system_settings WHERE setting_key = 'financial_loans_enabled') as loans_enabled,
    (SELECT setting_value::BOOLEAN FROM public.system_settings WHERE setting_key = 'financial_pf_enabled') as pf_enabled
  INTO v_settings;
  
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
    -- 1. First run standard payroll calculation
    PERFORM public.calculate_payroll_to_date(p_payroll_period_id);
    
    -- 2. Apply sandwich rule if enabled
    IF v_settings.sandwich_enabled THEN
      PERFORM public.apply_sandwich_rule_with_settings(
        v_employee.id, v_period.start_date, v_period.end_date
      );
    END IF;
    
    -- 3. Process financial deductions if enabled
    IF v_settings.deposit_enabled OR v_settings.loans_enabled OR v_settings.pf_enabled THEN
      PERFORM public.process_monthly_financial_deductions(
        p_payroll_period_id, v_employee.id
      );
    END IF;
    
    -- 4. Apply advanced attendance calculations
    PERFORM public.calculate_advanced_payroll(p_payroll_period_id, v_employee.id);
    
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- Create comprehensive salary slip data function
CREATE OR REPLACE FUNCTION public.get_comprehensive_salary_slip(
  p_payroll_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_payroll RECORD;
  v_employee RECORD;
  v_period RECORD;
  v_earnings JSONB := '[]'::JSONB;
  v_deductions JSONB := '[]'::JSONB;
  v_financial_data JSONB := '{}'::JSONB;
  v_attendance_data JSONB := '{}'::JSONB;
  v_result JSONB;
BEGIN
  -- Get payroll record
  SELECT p.*, pp.name as period_name, pp.start_date, pp.end_date
  INTO v_payroll
  FROM public.payroll p
  JOIN public.payroll_periods pp ON p.payroll_period_id = pp.id
  WHERE p.id = p_payroll_id;
  
  -- Get employee details
  SELECT e.*, up.first_name, up.last_name
  INTO v_employee
  FROM public.employees e
  JOIN public.user_profiles up ON e.user_id = up.id
  WHERE e.id = v_payroll.employee_id;
  
  -- Get earnings breakdown
  SELECT jsonb_agg(
    jsonb_build_object(
      'component', sc.name,
      'amount', pc.amount
    )
  ) INTO v_earnings
  FROM public.payroll_components pc
  JOIN public.salary_components sc ON pc.salary_component_id = sc.id
  WHERE pc.payroll_id = p_payroll_id 
    AND sc.component_type = 'earning'
    AND pc.is_active = true;
  
  -- Get deductions breakdown
  SELECT jsonb_agg(
    jsonb_build_object(
      'component', sc.name,
      'amount', pc.amount
    )
  ) INTO v_deductions
  FROM public.payroll_components pc
  JOIN public.salary_components sc ON pc.salary_component_id = sc.id
  WHERE pc.payroll_id = p_payroll_id 
    AND sc.component_type = 'deduction'
    AND pc.is_active = true;
  
  -- Get financial data
  SELECT jsonb_build_object(
    'security_deposits', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'amount', sdt.amount,
          'type', sdt.transaction_type,
          'date', sdt.transaction_date
        )
      )
      FROM public.security_deposit_transactions sdt
      JOIN public.employee_security_deposits esd ON sdt.security_deposit_id = esd.id
      WHERE esd.employee_id = v_payroll.employee_id
        AND sdt.payroll_period_id = v_payroll.payroll_period_id
    ),
    'loans', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'amount', lt.amount,
          'type', lt.transaction_type,
          'date', lt.transaction_date
        )
      )
      FROM public.loan_transactions lt
      JOIN public.employee_loans el ON lt.loan_id = el.id
      WHERE el.employee_id = v_payroll.employee_id
        AND lt.payroll_period_id = v_payroll.payroll_period_id
    ),
    'pf', (
      SELECT jsonb_build_object(
        'employee_contribution', pt.employee_contribution,
        'employer_contribution', pt.employer_contribution,
        'total_balance', pfa.total_balance
      )
      FROM public.pf_transactions pt
      JOIN public.employee_pf_accounts pfa ON pt.pf_account_id = pfa.id
      WHERE pfa.employee_id = v_payroll.employee_id
        AND pt.payroll_period_id = v_payroll.payroll_period_id
      LIMIT 1
    )
  ) INTO v_financial_data;
  
  -- Get attendance data
  SELECT jsonb_build_object(
    'total_days', COUNT(*),
    'present_days', COUNT(*) FILTER (WHERE ar.status = 'present'),
    'half_days', COUNT(*) FILTER (WHERE ar.status = 'half_day'),
    'absent_days', COUNT(*) FILTER (WHERE ar.status = 'absent'),
    'late_arrivals', COUNT(*) FILTER (WHERE ar.late_arrival_minutes > 0),
    'penalties', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'date', elt.attendance_date,
          'type', elt.penalty_type,
          'late_minutes', elt.late_minutes
        )
      )
      FROM public.employee_late_tracking elt
      WHERE elt.employee_id = v_payroll.employee_id
        AND elt.attendance_date BETWEEN v_payroll.start_date AND v_payroll.end_date
        AND elt.penalty_applied = true
    ),
    'sandwich_rule_penalties', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'start_date', srt.start_date,
          'end_date', srt.end_date,
          'deduction', srt.salary_deduction
        )
      )
      FROM public.sandwich_rule_tracking srt
      WHERE srt.employee_id = v_payroll.employee_id
        AND srt.start_date >= v_payroll.start_date
        AND srt.end_date <= v_payroll.end_date
        AND srt.penalty_applied = true
    )
  ) INTO v_attendance_data
  FROM public.attendance_records ar
  JOIN public.employees e ON e.user_id = ar.user_profile_id
  WHERE e.id = v_payroll.employee_id
    AND ar.attendance_date BETWEEN v_payroll.start_date AND v_payroll.end_date;
  
  -- Build comprehensive result
  v_result := jsonb_build_object(
    'payroll', jsonb_build_object(
      'id', v_payroll.id,
      'period_name', v_payroll.period_name,
      'basic_salary', v_payroll.basic_salary,
      'gross_salary', v_payroll.gross_salary,
      'total_deductions', v_payroll.total_deductions,
      'net_salary', v_payroll.net_salary,
      'working_days', v_payroll.working_days,
      'present_days', v_payroll.present_days
    ),
    'employee', jsonb_build_object(
      'name', v_employee.first_name || ' ' || v_employee.last_name,
      'employee_code', v_employee.employee_code,
      'company_email', v_employee.company_email
    ),
    'earnings', COALESCE(v_earnings, '[]'::JSONB),
    'deductions', COALESCE(v_deductions, '[]'::JSONB),
    'financial_data', v_financial_data,
    'attendance_data', v_attendance_data
  );
  
  RETURN v_result;
END;
$$;

-- Create function to get employee financial summary
CREATE OR REPLACE FUNCTION public.get_employee_financial_summary(
  p_employee_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'security_deposits', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', esd.id,
          'deposit_amount', esd.deposit_amount,
          'monthly_deduction', esd.monthly_deduction,
          'total_collected', esd.total_collected,
          'status', esd.status,
          'interest_earned', public.calculate_security_deposit_interest(esd.id)
        )
      )
      FROM public.employee_security_deposits esd
      WHERE esd.employee_id = p_employee_id AND esd.is_active = true
    ),
    'loans', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', el.id,
          'loan_amount', el.loan_amount,
          'monthly_deduction', el.monthly_deduction,
          'total_paid', el.total_paid,
          'remaining_amount', el.remaining_amount,
          'status', el.status
        )
      )
      FROM public.employee_loans el
      WHERE el.employee_id = p_employee_id AND el.is_active = true
    ),
    'pf_account', (
      SELECT jsonb_build_object(
        'pf_number', pfa.pf_number,
        'employee_contribution_rate', pfa.employee_contribution_rate,
        'employer_contribution_rate', pfa.employer_contribution_rate,
        'total_employee_contribution', pfa.total_employee_contribution,
        'total_employer_contribution', pfa.total_employer_contribution,
        'total_balance', pfa.total_balance
      )
      FROM public.employee_pf_accounts pfa
      WHERE pfa.employee_id = p_employee_id AND pfa.is_active = true
      LIMIT 1
    )
  ) INTO v_result;
  
  RETURN v_result;
END;
$$;

-- Create function to apply bulk attendance rules
CREATE OR REPLACE FUNCTION public.apply_bulk_attendance_rules(
  p_start_date DATE,
  p_end_date DATE
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_employee RECORD;
BEGIN
  FOR v_employee IN
    SELECT id FROM public.employees 
    WHERE is_active = true AND is_deleted = false
  LOOP
    -- Apply sandwich rule
    PERFORM public.apply_sandwich_rule_with_settings(
      v_employee.id, p_start_date, p_end_date
    );
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.calculate_comprehensive_payroll(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_comprehensive_salary_slip(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_employee_financial_summary(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_bulk_attendance_rules(DATE, DATE) TO authenticated;