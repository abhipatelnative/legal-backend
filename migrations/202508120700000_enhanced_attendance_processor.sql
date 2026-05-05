-- Enhanced attendance processing functions for late tracking and penalties

-- Function to process employee late tracking with consecutive penalties
CREATE OR REPLACE FUNCTION public.process_employee_late_tracking(
  p_employee_id UUID,
  p_attendance_date DATE,
  p_late_minutes INTEGER
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_consecutive_count INTEGER := 0;
  v_penalty_type VARCHAR(20) := NULL;
  v_daily_salary NUMERIC(15,2);
  v_penalty_amount NUMERIC(15,2) := 0;
  v_half_day_penalty BOOLEAN := false;
BEGIN
  -- Get employee's daily salary
  SELECT (c.basic_salary / 30) INTO v_daily_salary
  FROM public.contracts c
  WHERE c.employee_id = p_employee_id AND c.status = 'active' AND c.is_active = true
  ORDER BY c.created_at DESC LIMIT 1;
  
  IF v_daily_salary IS NULL THEN
    v_daily_salary := 0;
  END IF;
  
  -- Check consecutive late arrivals in the last 10 days
  SELECT COALESCE(MAX(consecutive_count), 0) + 1
  INTO v_consecutive_count
  FROM public.employee_late_tracking
  WHERE employee_id = p_employee_id
    AND attendance_date >= p_attendance_date - INTERVAL '10 days'
    AND attendance_date < p_attendance_date
    AND late_minutes > 0;
  
  -- Apply penalty logic: Every 3rd consecutive late = half day penalty
  IF v_consecutive_count >= 3 AND v_consecutive_count % 3 = 0 THEN
    v_penalty_type := 'half_day';
    v_penalty_amount := v_daily_salary * 0.5;
    v_half_day_penalty := true;
    
    -- Update attendance status to half_day for penalty
    UPDATE public.attendance_records
    SET status = 'half_day',
        half_day_penalty = true,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_profile_id = (
      SELECT user_id FROM public.employees WHERE id = p_employee_id
    )
    AND attendance_date = p_attendance_date;
  END IF;
  
  -- Insert or update late tracking record
  INSERT INTO public.employee_late_tracking (
    employee_id,
    attendance_date,
    late_minutes,
    consecutive_count,
    penalty_type,
    penalty_applied,
    salary_deduction,
    created_at
  ) VALUES (
    p_employee_id,
    p_attendance_date,
    p_late_minutes,
    v_consecutive_count,
    v_penalty_type,
    v_half_day_penalty,
    v_penalty_amount,
    CURRENT_TIMESTAMP
  )
  ON CONFLICT (employee_id, attendance_date)
  DO UPDATE SET
    late_minutes = EXCLUDED.late_minutes,
    consecutive_count = EXCLUDED.consecutive_count,
    penalty_type = EXCLUDED.penalty_type,
    penalty_applied = EXCLUDED.penalty_applied,
    salary_deduction = EXCLUDED.salary_deduction,
    updated_at = CURRENT_TIMESTAMP;
  
  RETURN TRUE;
END;
$$;

-- Enhanced trigger function for attendance records
CREATE OR REPLACE FUNCTION public.auto_calculate_simple_attendance()
RETURNS TRIGGER AS $$
DECLARE
  v_employee_id UUID;
  v_shift_start TIME;
  v_shift_end TIME;
  v_late_minutes INTEGER := 0;
  v_early_minutes INTEGER := 0;
  v_actual_work_hours NUMERIC(5,2) := 0;
  v_overtime_hours NUMERIC(5,2) := 0;
  v_status VARCHAR(50) := 'present';
BEGIN
  -- Get employee ID from user_profile_id
  SELECT e.id INTO v_employee_id
  FROM public.employees e
  WHERE e.user_id = NEW.user_profile_id;
  
  IF v_employee_id IS NULL THEN
    RETURN NEW;
  END IF;
  
  -- Get shift details
  SELECT s.start_time, s.end_time
  INTO v_shift_start, v_shift_end
  FROM public.employee_shifts es
  JOIN public.shifts s ON es.shift_id = s.id
  WHERE es.employee_id = v_employee_id
    AND es.is_active = true
    AND es.is_deleted = false
  ORDER BY es.created_at DESC
  LIMIT 1;
  
  -- Set default shift if not found
  IF v_shift_start IS NULL THEN
    v_shift_start := '09:30:00'::TIME;
    v_shift_end := '18:00:00'::TIME;
  END IF;
  
  -- Calculate late arrival (with grace period)
  IF NEW.check_in IS NOT NULL THEN
    v_late_minutes := GREATEST(0, 
      EXTRACT(EPOCH FROM (NEW.check_in::TIME - v_shift_start)) / 60 - COALESCE(NEW.grace_period_minutes, 5)
    );
  END IF;
  
  -- Calculate early departure
  IF NEW.check_out IS NOT NULL THEN
    v_early_minutes := GREATEST(0,
      EXTRACT(EPOCH FROM (v_shift_end - NEW.check_out::TIME)) / 60
    );
  END IF;
  
  -- Calculate actual work hours (total - break time)
  IF NEW.check_in IS NOT NULL AND NEW.check_out IS NOT NULL THEN
    v_actual_work_hours := GREATEST(0,
      EXTRACT(EPOCH FROM (NEW.check_out - NEW.check_in)) / 3600 - 
      COALESCE(NEW.total_break_duration_minutes, 30) / 60.0
    );
    
    -- Calculate overtime (work hours > 8)
    v_overtime_hours := GREATEST(0, v_actual_work_hours - 8);
  END IF;
  
  -- Determine status based on work hours
  IF v_actual_work_hours >= 8 THEN
    v_status := 'present';
  ELSIF v_actual_work_hours >= 4 THEN
    v_status := 'half_day';
  ELSIF v_actual_work_hours > 0 THEN
    v_status := 'half_day';
  ELSE
    v_status := 'absent';
  END IF;
  
  -- Update NEW record with calculated values
  NEW.late_arrival_minutes := v_late_minutes;
  NEW.early_departure_minutes := v_early_minutes;
  NEW.actual_work_hours := v_actual_work_hours;
  NEW.overtime_hours := COALESCE(NEW.overtime_hours, v_overtime_hours);
  NEW.status := COALESCE(NEW.status, v_status);
  NEW.shift_start_time := v_shift_start;
  NEW.shift_end_time := v_shift_end;
  NEW.updated_at := CURRENT_TIMESTAMP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Update the trigger to use the enhanced function
DROP TRIGGER IF EXISTS trigger_auto_calculate_attendance ON public.attendance_records;
CREATE TRIGGER trigger_auto_calculate_attendance
  BEFORE INSERT OR UPDATE ON public.attendance_records
  FOR EACH ROW EXECUTE FUNCTION auto_calculate_simple_attendance();

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION public.process_employee_late_tracking TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_calculate_simple_attendance TO authenticated;