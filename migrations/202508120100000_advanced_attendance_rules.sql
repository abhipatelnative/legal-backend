-- Advanced Attendance and Salary Calculation Rules
-- Sandwich Rule, Late Penalties, Work Hours Calculation

-- 1. Add columns to attendance_records
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'attendance_records' AND column_name = 'late_arrival_minutes') THEN
    ALTER TABLE public.attendance_records 
    ADD COLUMN late_arrival_minutes INTEGER DEFAULT 0,
    ADD COLUMN early_departure_minutes INTEGER DEFAULT 0,
    ADD COLUMN is_sandwich_rule_applied BOOLEAN DEFAULT false,
    ADD COLUMN consecutive_late_count INTEGER DEFAULT 0,
    ADD COLUMN half_day_penalty BOOLEAN DEFAULT false,
    ADD COLUMN actual_work_hours DECIMAL(5,2) DEFAULT 0,
    ADD COLUMN shift_start_time TIME,
    ADD COLUMN shift_end_time TIME,
    ADD COLUMN grace_period_minutes INTEGER DEFAULT 5;
  END IF;
END
$$;

-- 2. Late Arrival Tracking
CREATE TABLE IF NOT EXISTS public.employee_late_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  attendance_date DATE NOT NULL,
  late_minutes INTEGER NOT NULL,
  consecutive_count INTEGER NOT NULL,
  penalty_applied BOOLEAN DEFAULT false,
  penalty_type VARCHAR(20) CHECK (penalty_type IN ('half_day', 'full_day', 'none')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(employee_id, attendance_date)
);

-- 3. Sandwich Rule Tracking
CREATE TABLE IF NOT EXISTS public.sandwich_rule_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  middle_date DATE NOT NULL,
  before_leave_type VARCHAR(50),
  after_leave_type VARCHAR(50),
  penalty_applied BOOLEAN DEFAULT false,
  salary_deduction DECIMAL(15,2) DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. Advanced Attendance Calculation
CREATE OR REPLACE FUNCTION public.calculate_advanced_attendance(
  p_employee_id UUID,
  p_attendance_date DATE,
  p_check_in TIMESTAMP WITH TIME ZONE,
  p_check_out TIMESTAMP WITH TIME ZONE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_shift_start TIME;
  v_shift_end TIME;
  v_shift_hours DECIMAL(5,2);
  v_grace_period INTEGER := 5;
  v_late_minutes INTEGER := 0;
  v_early_departure_minutes INTEGER := 0;
  v_actual_work_hours DECIMAL(5,2) := 0;
  v_consecutive_late_count INTEGER := 0;
  v_penalty_type VARCHAR(20) := 'none';
  v_half_day_penalty BOOLEAN := false;
  v_attendance_status VARCHAR(20) := 'present';
  v_result JSONB;
BEGIN
  -- Get shift details
  SELECT 
    s.start_time, s.end_time,
    (EXTRACT(EPOCH FROM (s.end_time - s.start_time)) / 3600) - (COALESCE(s.break_duration, 0) / 60.0)
  INTO v_shift_start, v_shift_end, v_shift_hours
  FROM public.employee_shifts es
  JOIN public.shifts s ON es.shift_id = s.id
  WHERE es.employee_id = p_employee_id AND es.is_active = true
  ORDER BY es.created_at DESC LIMIT 1;
  
  -- Default shift 9:30-18:00
  IF v_shift_start IS NULL THEN
    v_shift_start := '09:30:00'::TIME;
    v_shift_end := '18:00:00'::TIME;
    v_shift_hours := 8.0;
  END IF;
  
  -- Calculate late arrival
  IF p_check_in IS NOT NULL THEN
    v_late_minutes := GREATEST(0, 
      EXTRACT(EPOCH FROM (p_check_in::TIME - v_shift_start)) / 60 - v_grace_period
    );
  END IF;
  
  -- Calculate early departure
  IF p_check_out IS NOT NULL THEN
    v_early_departure_minutes := GREATEST(0,
      EXTRACT(EPOCH FROM (v_shift_end - p_check_out::TIME)) / 60
    );
  END IF;
  
  -- Calculate actual work hours
  IF p_check_in IS NOT NULL AND p_check_out IS NOT NULL THEN
    v_actual_work_hours := EXTRACT(EPOCH FROM (p_check_out - p_check_in)) / 3600;
    v_actual_work_hours := GREATEST(0, v_actual_work_hours - 1.0); -- 1 hour break
  END IF;
  
  -- Check consecutive late arrivals
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
    'early_departure_minutes', v_early_departure_minutes,
    'actual_work_hours', v_actual_work_hours,
    'consecutive_late_count', v_consecutive_late_count,
    'half_day_penalty', v_half_day_penalty,
    'penalty_type', v_penalty_type
  );
  
  RETURN v_result;
END;
$$;

-- 5. Sandwich Rule Application
CREATE OR REPLACE FUNCTION public.apply_sandwich_rule(
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
  
  -- Loop through dates
  FOR v_date IN SELECT generate_series(p_start_date + 1, p_end_date - 1, '1 day'::interval)::date
  LOOP
    v_prev_date := v_date - 1;
    v_next_date := v_date + 1;
    
    -- Check if work day
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
    
    -- Get status for prev/curr/next days
    -- Simplified status check - can be expanded
    SELECT COALESCE(ar.status, 'absent') INTO v_prev_status
    FROM public.attendance_records ar
    JOIN public.employees e ON e.user_id = ar.user_profile_id
    WHERE e.id = p_employee_id AND ar.attendance_date = v_prev_date;
    
    SELECT COALESCE(ar.status, 'absent') INTO v_curr_status
    FROM public.attendance_records ar
    JOIN public.employees e ON e.user_id = ar.user_profile_id
    WHERE e.id = p_employee_id AND ar.attendance_date = v_date;
    
    SELECT COALESCE(ar.status, 'absent') INTO v_next_status
    FROM public.attendance_records ar
    JOIN public.employees e ON e.user_id = ar.user_profile_id
    WHERE e.id = p_employee_id AND ar.attendance_date = v_next_date;
    
    -- Apply sandwich rule logic
    -- Case 1: Paid leave + Off day + Unpaid leave = Off day salary cut
    IF v_prev_status = 'leave' AND v_curr_status = 'absent' AND v_next_status = 'absent' THEN
      v_deduction := v_deduction + v_daily_salary;
      
      INSERT INTO public.sandwich_rule_tracking (
        employee_id, start_date, end_date, middle_date,
        before_leave_type, after_leave_type, penalty_applied, salary_deduction
      ) VALUES (
        p_employee_id, v_prev_date, v_next_date, v_date,
        'paid_leave', 'unpaid_leave', true, v_daily_salary
      );
    END IF;
    
  END LOOP;
  
  RETURN true;
END;
$$;

-- 6. Enhanced Payroll Calculation
CREATE OR REPLACE FUNCTION public.calculate_advanced_payroll(
  p_payroll_period_id UUID,
  p_employee_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_period RECORD;
  v_basic_salary DECIMAL(15,2);
  v_daily_salary DECIMAL(15,2);
  v_total_deductions DECIMAL(15,2) := 0;
  v_late_penalty DECIMAL(15,2) := 0;
  v_sandwich_penalty DECIMAL(15,2) := 0;
  v_attendance_days DECIMAL(10,2) := 0;
  v_gross_salary DECIMAL(15,2);
  v_net_salary DECIMAL(15,2);
BEGIN
  SELECT * INTO v_period FROM public.payroll_periods WHERE id = p_payroll_period_id;
  
  SELECT c.basic_salary INTO v_basic_salary
  FROM public.contracts c
  WHERE c.employee_id = p_employee_id AND c.status = 'active' AND c.is_active = true
  ORDER BY c.created_at DESC LIMIT 1;
  
  v_daily_salary := v_basic_salary / 30;
  
  -- Apply sandwich rule
  PERFORM public.apply_sandwich_rule(p_employee_id, v_period.start_date, v_period.end_date);
  
  -- Calculate late penalties
  SELECT COALESCE(SUM(
    CASE 
      WHEN penalty_type = 'half_day' THEN v_daily_salary * 0.5
      WHEN penalty_type = 'full_day' THEN v_daily_salary
      ELSE 0
    END
  ), 0) INTO v_late_penalty
  FROM public.employee_late_tracking
  WHERE employee_id = p_employee_id
    AND attendance_date BETWEEN v_period.start_date AND v_period.end_date
    AND penalty_applied = true;
  
  -- Calculate sandwich penalties
  SELECT COALESCE(SUM(salary_deduction), 0) INTO v_sandwich_penalty
  FROM public.sandwich_rule_tracking
  WHERE employee_id = p_employee_id
    AND start_date >= v_period.start_date
    AND end_date <= v_period.end_date
    AND penalty_applied = true;
  
  -- Calculate attendance days
  SELECT COALESCE(SUM(
    CASE 
      WHEN ar.half_day_penalty = true THEN 0.5
      WHEN ar.status = 'half_day' THEN 0.5
      WHEN ar.status = 'present' THEN 
        CASE 
          WHEN ar.actual_work_hours >= 8 THEN 1.0
          WHEN ar.actual_work_hours >= 4 THEN 0.5
          ELSE ar.actual_work_hours / 8.0
        END
      ELSE 1.0
    END
  ), 0) INTO v_attendance_days
  FROM public.attendance_records ar
  JOIN public.employees e ON e.user_id = ar.user_profile_id
  WHERE e.id = p_employee_id
    AND ar.attendance_date BETWEEN v_period.start_date AND v_period.end_date
    AND ar.is_active = true;
  
  v_gross_salary := (v_daily_salary * v_attendance_days);
  v_total_deductions := v_late_penalty + v_sandwich_penalty;
  v_net_salary := GREATEST(0, v_gross_salary - v_total_deductions);
  
  -- Process financial deductions
  PERFORM process_monthly_financial_deductions(p_payroll_period_id, p_employee_id);
  
  INSERT INTO public.payroll (
    payroll_period_id, employee_id, basic_salary, gross_salary,
    total_deductions, net_salary, working_days, present_days, status
  ) VALUES (
    p_payroll_period_id, p_employee_id, v_basic_salary, v_gross_salary,
    v_total_deductions, v_net_salary, 30, v_attendance_days, 'draft'
  )
  ON CONFLICT (payroll_period_id, employee_id)
  DO UPDATE SET
    basic_salary = EXCLUDED.basic_salary,
    gross_salary = EXCLUDED.gross_salary,
    total_deductions = EXCLUDED.total_deductions,
    net_salary = EXCLUDED.net_salary,
    present_days = EXCLUDED.present_days,
    updated_at = CURRENT_TIMESTAMP;
  
  RETURN true;
END;
$$;

-- 7. Auto-calculate attendance trigger
CREATE OR REPLACE FUNCTION public.auto_calculate_attendance()
RETURNS TRIGGER AS $$
DECLARE
  v_employee_id UUID;
  v_calc_result JSONB;
BEGIN
  SELECT e.id INTO v_employee_id
  FROM public.employees e
  WHERE e.user_id = NEW.user_profile_id;
  
  IF v_employee_id IS NOT NULL AND NEW.check_in IS NOT NULL THEN
    v_calc_result := public.calculate_advanced_attendance(
      v_employee_id, NEW.attendance_date, NEW.check_in, NEW.check_out
    );
    
    NEW.status := (v_calc_result->>'status')::VARCHAR;
    NEW.late_arrival_minutes := (v_calc_result->>'late_minutes')::INTEGER;
    NEW.early_departure_minutes := (v_calc_result->>'early_departure_minutes')::INTEGER;
    NEW.actual_work_hours := (v_calc_result->>'actual_work_hours')::DECIMAL;
    NEW.consecutive_late_count := (v_calc_result->>'consecutive_late_count')::INTEGER;
    NEW.half_day_penalty := (v_calc_result->>'half_day_penalty')::BOOLEAN;
    NEW.total_hours := NEW.actual_work_hours;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_auto_calculate_attendance ON public.attendance_records;
CREATE TRIGGER trigger_auto_calculate_attendance
  BEFORE INSERT OR UPDATE ON public.attendance_records
  FOR EACH ROW EXECUTE FUNCTION public.auto_calculate_attendance();

-- Indexes
CREATE INDEX IF NOT EXISTS idx_late_tracking_employee_date ON public.employee_late_tracking(employee_id, attendance_date);
CREATE INDEX IF NOT EXISTS idx_sandwich_tracking_employee_dates ON public.sandwich_rule_tracking(employee_id, start_date, end_date);

-- RLS
ALTER TABLE public.employee_late_tracking ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sandwich_rule_tracking ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own late tracking" ON public.employee_late_tracking
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.employees e WHERE e.id = employee_id AND e.user_id = auth.uid())
  );

CREATE POLICY "HR can manage late tracking" ON public.employee_late_tracking
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() AND r.name IN ('HR Manager', 'Admin') AND ur.is_active = true
    )
  );