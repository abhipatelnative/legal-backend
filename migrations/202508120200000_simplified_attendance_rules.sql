-- Simplified Attendance Rules (No Settings UI)
-- Hardcoded values for sandwich rule, late penalties, and work hours

-- Update attendance calculation function with hardcoded values
CREATE OR REPLACE FUNCTION public.calculate_simple_attendance(
  p_employee_id UUID,
  p_attendance_date DATE,
  p_check_in TIMESTAMP WITH TIME ZONE,
  p_check_out TIMESTAMP WITH TIME ZONE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_shift_start TIME := '09:30:00';
  v_shift_end TIME := '18:00:00';
  v_grace_period INTEGER := 5; -- 5 minutes grace
  v_late_minutes INTEGER := 0;
  v_actual_work_hours DECIMAL(5,2) := 0;
  v_consecutive_late_count INTEGER := 0;
  v_penalty_type VARCHAR(20) := 'none';
  v_half_day_penalty BOOLEAN := false;
  v_attendance_status VARCHAR(20) := 'present';
  v_result JSONB;
BEGIN
  -- Get employee's shift or use defaults
  SELECT 
    COALESCE(s.start_time, v_shift_start),
    COALESCE(s.end_time, v_shift_end)
  INTO v_shift_start, v_shift_end
  FROM public.employee_shifts es
  LEFT JOIN public.shifts s ON es.shift_id = s.id
  WHERE es.employee_id = p_employee_id AND es.is_active = true
  ORDER BY es.created_at DESC LIMIT 1;
  
  -- Calculate late arrival
  IF p_check_in IS NOT NULL THEN
    v_late_minutes := GREATEST(0, 
      EXTRACT(EPOCH FROM (p_check_in::TIME - v_shift_start)) / 60 - v_grace_period
    );
  END IF;
  
  -- Calculate work hours (subtract 1 hour break)
  IF p_check_in IS NOT NULL AND p_check_out IS NOT NULL THEN
    v_actual_work_hours := EXTRACT(EPOCH FROM (p_check_out - p_check_in)) / 3600;
    v_actual_work_hours := GREATEST(0, v_actual_work_hours - 1.0);
  END IF;
  
  -- Determine status based on work hours
  IF v_actual_work_hours >= 8 THEN
    v_attendance_status := 'present';
  ELSIF v_actual_work_hours >= 4 THEN
    v_attendance_status := 'half_day';
  ELSE
    v_attendance_status := 'absent';
  END IF;
  
  -- Check consecutive late arrivals (3 consecutive = half day penalty)
  IF v_late_minutes > 0 THEN
    SELECT COALESCE(MAX(consecutive_count), 0) + 1
    INTO v_consecutive_late_count
    FROM public.employee_late_tracking
    WHERE employee_id = p_employee_id
      AND attendance_date >= p_attendance_date - INTERVAL '10 days'
      AND attendance_date < p_attendance_date
      AND late_minutes > 0
    ORDER BY attendance_date DESC LIMIT 1;
    
    -- Apply penalty every 3rd consecutive late
    IF v_consecutive_late_count >= 3 AND v_consecutive_late_count % 3 = 0 THEN
      v_penalty_type := 'half_day';
      v_half_day_penalty := true;
      v_attendance_status := 'half_day';
    END IF;
  ELSE
    v_consecutive_late_count := 0;
  END IF;
  
  -- Record late tracking
  IF v_late_minutes > 0 THEN
    INSERT INTO public.employee_late_tracking (
      employee_id, attendance_date, late_minutes, consecutive_count, 
      penalty_applied, penalty_type
    ) VALUES (
      p_employee_id, p_attendance_date, v_late_minutes, v_consecutive_late_count,
      v_half_day_penalty, v_penalty_type
    )
    ON CONFLICT (employee_id, attendance_date)
    DO UPDATE SET
      late_minutes = EXCLUDED.late_minutes,
      consecutive_count = EXCLUDED.consecutive_count,
      penalty_applied = EXCLUDED.penalty_applied,
      penalty_type = EXCLUDED.penalty_type;
  END IF;
  
  v_result := jsonb_build_object(
    'status', v_attendance_status,
    'late_minutes', v_late_minutes,
    'actual_work_hours', v_actual_work_hours,
    'consecutive_late_count', v_consecutive_late_count,
    'half_day_penalty', v_half_day_penalty,
    'penalty_type', v_penalty_type
  );
  
  RETURN v_result;
END;
$$;

-- Simplified sandwich rule function
CREATE OR REPLACE FUNCTION public.apply_simple_sandwich_rule(
  p_employee_id UUID,
  p_start_date DATE,
  p_end_date DATE
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_date DATE;
  v_prev_date DATE;
  v_next_date DATE;
  v_prev_status VARCHAR(50);
  v_curr_status VARCHAR(50);
  v_next_status VARCHAR(50);
  v_daily_salary DECIMAL(15,2);
  v_deduction DECIMAL(15,2) := 0;
  v_work_week RECORD;
  v_is_work_day BOOLEAN;
BEGIN
  -- Get work week
  SELECT ww.* INTO v_work_week
  FROM public.employee_shifts es
  JOIN public.work_weeks ww ON es.work_week_id = ww.id
  WHERE es.employee_id = p_employee_id AND es.is_active = true
  LIMIT 1;
  
  -- Get daily salary
  SELECT (c.basic_salary / 30) INTO v_daily_salary
  FROM public.contracts c
  WHERE c.employee_id = p_employee_id AND c.status = 'active' AND c.is_active = true
  ORDER BY c.created_at DESC LIMIT 1;
  
  -- Loop through dates to find sandwich patterns
  FOR v_date IN SELECT generate_series(p_start_date + 1, p_end_date - 1, '1 day'::interval)::date
  LOOP
    v_prev_date := v_date - 1;
    v_next_date := v_date + 1;
    
    -- Check if current date is a work day
    v_is_work_day := CASE EXTRACT(DOW FROM v_date)
      WHEN 1 THEN v_work_week.monday
      WHEN 2 THEN v_work_week.tuesday
      WHEN 3 THEN v_work_week.wednesday
      WHEN 4 THEN v_work_week.thursday
      WHEN 5 THEN v_work_week.friday
      WHEN 6 THEN v_work_week.saturday
      WHEN 0 THEN v_work_week.sunday
      ELSE false
    END;
    
    CONTINUE WHEN NOT v_is_work_day;
    
    -- Get attendance/leave status for prev, current, and next day
    -- Simplified: Check if it's leave or absent
    SELECT 
      CASE 
        WHEN lr.id IS NOT NULL AND COALESCE(cl.salary_payable, lt.salary_payable, true) THEN 'paid_leave'
        WHEN lr.id IS NOT NULL THEN 'unpaid_leave'
        WHEN ar.status IS NOT NULL THEN ar.status
        ELSE 'absent'
      END
    INTO v_prev_status
    FROM public.attendance_records ar
    FULL OUTER JOIN public.leave_requests lr ON lr.employee_id = p_employee_id 
      AND v_prev_date BETWEEN lr.start_date AND lr.end_date 
      AND lr.status = 'approved'
    LEFT JOIN public.leave_types lt ON lr.leave_type_id = lt.id
    LEFT JOIN public.contracts c ON c.employee_id = p_employee_id AND c.status = 'active'
    LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
    JOIN public.employees e ON e.user_id = ar.user_profile_id
    WHERE e.id = p_employee_id AND ar.attendance_date = v_prev_date;
    
    -- Similar for current and next day (simplified)
    v_curr_status := 'absent'; -- Off day
    
    SELECT 
      CASE 
        WHEN lr.id IS NOT NULL AND COALESCE(cl.salary_payable, lt.salary_payable, true) THEN 'paid_leave'
        WHEN lr.id IS NOT NULL THEN 'unpaid_leave'
        WHEN ar.status IS NOT NULL THEN ar.status
        ELSE 'absent'
      END
    INTO v_next_status
    FROM public.attendance_records ar
    FULL OUTER JOIN public.leave_requests lr ON lr.employee_id = p_employee_id 
      AND v_next_date BETWEEN lr.start_date AND lr.end_date 
      AND lr.status = 'approved'
    LEFT JOIN public.leave_types lt ON lr.leave_type_id = lt.id
    LEFT JOIN public.contracts c ON c.employee_id = p_employee_id AND c.status = 'active'
    LEFT JOIN public.contract_leaves cl ON cl.contract_id = c.id AND cl.leave_type_id = lt.id
    JOIN public.employees e ON e.user_id = ar.user_profile_id
    WHERE e.id = p_employee_id AND ar.attendance_date = v_next_date;
    
    -- Apply sandwich rule: Paid + Off + Unpaid = Off day salary cut
    IF v_prev_status = 'paid_leave' AND v_curr_status = 'absent' AND v_next_status = 'unpaid_leave' THEN
      v_deduction := v_deduction + v_daily_salary;
      
      INSERT INTO public.sandwich_rule_tracking (
        employee_id, start_date, end_date, middle_date,
        before_leave_type, after_leave_type, penalty_applied, salary_deduction
      ) VALUES (
        p_employee_id, v_prev_date, v_next_date, v_date,
        'paid_leave', 'unpaid_leave', true, v_daily_salary
      );
    END IF;
    
    -- Unpaid + Off + Unpaid = All 3 days salary cut
    IF v_prev_status = 'unpaid_leave' AND v_curr_status = 'absent' AND v_next_status = 'unpaid_leave' THEN
      v_deduction := v_deduction + (v_daily_salary * 3);
      
      INSERT INTO public.sandwich_rule_tracking (
        employee_id, start_date, end_date, middle_date,
        before_leave_type, after_leave_type, penalty_applied, salary_deduction
      ) VALUES (
        p_employee_id, v_prev_date, v_next_date, v_date,
        'unpaid_leave', 'unpaid_leave', true, v_daily_salary * 3
      );
    END IF;
    
  END LOOP;
  
  RETURN true;
END;
$$;

-- Update the auto-calculate attendance trigger to use simple function
CREATE OR REPLACE FUNCTION public.auto_calculate_simple_attendance()
RETURNS TRIGGER AS $$
DECLARE
  v_employee_id UUID;
  v_calc_result JSONB;
BEGIN
  SELECT e.id INTO v_employee_id
  FROM public.employees e
  WHERE e.user_id = NEW.user_profile_id;
  
  IF v_employee_id IS NOT NULL AND NEW.check_in IS NOT NULL THEN
    v_calc_result := public.calculate_simple_attendance(
      v_employee_id, NEW.attendance_date, NEW.check_in, NEW.check_out
    );
    
    NEW.status := (v_calc_result->>'status')::VARCHAR;
    NEW.late_arrival_minutes := (v_calc_result->>'late_minutes')::INTEGER;
    NEW.actual_work_hours := (v_calc_result->>'actual_work_hours')::DECIMAL;
    NEW.consecutive_late_count := (v_calc_result->>'consecutive_late_count')::INTEGER;
    NEW.half_day_penalty := (v_calc_result->>'half_day_penalty')::BOOLEAN;
    NEW.total_hours := NEW.actual_work_hours;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Update trigger
DROP TRIGGER IF EXISTS trigger_auto_calculate_attendance ON public.attendance_records;
CREATE TRIGGER trigger_auto_calculate_attendance
  BEFORE INSERT OR UPDATE ON public.attendance_records
  FOR EACH ROW EXECUTE FUNCTION public.auto_calculate_simple_attendance();