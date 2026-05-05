-- Comprehensive Payroll Calculation with All Attendance Rules
-- Includes: Sandwich Rule, Late Penalties, Work Hours, PF, Loans, Security Deposits

CREATE OR REPLACE FUNCTION public.calculate_payroll_to_date(p_payroll_period_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_period RECORD;
  v_employee RECORD;
  v_contract RECORD;
  v_shift RECORD;
  v_work_week RECORD;
  v_total_days INTEGER;
  v_basic_salary NUMERIC(15,2);
  v_daily_salary NUMERIC(15,2);
  v_hourly_rate NUMERIC(15,2);
  v_calculated_gross NUMERIC(15,2);
  v_total_deductions NUMERIC(15,2) := 0;
  v_calculated_net NUMERIC(15,2);
  v_present_days DECIMAL(10,2) := 0;
  v_sandwich_penalty NUMERIC(15,2) := 0;
  v_late_penalty NUMERIC(15,2) := 0;
  v_absent_penalty NUMERIC(15,2) := 0;
  v_pf_deduction NUMERIC(15,2) := 0;
  v_loan_deduction NUMERIC(15,2) := 0;
  v_security_deposit_deduction NUMERIC(15,2) := 0;
BEGIN
  -- Get period details
  SELECT * INTO v_period FROM public.payroll_periods WHERE id = p_payroll_period_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payroll period not found'; END IF;
  
  v_total_days := EXTRACT(DAY FROM (DATE_TRUNC('MONTH', v_period.start_date::date) + INTERVAL '1 MONTH - 1 DAY'));

  -- Process each active employee
  FOR v_employee IN
    SELECT e.id, e.employee_code, e.user_id FROM public.employees e
    WHERE e.is_active = true AND e.is_deleted = false
      AND EXISTS (SELECT 1 FROM public.contracts c WHERE c.employee_id = e.id AND c.status = 'active')
  LOOP
    -- Reset variables for each employee
    v_total_deductions := 0; v_present_days := 0; v_sandwich_penalty := 0;
    v_late_penalty := 0; v_absent_penalty := 0; v_pf_deduction := 0;
    v_loan_deduction := 0; v_security_deposit_deduction := 0;
    
    -- Get employee contract, shift, and work week details
    SELECT 
      c.basic_salary, c.id as contract_id,
      COALESCE(s.start_time, '09:30:00'::TIME) as shift_start,
      COALESCE(s.end_time, '18:00:00'::TIME) as shift_end,
      COALESCE(s.break_duration, 30) as break_minutes,
      COALESCE(ww.monday, false) as monday,
      COALESCE(ww.tuesday, false) as tuesday,
      COALESCE(ww.wednesday, false) as wednesday,
      COALESCE(ww.thursday, false) as thursday,
      COALESCE(ww.friday, false) as friday,
      COALESCE(ww.saturday, false) as saturday,
      COALESCE(ww.sunday, false) as sunday
    INTO v_contract
    FROM public.contracts c
    LEFT JOIN public.employee_shifts es ON es.employee_id = c.employee_id AND es.is_active = true
    LEFT JOIN public.work_weeks ww ON es.work_week_id = ww.id
    LEFT JOIN public.shifts s ON es.shift_id = s.id
    WHERE c.employee_id = v_employee.id AND c.status = 'active' AND c.is_active = true
    ORDER BY c.created_at DESC LIMIT 1;
    
    IF NOT FOUND OR v_contract.basic_salary <= 0 THEN CONTINUE; END IF;
    
    -- Get basic salary from employee_salary_components, fallback to contract
    SELECT COALESCE(SUM(CASE WHEN sc.component_type = 'earning' THEN esc.value ELSE 0 END), v_contract.basic_salary)
    INTO v_basic_salary
    FROM public.employee_salary_components esc
    JOIN public.salary_components sc ON esc.salary_component_id = sc.id
    WHERE esc.employee_id = v_employee.id
      AND sc.component_type = 'earning'
      AND esc.is_active = true
      AND (esc.effective_to IS NULL OR esc.effective_to >= CURRENT_DATE)
      AND esc.effective_from <= CURRENT_DATE;
    
    v_daily_salary := v_basic_salary / v_total_days;
    v_hourly_rate := v_daily_salary / 8.0;

    -- Calculate attendance + leave based salary with precise work hours
    WITH daily_attendance AS (
      SELECT 
        ar.attendance_date,
        ar.check_in,
        ar.check_out,
        ar.status,
        CASE 
          WHEN ar.check_in IS NOT NULL AND ar.check_out IS NOT NULL THEN
            -- Calculate work hours: total time - break time
            GREATEST(0, EXTRACT(EPOCH FROM (ar.check_out - ar.check_in))/3600 - (v_contract.break_minutes/60.0))
          ELSE 0
        END as actual_work_hours,
        CASE 
          WHEN ar.check_in IS NOT NULL THEN
            -- Calculate late minutes based on shift start
            GREATEST(0, EXTRACT(EPOCH FROM (ar.check_in::TIME - v_contract.shift_start))/60 - 5) -- 5 min grace
          ELSE 0
        END as late_minutes
      FROM public.attendance_records ar
      WHERE ar.user_profile_id = v_employee.user_id
        AND ar.attendance_date BETWEEN v_period.start_date AND v_period.end_date
        AND ar.is_active = true
    ),
    daily_leaves AS (
      SELECT 
        generate_series(lr.start_date, lr.end_date, '1 day'::interval)::date as leave_date,
        CASE 
          WHEN lr.half_day_type IS NOT NULL THEN 0.5
          ELSE 1.0
        END as leave_days,
        CASE 
          WHEN COALESCE(cl.salary_payable, lt.salary_payable, true) = true THEN 'paid'
          ELSE 'unpaid'
        END as leave_type
      FROM public.leave_requests lr
      JOIN public.leave_types lt ON lr.leave_type_id = lt.id
      LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
      LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
      WHERE lr.employee_id = v_employee.id
        AND lr.status = 'approved'
        AND lr.start_date <= v_period.end_date
        AND lr.end_date >= v_period.start_date
        AND lr.is_active = true
    ),
    combined_summary AS (
      SELECT COALESCE(SUM(
        CASE 
          -- Attendance days
          WHEN da.actual_work_hours >= 8 THEN 1.0  -- Full day
          WHEN da.actual_work_hours >= 4 THEN 0.5  -- Half day
          WHEN da.actual_work_hours > 0 THEN da.actual_work_hours / 8.0  -- Proportional
          WHEN da.status = 'half_day' THEN 0.5
          WHEN da.status = 'present' THEN 1.0
          ELSE 0
        END
      ), 0) +
      -- Add paid leave days
      COALESCE(SUM(
        CASE 
          WHEN dl.leave_type = 'paid' AND dl.leave_date BETWEEN v_period.start_date AND v_period.end_date
            AND NOT EXISTS (
              SELECT 1 FROM daily_attendance da2 WHERE da2.attendance_date = dl.leave_date
            ) THEN dl.leave_days
          ELSE 0
        END
      ), 0) as total_payable_days
      FROM daily_attendance da
      FULL OUTER JOIN daily_leaves dl ON da.attendance_date = dl.leave_date
    )
    SELECT total_payable_days INTO v_present_days FROM combined_summary;
    
    -- Sandwich rule penalties are now integrated into absent_penalty calculation
    v_sandwich_penalty := 0;
    
    -- Calculate late arrival penalties (3 consecutive = half day)
    SELECT COALESCE(SUM(
      CASE WHEN penalty_type = 'half_day' THEN v_daily_salary * 0.5 ELSE 0 END
    ), 0) INTO v_late_penalty
    FROM public.employee_late_tracking
    WHERE employee_id = v_employee.id
      AND attendance_date BETWEEN v_period.start_date AND v_period.end_date
      AND penalty_applied = true;
    
    -- Calculate absent day penalties with sandwich rule logic
    WITH daily_status AS (
      SELECT 
        cd.calendar_date,
        CASE 
          WHEN EXISTS (
            SELECT 1 FROM public.attendance_records ar
            WHERE ar.user_profile_id = v_employee.user_id AND ar.attendance_date = cd.calendar_date
          ) THEN 'present'
          WHEN EXISTS (
            SELECT 1 FROM public.leave_requests lr
            JOIN public.leave_types lt ON lr.leave_type_id = lt.id
            LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
            LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
            WHERE lr.employee_id = v_employee.id AND lr.status = 'approved'
              AND cd.calendar_date BETWEEN lr.start_date AND lr.end_date
              AND COALESCE(cl.salary_payable, lt.salary_payable, true) = true
          ) THEN 'paid_leave'
          WHEN EXISTS (
            SELECT 1 FROM public.leave_requests lr
            JOIN public.leave_types lt ON lr.leave_type_id = lt.id
            LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
            LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
            WHERE lr.employee_id = v_employee.id AND lr.status = 'approved'
              AND cd.calendar_date BETWEEN lr.start_date AND lr.end_date
              AND COALESCE(cl.salary_payable, lt.salary_payable, true) = false
          ) THEN 'unpaid_leave'
          WHEN EXISTS (
            SELECT 1 FROM public.contract_holidays ch
            JOIN public.holidays h ON ch.holiday_id = h.id
            WHERE ch.contract_id = v_contract.contract_id 
              AND cd.calendar_date BETWEEN h.start_date AND h.end_date
          ) THEN 'holiday'
          WHEN CASE EXTRACT(DOW FROM cd.calendar_date)
            WHEN 1 THEN v_contract.monday
            WHEN 2 THEN v_contract.tuesday
            WHEN 3 THEN v_contract.wednesday
            WHEN 4 THEN v_contract.thursday
            WHEN 5 THEN v_contract.friday
            WHEN 6 THEN v_contract.saturday
            WHEN 0 THEN v_contract.sunday
          END = false THEN 'week_off'
          ELSE 'absent'
        END as day_status
      FROM (
        SELECT generate_series(v_period.start_date, LEAST(v_period.end_date, CURRENT_DATE), '1 day'::interval)::date as calendar_date
      ) cd
    ),
    sandwich_penalties AS (
      SELECT 
        ds1.calendar_date,
        ds1.day_status,
        LAG(ds1.day_status) OVER (ORDER BY ds1.calendar_date) as prev_status,
        LEAD(ds1.day_status) OVER (ORDER BY ds1.calendar_date) as next_status,
        CASE 
          -- Sandwich rule: Absent + Off + Absent = All 3 days get double penalty
          WHEN LAG(ds1.day_status) OVER (ORDER BY ds1.calendar_date) = 'absent'
            AND ds1.day_status IN ('week_off', 'holiday')
            AND LEAD(ds1.day_status) OVER (ORDER BY ds1.calendar_date) = 'absent'
          THEN 2 -- Double penalty for off day in sandwich (no info provided)
          -- Sandwich rule: Paid + Off + Unpaid = Off day gets single penalty
          WHEN LAG(ds1.day_status) OVER (ORDER BY ds1.calendar_date) = 'paid_leave'
            AND ds1.day_status IN ('week_off', 'holiday')
            AND LEAD(ds1.day_status) OVER (ORDER BY ds1.calendar_date) = 'unpaid_leave'
          THEN 1 -- Single penalty for off day in sandwich
          -- Sandwich rule: Unpaid + Off + Unpaid = All 3 days get single penalty
          WHEN LAG(ds1.day_status) OVER (ORDER BY ds1.calendar_date) = 'unpaid_leave'
            AND ds1.day_status IN ('week_off', 'holiday')
            AND LEAD(ds1.day_status) OVER (ORDER BY ds1.calendar_date) = 'unpaid_leave'
          THEN 1 -- Single penalty for off day in sandwich
          -- Regular absent day penalty (no info provided)
          WHEN ds1.day_status = 'absent' THEN 2 -- Double penalty for no info
          -- Regular unpaid leave penalty
          WHEN ds1.day_status = 'unpaid_leave' THEN 1 -- Single penalty
          ELSE 0
        END as penalty_multiplier
      FROM daily_status ds1
    ),
    absent_days AS (
      SELECT SUM(penalty_multiplier) as total_penalty_days
      FROM sandwich_penalties
    ),
    unpaid_leave_deduction AS (
      SELECT COALESCE(SUM(
        CASE 
          WHEN lr.half_day_type IS NOT NULL THEN 0.5
          ELSE lr.total_days
        END
      ), 0) * v_daily_salary as unpaid_amount
      FROM public.leave_requests lr
      JOIN public.leave_types lt ON lr.leave_type_id = lt.id
      LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
      LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
      WHERE lr.employee_id = v_employee.id
        AND lr.status = 'approved'
        AND lr.start_date <= v_period.end_date
        AND lr.end_date >= v_period.start_date
        AND lr.is_active = true
        AND COALESCE(cl.salary_payable, lt.salary_payable, true) = false
    )
    SELECT (total_penalty_days * v_daily_salary) + unpaid_amount INTO v_absent_penalty 
    FROM absent_days, unpaid_leave_deduction;
    
    -- Process PF deduction: Check salary component first, then default to 12%
    SELECT COALESCE(esc.value, 0) INTO v_pf_deduction
    FROM public.employee_salary_components esc
    JOIN public.salary_components sc ON esc.salary_component_id = sc.id
    WHERE esc.employee_id = v_employee.id
      AND sc.code = 'PF'
      AND sc.component_type = 'deduction'
      AND esc.is_active = true
      AND (esc.effective_to IS NULL OR esc.effective_to >= CURRENT_DATE)
      AND esc.effective_from <= CURRENT_DATE;
    
    -- If PF component found, treat as percentage and calculate amount
    IF v_pf_deduction > 0 THEN
      v_pf_deduction := v_basic_salary * (v_pf_deduction / 100);
    ELSE
      -- If no PF component found, calculate 12% of full basic salary
      v_pf_deduction := v_basic_salary * 0.12;
    END IF;
    
    -- Process PF deduction if amount > 0
    IF v_pf_deduction > 0 THEN
      -- Insert PF transaction
      INSERT INTO public.pf_transactions (
        pf_account_id, payroll_period_id, employee_contribution, 
        employer_contribution, basic_salary, transaction_date
      )
      SELECT pfa.id, p_payroll_period_id, v_pf_deduction, v_pf_deduction, v_basic_salary, CURRENT_DATE
      FROM public.employee_pf_accounts pfa 
      WHERE pfa.employee_id = v_employee.id AND pfa.is_active = true;
      
      -- Update PF account balance
      UPDATE public.employee_pf_accounts
      SET total_employee_contribution = total_employee_contribution + v_pf_deduction,
          total_employer_contribution = total_employer_contribution + v_pf_deduction,
          updated_at = CURRENT_TIMESTAMP
      WHERE employee_id = v_employee.id AND is_active = true;
      
      -- Insert PF component into payroll_components
      INSERT INTO public.payroll_components (
        payroll_id, salary_component_id, amount
      )
      SELECT 
        (SELECT id FROM public.payroll WHERE payroll_period_id = p_payroll_period_id AND employee_id = v_employee.id),
        sc.id,
        v_pf_deduction
      FROM public.salary_components sc
      WHERE sc.code = 'PF' AND sc.component_type = 'deduction'
      ON CONFLICT (payroll_id, salary_component_id) DO UPDATE SET amount = EXCLUDED.amount;
    ELSE
      v_pf_deduction := 0;
    END IF;
    
    -- Process loan deductions
    FOR v_loan_deduction IN
      SELECT monthly_deduction FROM public.employee_loans
      WHERE employee_id = v_employee.id AND status = 'active' AND total_paid < loan_amount
    LOOP
      -- Insert loan transaction
      INSERT INTO public.loan_transactions (
        loan_id, payroll_period_id, transaction_type, amount, transaction_date
      )
      SELECT id, p_payroll_period_id, 'deduction', monthly_deduction, CURRENT_DATE
      FROM public.employee_loans
      WHERE employee_id = v_employee.id AND status = 'active' AND total_paid < loan_amount;
      
      -- Update loan balance
      UPDATE public.employee_loans
      SET total_paid = total_paid + monthly_deduction,
          status = CASE WHEN (total_paid + monthly_deduction) >= loan_amount THEN 'completed' ELSE 'active' END,
          completion_date = CASE WHEN (total_paid + monthly_deduction) >= loan_amount THEN CURRENT_DATE ELSE completion_date END,
          updated_at = CURRENT_TIMESTAMP
      WHERE employee_id = v_employee.id AND status = 'active' AND total_paid < loan_amount;
    END LOOP;
    
    -- Get total loan deductions
    SELECT COALESCE(SUM(monthly_deduction), 0) INTO v_loan_deduction
    FROM public.employee_loans 
    WHERE employee_id = v_employee.id AND status = 'active' AND total_paid < loan_amount;
    
    -- Process security deposit deductions (first 8 months)
    FOR v_security_deposit_deduction IN
      SELECT monthly_deduction FROM public.employee_security_deposits
      WHERE employee_id = v_employee.id AND status = 'active' AND total_collected < deposit_amount
    LOOP
      -- Insert security deposit transaction
      INSERT INTO public.security_deposit_transactions (
        security_deposit_id, payroll_period_id, transaction_type, amount, transaction_date
      )
      SELECT id, p_payroll_period_id, 'deduction', monthly_deduction, CURRENT_DATE
      FROM public.employee_security_deposits
      WHERE employee_id = v_employee.id AND status = 'active' AND total_collected < deposit_amount;
      
      -- Update security deposit balance
      UPDATE public.employee_security_deposits
      SET total_collected = total_collected + monthly_deduction,
          status = CASE WHEN (total_collected + monthly_deduction) >= deposit_amount THEN 'completed' ELSE 'active' END,
          completion_date = CASE WHEN (total_collected + monthly_deduction) >= deposit_amount THEN CURRENT_DATE ELSE completion_date END,
          updated_at = CURRENT_TIMESTAMP
      WHERE employee_id = v_employee.id AND status = 'active' AND total_collected < deposit_amount;
    END LOOP;
    
    -- Get total security deposit deductions
    SELECT COALESCE(SUM(monthly_deduction), 0) INTO v_security_deposit_deduction
    FROM public.employee_security_deposits 
    WHERE employee_id = v_employee.id AND status = 'active' AND total_collected < deposit_amount;
    
    -- Calculate totals
    v_total_deductions := v_sandwich_penalty + v_late_penalty + v_absent_penalty + 
                         v_pf_deduction + v_loan_deduction + v_security_deposit_deduction;
    v_calculated_gross := GREATEST(0.01, v_daily_salary * v_present_days);
    v_calculated_net := GREATEST(0, v_calculated_gross - v_total_deductions);
    
    -- Insert/Update payroll record
    INSERT INTO public.payroll (
      payroll_period_id, employee_id, basic_salary, gross_salary,
      total_deductions, net_salary, working_days, present_days, status
    ) VALUES (
      p_payroll_period_id, v_employee.id, v_basic_salary, v_calculated_gross,
      v_total_deductions, v_calculated_net, v_total_days, GREATEST(0, v_present_days::INTEGER), 'draft'
    )
    ON CONFLICT (payroll_period_id, employee_id)
    DO UPDATE SET
      basic_salary = EXCLUDED.basic_salary,
      gross_salary = EXCLUDED.gross_salary,
      total_deductions = EXCLUDED.total_deductions,
      net_salary = EXCLUDED.net_salary,
      present_days = EXCLUDED.present_days,
      updated_at = CURRENT_TIMESTAMP;
  
  END LOOP;
  
  RETURN TRUE;
END;
$$;