-- Update payroll calculation to include leave requests, attendance records and manual adjustments
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
  v_manual_adjustments NUMERIC(15,2);
  v_calculated_net NUMERIC(15,2);
  v_present_days DECIMAL(10,2);
  v_leave_days INTEGER;
  v_unpaid_leave_days INTEGER;
  v_leave_deduction NUMERIC(15,2);
  v_absent_work_days INTEGER;
  v_extra_days INTEGER;
  v_paid_leave_days INTEGER;
  v_total_work_days_in_month INTEGER;
  v_shift_hours DECIMAL(5,2) := 8.0;
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
    JOIN public.contracts c ON esc.contract_id = c.id
    WHERE esc.employee_id = v_employee.id
      AND esc.is_active = true
      AND esc.is_deleted = false
       AND c.status = 'active'
  AND c.is_active = true
  AND c.is_deleted = false;

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

    -- Calculate total work days in full month based on employee's work week
    WITH full_month_days AS (
      SELECT generate_series(
        v_period.start_date::date,
        v_period.end_date::date,
        '1 day'::interval
      )::date as work_date
    ),
    work_days_till_today AS (
      SELECT generate_series(
        v_period.start_date::date,
        LEAST(v_period.end_date::date, CURRENT_DATE),
        '1 day'::interval
      )::date as work_date
    ),
    employee_work_week AS (
      SELECT ww.* FROM public.work_weeks ww
      JOIN public.employee_shifts es ON es.work_week_id = ww.id
      WHERE es.employee_id = v_employee.id AND es.is_active = true
      LIMIT 1
    ),
    total_work_days_in_month AS (
      SELECT COUNT(*) as total_work_days
      FROM full_month_days fmd, employee_work_week eww
      WHERE (
        (EXTRACT(DOW FROM fmd.work_date) = 1 AND eww.monday = true) OR
        (EXTRACT(DOW FROM fmd.work_date) = 2 AND eww.tuesday = true) OR
        (EXTRACT(DOW FROM fmd.work_date) = 3 AND eww.wednesday = true) OR
        (EXTRACT(DOW FROM fmd.work_date) = 4 AND eww.thursday = true) OR
        (EXTRACT(DOW FROM fmd.work_date) = 5 AND eww.friday = true) OR
        (EXTRACT(DOW FROM fmd.work_date) = 6 AND eww.saturday = true) OR
        (EXTRACT(DOW FROM fmd.work_date) = 0 AND eww.sunday = true)
      )
    ),
    expected_work_days_till_today AS (
      SELECT COUNT(*) as work_days_till_today
      FROM work_days_till_today wdtt, employee_work_week eww
      WHERE (
        (EXTRACT(DOW FROM wdtt.work_date) = 1 AND eww.monday = true) OR
        (EXTRACT(DOW FROM wdtt.work_date) = 2 AND eww.tuesday = true) OR
        (EXTRACT(DOW FROM wdtt.work_date) = 3 AND eww.wednesday = true) OR
        (EXTRACT(DOW FROM wdtt.work_date) = 4 AND eww.thursday = true) OR
        (EXTRACT(DOW FROM wdtt.work_date) = 5 AND eww.friday = true) OR
        (EXTRACT(DOW FROM wdtt.work_date) = 6 AND eww.saturday = true) OR
        (EXTRACT(DOW FROM wdtt.work_date) = 0 AND eww.sunday = true)
      )
    )
    SELECT 
      COALESCE(twdim.total_work_days, v_total_days),
      COALESCE(ewdtt.work_days_till_today, v_total_days)
    INTO v_total_work_days_in_month, v_current_date
    FROM total_work_days_in_month twdim, expected_work_days_till_today ewdtt;

    -- Get employee's working hours (shift hours - break time)
    SELECT 
      COALESCE(
        (EXTRACT(EPOCH FROM (s.end_time - s.start_time)) / 3600) - (COALESCE(s.break_duration, 0) / 60.0), 
        8.0
      )
    INTO v_shift_hours
    FROM public.employee_shifts es
    JOIN public.shifts s ON es.shift_id = s.id
    WHERE es.employee_id = v_employee.id
      AND es.is_active = true
      AND es.is_deleted = false
    ORDER BY es.created_at DESC
    LIMIT 1;
    
    IF v_shift_hours IS NULL OR v_shift_hours <= 0 THEN
        v_shift_hours := 8.0;
    END IF;
    
    -- Calculate paid days including attendance + off days + holidays + leaves
    WITH attendance_fraction AS (
      SELECT COALESCE(SUM(
        CASE 
          WHEN ar.total_hours IS NOT NULL AND ar.total_hours > 0 THEN 
            LEAST(ar.total_hours / v_shift_hours, 1.0)
          WHEN ar.status = 'half_day' THEN 0.5
          WHEN ar.status = 'present' OR ar.status IS NULL THEN 1.0
          ELSE 1.0
        END
      ), 0) as days
      FROM public.attendance_records ar
      JOIN public.employees e ON e.user_id = ar.user_profile_id
      WHERE e.id = v_employee.id
        AND ar.attendance_date >= v_period.start_date::date
        AND ar.attendance_date <= LEAST(v_period.end_date::date, CURRENT_DATE)
        AND ar.is_active = true
        AND ar.is_deleted = false
    ),
    off_days_automatic AS (
      -- Count off days (non-work days) as automatically paid
      SELECT 
        COUNT(*) as days
      FROM generate_series(
        v_period.start_date::date,
        LEAST(v_period.end_date::date, CURRENT_DATE),
        '1 day'::interval
      ) AS date_series(off_date)
      JOIN public.employee_shifts es ON es.employee_id = v_employee.id AND es.is_active = true
      JOIN public.work_weeks ww ON es.work_week_id = ww.id
      WHERE NOT (
        (EXTRACT(DOW FROM off_date) = 1 AND ww.monday = true) OR
        (EXTRACT(DOW FROM off_date) = 2 AND ww.tuesday = true) OR
        (EXTRACT(DOW FROM off_date) = 3 AND ww.wednesday = true) OR
        (EXTRACT(DOW FROM off_date) = 4 AND ww.thursday = true) OR
        (EXTRACT(DOW FROM off_date) = 5 AND ww.friday = true) OR
        (EXTRACT(DOW FROM off_date) = 6 AND ww.saturday = true) OR
        (EXTRACT(DOW FROM off_date) = 0 AND ww.sunday = true)
      )
    ),
    contract_holiday_days AS (
      SELECT COALESCE(COUNT(*), 0) as days
      FROM public.contract_holidays ch
      JOIN public.holidays h ON ch.holiday_id = h.id
      JOIN public.contracts c ON ch.contract_id = c.id
      WHERE c.employee_id = v_employee.id
        AND c.status = 'active'
        AND c.is_active = true
        AND ch.is_applicable = true
        AND ch.is_active = true
        AND ch.is_deleted = false
        AND h.is_active = true
        AND h.is_deleted = false
        AND h.start_date >= v_period.start_date::date
        AND h.end_date <= LEAST(v_period.end_date::date, CURRENT_DATE)
        AND EXTRACT(YEAR FROM h.start_date) = EXTRACT(YEAR FROM v_period.start_date::date)
    )
    SELECT 
      COALESCE(a.days, 0) + COALESCE(off.days, 0) + COALESCE(h.days, 0)
    INTO v_present_days
    FROM attendance_fraction a, off_days_automatic off, contract_holiday_days h;

    -- Calculate extra days (attendance on non-work days)
    v_extra_days := GREATEST(0, v_present_days - v_current_date);

    -- Get approved leave days for the period
    SELECT 
      COALESCE(SUM(lr.total_days), 0)
    INTO v_leave_days
    FROM public.leave_requests lr
    WHERE lr.employee_id = v_employee.id
      AND lr.status = 'approved'
      AND lr.start_date <= LEAST(v_period.end_date::date, CURRENT_DATE)
      AND lr.end_date >= v_period.start_date::date
      AND lr.is_active = true
      AND lr.is_deleted = false;

    -- Calculate unpaid leave days (where salary_payable = false) - simplified calculation
    SELECT 
      COALESCE(SUM(lr.total_days), 0)
    INTO v_unpaid_leave_days
    FROM public.leave_requests lr
    JOIN public.leave_types lt ON lr.leave_type_id = lt.id
    LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
    LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
    WHERE lr.employee_id = v_employee.id
      AND lr.status = 'approved'
      AND lr.start_date <= LEAST(v_period.end_date::date, CURRENT_DATE)
      AND lr.end_date >= v_period.start_date::date
      AND lr.is_active = true
      AND lr.is_deleted = false
      AND (
        (cl.salary_payable = false) OR 
        (cl.id IS NULL AND lt.salary_payable = false)
      );

    -- Calculate daily salary based on total days in month (30/31)
    v_daily_salary := v_earnings / v_total_days;
    
    -- Calculate leave deduction for unpaid leaves
    v_leave_deduction := v_daily_salary * v_unpaid_leave_days;
    
    -- Get paid leave days (where salary_payable = true) - simplified calculation
    SELECT 
      COALESCE(SUM(lr.total_days), 0)
    INTO v_paid_leave_days
    FROM public.leave_requests lr
    JOIN public.leave_types lt ON lr.leave_type_id = lt.id
    LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
    LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
    WHERE lr.employee_id = v_employee.id
      AND lr.status = 'approved'
      AND lr.start_date <= LEAST(v_period.end_date::date, CURRENT_DATE)
      AND lr.end_date >= v_period.start_date::date
      AND lr.is_active = true
      AND lr.is_deleted = false
      AND (
        (cl.salary_payable = true) OR 
        (cl.id IS NULL AND lt.salary_payable = true)
      );
    
    -- Calculate absent work days (missing from expected work days, excluding paid leaves)
    v_absent_work_days := GREATEST(0, v_current_date - v_present_days - v_paid_leave_days);
    
    -- Calculate salary: pay for attendance + paid leaves, deduct unpaid leaves
    -- Gross salary = (attendance days + paid leave days) * daily rate
    v_calculated_gross := v_daily_salary * (v_present_days + v_paid_leave_days);
    
    -- Total deductions = regular deductions + unpaid leave deduction
    v_calculated_deductions := (v_deductions / v_total_days) * (v_present_days + v_paid_leave_days) + v_leave_deduction;
    
    -- Get manual adjustments for this employee and period
    SELECT COALESCE(SUM(
      CASE 
        WHEN adjustment_type = 'addition' THEN amount
        WHEN adjustment_type = 'deduction' THEN -amount
        ELSE 0
      END
    ), 0) INTO v_manual_adjustments
    FROM public.payroll_adjustments
    WHERE payroll_period_id = p_payroll_period_id
      AND employee_id = v_employee.id
      AND is_active = true
      AND is_deleted = false;
    
    -- Calculate net salary including manual adjustments
    v_calculated_net := v_calculated_gross - v_calculated_deductions + v_manual_adjustments;

    -- Ensure minimum values to satisfy constraints
    v_calculated_gross := GREATEST(v_calculated_gross, 0.01);
    v_calculated_net := GREATEST(v_calculated_net, 0);
    
    -- Use total days in month for working_days to show present/total format
    v_current_date := v_total_days;

    -- v_current_date now represents total attendance record days
    -- v_present_days represents actual present days

    -- Insert or update payroll record
    INSERT INTO public.payroll (
      payroll_period_id,
      employee_id,
      basic_salary,
      gross_salary,
      total_deductions,
      manual_adjustment_total,
      net_salary,
      working_days,
      present_days,
      leave_days,
      overtime_hours,
      overtime_amount,
      status
    ) VALUES (
      p_payroll_period_id,
      v_employee.id,
      v_earnings,
      v_calculated_gross,
      v_calculated_deductions,
      v_manual_adjustments,
      v_calculated_net,
      v_total_days,
      v_present_days,
      v_leave_days::INTEGER,
      0,
      0,
      'draft'
    )
    ON CONFLICT (payroll_period_id, employee_id)
    DO UPDATE SET
      basic_salary = v_earnings,
      gross_salary = v_calculated_gross,
      total_deductions = v_calculated_deductions,
      manual_adjustment_total = v_manual_adjustments,
      net_salary = v_calculated_net,
      working_days = v_total_days,
      present_days = v_present_days,
      leave_days = v_leave_days::INTEGER,
      updated_at = CURRENT_TIMESTAMP;

  END LOOP;

  RETURN TRUE;
END;
$$;

-- Create function to recalculate a single payroll record with leave and attendance data
CREATE OR REPLACE FUNCTION recalculate_single_payroll(p_payroll_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_payroll_record RECORD;
    v_period RECORD;
    v_total_earnings DECIMAL(15,2) := 0;
    v_total_deductions DECIMAL(15,2) := 0;
    v_gross_salary DECIMAL(15,2) := 0;
    v_net_salary DECIMAL(15,2) := 0;
    v_manual_adjustment DECIMAL(15,2) := 0;
    v_leave_days INTEGER := 0;
    v_unpaid_leave_days INTEGER := 0;
    v_leave_deduction DECIMAL(15,2) := 0;
    v_daily_salary DECIMAL(15,2) := 0;
    v_total_days INTEGER;
    v_attendance_days DECIMAL(10,2) := 0;
    v_shift_hours DECIMAL(5,2) := 8.0;
BEGIN
    -- Get payroll record with period info
    SELECT p.*, pp.start_date, pp.end_date INTO v_payroll_record
    FROM payroll p
    JOIN payroll_periods pp ON p.payroll_period_id = pp.id
    WHERE p.id = p_payroll_id AND p.is_active = true AND p.is_deleted = false;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payroll record not found';
    END IF;
    
    -- Get total days in the period (calendar days)
    v_total_days := EXTRACT(DAY FROM (DATE_TRUNC('MONTH', v_payroll_record.start_date::date) + INTERVAL '1 MONTH - 1 DAY'));
    v_daily_salary := v_payroll_record.basic_salary / v_total_days;
    
    -- Get employee's working hours (shift hours - break time)
    SELECT 
      COALESCE(
        (EXTRACT(EPOCH FROM (s.end_time - s.start_time)) / 3600) - (COALESCE(s.break_duration, 0) / 60.0), 
        8.0
      )
    INTO v_shift_hours
    FROM public.employee_shifts es
    JOIN public.shifts s ON es.shift_id = s.id
    WHERE es.employee_id = v_payroll_record.employee_id
      AND es.is_active = true
      AND es.is_deleted = false
    ORDER BY es.created_at DESC
    LIMIT 1;
    
    -- Default to 8 hours if no shift found
    IF v_shift_hours IS NULL OR v_shift_hours <= 0 THEN
        v_shift_hours := 8.0;
    END IF;
    
    -- Calculate salary: work days (attendance) + off days (automatic) + holidays + leaves
    WITH attendance_fraction AS (
      SELECT COALESCE(SUM(
        CASE 
          WHEN ar.total_hours IS NOT NULL AND ar.total_hours > 0 THEN 
            LEAST(ar.total_hours / v_shift_hours, 1.0)
          WHEN ar.status = 'half_day' THEN 0.5
          WHEN ar.status = 'present' OR ar.status IS NULL THEN 1.0
          ELSE 1.0
        END
      ), 0) as days
      FROM public.attendance_records ar
      JOIN public.employees e ON e.user_id = ar.user_profile_id
      WHERE e.id = v_payroll_record.employee_id
        AND ar.attendance_date >= v_payroll_record.start_date::date
        AND ar.attendance_date <= v_payroll_record.end_date::date
        AND ar.is_active = true
        AND ar.is_deleted = false
    ),
    off_days_automatic AS (
      -- Count off days (non-work days) as automatically paid
      SELECT 
        COUNT(*) as days
      FROM generate_series(
        v_payroll_record.start_date::date,
        v_payroll_record.end_date::date,
        '1 day'::interval
      ) AS date_series(off_date)
      JOIN public.employee_shifts es ON es.employee_id = v_payroll_record.employee_id AND es.is_active = true
      JOIN public.work_weeks ww ON es.work_week_id = ww.id
      WHERE NOT (
        (EXTRACT(DOW FROM off_date) = 1 AND ww.monday = true) OR
        (EXTRACT(DOW FROM off_date) = 2 AND ww.tuesday = true) OR
        (EXTRACT(DOW FROM off_date) = 3 AND ww.wednesday = true) OR
        (EXTRACT(DOW FROM off_date) = 4 AND ww.thursday = true) OR
        (EXTRACT(DOW FROM off_date) = 5 AND ww.friday = true) OR
        (EXTRACT(DOW FROM off_date) = 6 AND ww.saturday = true) OR
        (EXTRACT(DOW FROM off_date) = 0 AND ww.sunday = true)
      )
    ),
    leave_fraction AS (
      SELECT COALESCE(SUM(
        CASE 
          WHEN (cl.salary_payable = true) OR (cl.id IS NULL AND lt.salary_payable = true) THEN 
            CASE
              WHEN lr.leave_duration = 'half_day' THEN 0.5
              WHEN lr.leave_duration = 'full_day' OR lr.leave_duration IS NULL THEN lr.total_days
              ELSE lr.total_days
            END
          ELSE 0
        END
      ), 0) as days
      FROM public.leave_requests lr
      JOIN public.leave_types lt ON lr.leave_type_id = lt.id
      LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
      LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
      WHERE lr.employee_id = v_payroll_record.employee_id
        AND lr.status = 'approved'
        AND lr.start_date <= v_payroll_record.end_date::date
        AND lr.end_date >= v_payroll_record.start_date::date
        AND lr.is_active = true
        AND lr.is_deleted = false
    ),
    contract_holiday_days AS (
      SELECT COALESCE(COUNT(*), 0) as days
      FROM public.contract_holidays ch
      JOIN public.holidays h ON ch.holiday_id = h.id
      JOIN public.contracts c ON ch.contract_id = c.id
      WHERE c.employee_id = v_payroll_record.employee_id
        AND c.status = 'active'
        AND c.is_active = true
        AND ch.is_applicable = true
        AND ch.is_active = true
        AND ch.is_deleted = false
        AND h.is_active = true
        AND h.is_deleted = false
        AND h.start_date >= v_payroll_record.start_date::date
        AND h.end_date <= v_payroll_record.end_date::date
        AND EXTRACT(YEAR FROM h.start_date) = EXTRACT(YEAR FROM v_payroll_record.start_date::date)
    ),
    attendance_leave_overlap AS (
      -- Subtract leave days that overlap with attendance to avoid double counting
      SELECT COALESCE(SUM(
        CASE 
          WHEN ar.attendance_date IS NOT NULL THEN lr.total_days
          ELSE 0
        END
      ), 0) as overlap_days
      FROM public.leave_requests lr
      JOIN public.leave_types lt ON lr.leave_type_id = lt.id
      LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
      LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
      LEFT JOIN public.attendance_records ar ON ar.attendance_date >= lr.start_date 
        AND ar.attendance_date <= lr.end_date
      LEFT JOIN public.employees e ON e.user_id = ar.user_profile_id AND e.id = lr.employee_id
      WHERE lr.employee_id = v_payroll_record.employee_id
        AND lr.status = 'approved'
        AND lr.start_date <= v_payroll_record.end_date::date
        AND lr.end_date >= v_payroll_record.start_date::date
        AND lr.is_active = true
        AND lr.is_deleted = false
        AND ((cl.salary_payable = true) OR (cl.id IS NULL AND lt.salary_payable = true))
        AND ar.is_active = true
        AND ar.is_deleted = false
    )
    SELECT 
      COALESCE(a.days, 0) + COALESCE(off.days, 0) + COALESCE(l.days, 0) + COALESCE(h.days, 0) - COALESCE(o.overlap_days, 0)
    INTO v_attendance_days
    FROM attendance_fraction a, off_days_automatic off, leave_fraction l, contract_holiday_days h, attendance_leave_overlap o;
    
    -- Calculate total earnings from payroll_components
    SELECT COALESCE(SUM(pc.amount), 0) INTO v_total_earnings
    FROM payroll_components pc
    JOIN salary_components sc ON pc.salary_component_id = sc.id
    WHERE pc.payroll_id = p_payroll_id 
    AND pc.is_active = true 
    AND sc.component_type = 'earning';
    
    -- Calculate total deductions from payroll_components
    SELECT COALESCE(SUM(pc.amount), 0) INTO v_total_deductions
    FROM payroll_components pc
    JOIN salary_components sc ON pc.salary_component_id = sc.id
    WHERE pc.payroll_id = p_payroll_id 
    AND pc.is_active = true 
    AND sc.component_type = 'deduction';
    
    -- Get total leave days (including half days) for the period
    SELECT 
      COALESCE(SUM(lr.total_days), 0)
    INTO v_leave_days
    FROM public.leave_requests lr
    WHERE lr.employee_id = v_payroll_record.employee_id
      AND lr.status = 'approved'
      AND lr.start_date <= v_payroll_record.end_date::date
      AND lr.end_date >= v_payroll_record.start_date::date
      AND lr.is_active = true
      AND lr.is_deleted = false;

    -- Calculate unpaid leave days (where salary_payable = false) including half days
    SELECT 
      COALESCE(SUM(lr.total_days), 0)
    INTO v_unpaid_leave_days
    FROM public.leave_requests lr
    JOIN public.leave_types lt ON lr.leave_type_id = lt.id
    LEFT JOIN public.contracts c ON c.employee_id = lr.employee_id AND c.status = 'active'
    LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
    WHERE lr.employee_id = v_payroll_record.employee_id
      AND lr.status = 'approved'
      AND lr.start_date <= v_payroll_record.end_date::date
      AND lr.end_date >= v_payroll_record.start_date::date
      AND lr.is_active = true
      AND lr.is_deleted = false
      AND (
        (cl.salary_payable = false) OR 
        (cl.id IS NULL AND lt.salary_payable = false)
      );
    
    -- Calculate leave deduction for unpaid leaves
    v_leave_deduction := v_daily_salary * v_unpaid_leave_days;
    
    -- Get manual adjustments total
    SELECT COALESCE(SUM(
      CASE 
        WHEN adjustment_type = 'addition' THEN amount
        WHEN adjustment_type = 'deduction' THEN -amount
        ELSE 0
      END
    ), 0) INTO v_manual_adjustment
    FROM payroll_adjustments
    WHERE payroll_period_id = v_payroll_record.payroll_period_id
      AND employee_id = v_payroll_record.employee_id
      AND is_active = true 
      AND is_deleted = false;
    
    -- Calculate gross salary based on attendance fraction + paid leaves + contract holidays
    IF v_attendance_days = 0 THEN
        v_gross_salary := 0;
        v_total_deductions := 0;
    ELSE
        -- Pay for attendance fraction + paid leaves + contract holidays
        v_gross_salary := (v_daily_salary * v_attendance_days) + v_total_earnings - v_leave_deduction;
        -- Deductions also based on paid days fraction
        v_total_deductions := (v_total_deductions / v_total_days) * v_attendance_days;
    END IF;
    
    -- Calculate net salary (gross - deductions + manual adjustments)
    v_net_salary := v_gross_salary - v_total_deductions + v_manual_adjustment;
    
    -- Ensure net salary is not negative
    IF v_net_salary < 0 THEN
        v_net_salary := 0;
    END IF;
    
    -- Update payroll record
    UPDATE payroll
    SET 
        gross_salary = v_gross_salary,
        total_deductions = v_total_deductions + v_leave_deduction,
        manual_adjustment_total = v_manual_adjustment,
        net_salary = v_net_salary,
        leave_days = v_leave_days,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_payroll_id;
    
END;
$$;