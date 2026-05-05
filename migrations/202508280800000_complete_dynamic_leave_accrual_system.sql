-- Complete Dynamic Leave Accrual System Implementation

-- 1. Create attendance_records table
CREATE TABLE IF NOT EXISTS public.attendance_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  status VARCHAR(20) NOT NULL CHECK (status IN ('present', 'absent', 'holiday', 'weekend', 'leave')),
  check_in_time TIME,
  check_out_time TIME,
  total_hours DECIMAL(4,2),
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  
  CONSTRAINT unique_employee_date UNIQUE(employee_id, date)
);

-- 2. Create leave_accrual_tracking table
CREATE TABLE IF NOT EXISTS public.leave_accrual_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  leave_type_id UUID NOT NULL REFERENCES public.leave_types(id) ON DELETE CASCADE,
  year INTEGER NOT NULL,
  continuous_days INTEGER DEFAULT 0,
  earned_leaves DECIMAL(10,2) DEFAULT 0,
  last_accrual_date DATE,
  last_attendance_date DATE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  
  CONSTRAINT unique_employee_leave_year UNIQUE(employee_id, leave_type_id, year)
);

-- 3. Update initialize_employee_leave_balances to handle payable vs non-payable correctly
CREATE OR REPLACE FUNCTION public.initialize_employee_leave_balances(
  p_employee_id UUID,
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  contract_leave RECORD;
  initial_allocated_days DECIMAL(10,2);
BEGIN
  -- Get contract leaves
  FOR contract_leave IN
    SELECT cl.leave_type_id, cl.days_allowed, cl.salary_payable
    FROM public.contracts c
    JOIN public.contract_leaves cl ON c.id = cl.contract_id
    WHERE c.employee_id = p_employee_id
      AND c.status = 'active'
      AND c.is_active = true
      AND c.is_deleted = false
      AND cl.is_active = true
      AND cl.is_deleted = false
  LOOP
    -- Set initial allocated days based on leave type
    IF contract_leave.salary_payable THEN
      initial_allocated_days := 0; -- Payable leaves: must earn through attendance
    ELSE
      initial_allocated_days := 999999; -- Non-payable leaves: unlimited
    END IF;
    
    -- Insert leave balance
    INSERT INTO public.leave_balances (
      employee_id,
      leave_type_id,
      year,
      allocated_days,
      used_days,
      carried_forward,
      encashed_days
    ) VALUES (
      p_employee_id,
      contract_leave.leave_type_id,
      p_year,
      initial_allocated_days,
      0,
      0,
      0
    )
    ON CONFLICT (employee_id, leave_type_id, year)
    DO UPDATE SET
      allocated_days = initial_allocated_days,
      updated_at = CURRENT_TIMESTAMP;
      
    -- Initialize accrual tracking ONLY for payable leaves
    IF contract_leave.salary_payable THEN
      INSERT INTO public.leave_accrual_tracking (
        employee_id, leave_type_id, year, continuous_days, earned_leaves
      ) VALUES (
        p_employee_id, contract_leave.leave_type_id, p_year, 0, 0
      ) ON CONFLICT (employee_id, leave_type_id, year) DO NOTHING;
    END IF;
  END LOOP;
  
  RETURN TRUE;
END;
$$;

-- 4. Create daily leave accrual processing function
CREATE OR REPLACE FUNCTION public.process_daily_leave_accrual()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  employee_record RECORD;
  accrual_rule RECORD;
  attendance_record RECORD;
  today_date DATE := CURRENT_DATE;
  yesterday_date DATE := CURRENT_DATE - INTERVAL '1 day';
  current_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE);
BEGIN
  -- Process each active employee
  FOR employee_record IN 
    SELECT e.id, e.hire_date, c.probation_active
    FROM public.employees e
    JOIN public.contracts c ON e.id = c.employee_id
    WHERE e.is_active = true 
    AND e.is_deleted = false
    AND c.status = 'active'
    AND c.is_active = true
    AND c.is_deleted = false
  LOOP
    
    -- Get attendance for yesterday
    SELECT * INTO attendance_record
    FROM public.attendance_records ar
    WHERE ar.employee_id = employee_record.id
    AND ar.date = yesterday_date
    LIMIT 1;
    
    -- Process each leave accrual rule for payable leaves
    FOR accrual_rule IN
      SELECT 
        lar.*, 
        cl.leave_type_id, 
        cl.days_allowed as max_annual_days,
        cl.salary_payable
      FROM public.leave_accrual_rules lar
      JOIN public.contract_leaves cl ON lar.leave_type_id = cl.leave_type_id
      JOIN public.contracts c ON cl.contract_id = c.id
      WHERE c.employee_id = employee_record.id
      AND c.status = 'active'
      AND cl.salary_payable = true
      AND lar.deleted_at IS NULL
      AND (lar.apply_to_probation = true OR employee_record.probation_active = false)
    LOOP
      
      -- Initialize tracking if not exists
      INSERT INTO public.leave_accrual_tracking (
        employee_id, leave_type_id, year, continuous_days, earned_leaves
      ) VALUES (
        employee_record.id, accrual_rule.leave_type_id, current_year, 0, 0
      ) ON CONFLICT (employee_id, leave_type_id, year) DO NOTHING;
      
      -- Update continuous days and check for accrual
      IF attendance_record.id IS NOT NULL AND attendance_record.status IN ('present', 'holiday', 'weekend') THEN
        -- Employee was present/holiday/weekend - increment continuous days
        UPDATE public.leave_accrual_tracking 
        SET 
          continuous_days = continuous_days + 1,
          last_attendance_date = yesterday_date,
          updated_at = CURRENT_TIMESTAMP
        WHERE employee_id = employee_record.id 
        AND leave_type_id = accrual_rule.leave_type_id 
        AND year = current_year;
        
        -- Check if earned a leave (based on frequency_days from accrual rule)
        UPDATE public.leave_accrual_tracking 
        SET 
          earned_leaves = earned_leaves + accrual_rule.accrual_value,
          last_accrual_date = yesterday_date,
          continuous_days = 0, -- Reset counter
          updated_at = CURRENT_TIMESTAMP
        WHERE employee_id = employee_record.id 
        AND leave_type_id = accrual_rule.leave_type_id 
        AND year = current_year
        AND continuous_days >= COALESCE(accrual_rule.frequency_days, 50) -- Default 50 days
        AND earned_leaves < accrual_rule.max_annual_days;
        
        -- Update leave balance with earned leaves
        UPDATE public.leave_balances 
        SET 
          allocated_days = (
            SELECT earned_leaves 
            FROM public.leave_accrual_tracking 
            WHERE employee_id = employee_record.id 
            AND leave_type_id = accrual_rule.leave_type_id 
            AND year = current_year
          ),
          updated_at = CURRENT_TIMESTAMP
        WHERE employee_id = employee_record.id 
        AND leave_type_id = accrual_rule.leave_type_id 
        AND year = current_year;
          
      ELSE
        -- Employee took leave or was absent - reset continuous days
        UPDATE public.leave_accrual_tracking 
        SET 
          continuous_days = 0,
          updated_at = CURRENT_TIMESTAMP
        WHERE employee_id = employee_record.id 
        AND leave_type_id = accrual_rule.leave_type_id 
        AND year = current_year;
      END IF;
      
    END LOOP;
  END LOOP;
END;
$$;

-- 5. Create function to auto-populate attendance records
CREATE OR REPLACE FUNCTION public.auto_populate_attendance_records()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  employee_record RECORD;
  yesterday_date DATE := CURRENT_DATE - INTERVAL '1 day';
  day_of_week INTEGER := EXTRACT(DOW FROM yesterday_date);
BEGIN
  -- Process each active employee
  FOR employee_record IN 
    SELECT e.id
    FROM public.employees e
    JOIN public.contracts c ON e.id = c.employee_id
    WHERE e.is_active = true 
    AND e.is_deleted = false
    AND c.status = 'active'
  LOOP
    
    -- Check if attendance record already exists
    IF NOT EXISTS (
      SELECT 1 FROM public.attendance_records 
      WHERE employee_id = employee_record.id 
      AND date = yesterday_date
    ) THEN
      
      -- Check if it's a holiday
      IF EXISTS (
        SELECT 1 FROM public.holidays 
        WHERE start_date <= yesterday_date 
        AND end_date >= yesterday_date
        AND is_active = true
        AND is_deleted = false
      ) THEN
        -- Insert as holiday
        INSERT INTO public.attendance_records (
          employee_id, date, status
        ) VALUES (
          employee_record.id, yesterday_date, 'holiday'
        );
      ELSIF day_of_week IN (0, 6) THEN -- Sunday = 0, Saturday = 6
        -- Insert as weekend
        INSERT INTO public.attendance_records (
          employee_id, date, status
        ) VALUES (
          employee_record.id, yesterday_date, 'weekend'
        );
      ELSE
        -- Insert as present (default assumption)
        INSERT INTO public.attendance_records (
          employee_id, date, status
        ) VALUES (
          employee_record.id, yesterday_date, 'present'
        );
      END IF;
    END IF;
    
  END LOOP;
END;
$$;

-- 6. Create cron jobs
SELECT cron.schedule(
  'auto-populate-attendance',
  '0 2 * * *', -- 2 AM daily
  'SELECT public.auto_populate_attendance_records();'
);

SELECT cron.schedule(
  'daily-leave-accrual-processing',
  '0 4 * * *', -- 4 AM daily
  'SELECT public.process_daily_leave_accrual();'
);

-- 7. Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_attendance_records_employee_date ON public.attendance_records(employee_id, date);
CREATE INDEX IF NOT EXISTS idx_attendance_records_status ON public.attendance_records(status);
CREATE INDEX IF NOT EXISTS idx_leave_accrual_tracking_employee ON public.leave_accrual_tracking(employee_id);
CREATE INDEX IF NOT EXISTS idx_leave_accrual_tracking_year ON public.leave_accrual_tracking(year);
CREATE INDEX IF NOT EXISTS idx_leave_accrual_tracking_leave_type ON public.leave_accrual_tracking(leave_type_id);

-- 8. Create triggers
CREATE TRIGGER update_attendance_records_updated_at 
  BEFORE UPDATE ON public.attendance_records 
  FOR EACH ROW 
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_leave_accrual_tracking_updated_at 
  BEFORE UPDATE ON public.leave_accrual_tracking 
  FOR EACH ROW 
  EXECUTE FUNCTION public.update_updated_at_column();

-- 9. Grant permissions
GRANT EXECUTE ON FUNCTION public.process_daily_leave_accrual() TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_populate_attendance_records() TO authenticated;

-- 10. Initialize system for existing employees
DO $$
DECLARE
  emp_record RECORD;
BEGIN
  FOR emp_record IN 
    SELECT e.id 
    FROM public.employees e
    JOIN public.contracts c ON e.id = c.employee_id
    WHERE e.is_active = true 
    AND c.status = 'active'
  LOOP
    PERFORM public.initialize_employee_leave_balances(emp_record.id);
  END LOOP;
END;
$$;