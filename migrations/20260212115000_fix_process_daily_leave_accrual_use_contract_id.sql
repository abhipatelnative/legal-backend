-- Migration: Update process_daily_leave_accrual() to use contract_id for shift lookups
-- Description: Updates the function to use contract_id instead of employee_id when fetching from employee_shifts

DROP FUNCTION IF EXISTS public.process_daily_leave_accrual();

CREATE OR REPLACE FUNCTION public.process_daily_leave_accrual()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    /* 1. Set the date context (Yesterday in IST) */
    v_today DATE := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')::DATE;
    v_yesterday DATE := v_today - 1;
    v_current_year INTEGER := EXTRACT(YEAR FROM v_yesterday);
    
    /* 2. Employee and State Variables */
    emp RECORD;
    v_user_id UUID;
    v_biometric_code TEXT;
    v_contract_id UUID;
    v_work_week_id UUID;
    v_pl_leave_type_id UUID;
    
    /* 3. Status Determination Variables */
    v_status TEXT;
    v_first_punch TIMESTAMP WITH TIME ZONE;
    v_is_working_day BOOLEAN;
    v_day_of_week INTEGER;
    v_leave_id UUID;
    v_holiday_id UUID;
    
    /* 4. Accrual Rule Variables */
    v_accrual_rule RECORD;
    v_current_earned_balance NUMERIC;
BEGIN
    /* ----------------------------------------------------
       PRE-STEP: Resolve PL Leave Type
    ---------------------------------------------------- */
    SELECT id INTO v_pl_leave_type_id
    FROM public.leave_types
    WHERE LOWER(code) = 'pl' AND is_active = TRUE AND is_deleted = FALSE
    LIMIT 1;

    /* ----------------------------------------------------
       MAIN LOOP: Process each employee eligible for PL accrual
    ---------------------------------------------------- */
    FOR emp IN
        SELECT e.id, e.user_id, e.consecutive_attendance_counter, e.attendance_counting_start_date, e.current_contract_id
        FROM public.employees e
        JOIN public.contracts c ON e.id = c.employee_id
        JOIN public.contract_leaves cl ON c.id = cl.contract_id
        JOIN public.leave_types lt ON cl.leave_type_id = lt.id
        JOIN public.leave_accrual_rules lar ON cl.leave_type_id = lar.leave_type_id
        WHERE e.is_active = true 
          AND e.employment_status = 'active'
          AND c.status = 'active'
          AND c.is_active = true
          AND c.is_deleted = false
          AND lt.salary_payable = true
          AND lar.rule_type = 'CONSECUTIVE_ATTENDANCE'
        GROUP BY e.id, e.user_id, e.consecutive_attendance_counter, e.attendance_counting_start_date, e.current_contract_id
    LOOP
        -- 1. Get Biometric Code
        SELECT biometric_code INTO v_biometric_code FROM public.user_profiles WHERE id = emp.user_id;
        
        -- 2. Get Active Contract
        SELECT id INTO v_contract_id FROM public.contracts 
        WHERE employee_id = emp.id AND status = 'active' AND is_active = TRUE AND is_deleted = FALSE LIMIT 1;

        -- 3. Safety Check: If counting start date is not set, use contract start date
        IF emp.attendance_counting_start_date IS NULL AND v_contract_id IS NOT NULL THEN
            SELECT start_date INTO emp.attendance_counting_start_date FROM public.contracts WHERE id = v_contract_id;
            UPDATE public.employees SET attendance_counting_start_date = emp.attendance_counting_start_date WHERE id = emp.id;
        END IF;

        -- 4. Skip if counting hasn't started for this employee yet or no contract found
        IF v_contract_id IS NULL OR (emp.attendance_counting_start_date IS NOT NULL AND v_yesterday < emp.attendance_counting_start_date) THEN
            CONTINUE;
        END IF;

        -- 5. Determine Day of Week
        v_day_of_week := EXTRACT(DOW FROM v_yesterday);

        /* ----------------------------------------------------
           PRIORITY LOGIC (Same as Backfill)
        ---------------------------------------------------- */
        
        -- Priority 1: Check Punches (4 AM Cutoff logic)
        SELECT MIN(pr.punch_time) INTO v_first_punch
        FROM public.punch_records pr
        WHERE pr.enroll_number::TEXT = v_biometric_code
          AND CASE WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 
                   THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE 
                   ELSE pr.punch_time::DATE END = v_yesterday
          AND pr.is_active = TRUE
          AND pr.is_deleted = FALSE;

        IF v_first_punch IS NOT NULL THEN
            v_status := 'present';
        ELSE
            -- Priority 2: Check Approved Leaves
            SELECT id INTO v_leave_id FROM public.leave_requests
            WHERE employee_id = emp.id AND v_yesterday BETWEEN start_date AND end_date
              AND status = 'approved' AND is_active = TRUE AND is_deleted = FALSE LIMIT 1;

            IF v_leave_id IS NOT NULL THEN
                v_status := 'leave';
            ELSE
                -- Priority 3: Check Holidays (Using holiday_master_id for consistency)
                SELECT h.id INTO v_holiday_id FROM public.holidays h
                LEFT JOIN public.contract_holidays ch ON ch.holiday_master_id = h.holiday_master_id AND ch.contract_id = v_contract_id
                WHERE v_yesterday BETWEEN h.start_date AND h.end_date
                  AND h.is_active = TRUE AND h.is_deleted = FALSE AND (ch.is_applicable IS NULL OR ch.is_applicable = TRUE) LIMIT 1;

                IF v_holiday_id IS NOT NULL THEN
                    v_status := 'holiday';
                ELSE
                    -- Priority 4: Check Weekoff
                    -- FIX: Use contract_id instead of employee_id for shift lookup
                    SELECT es.work_week_id INTO v_work_week_id FROM public.employee_shifts es 
                    WHERE es.contract_id = v_contract_id AND es.is_active = TRUE AND es.is_deleted = FALSE LIMIT 1;

                    IF v_work_week_id IS NOT NULL THEN
                        SELECT 
                            CASE v_day_of_week
                                WHEN 0 THEN ww.sunday WHEN 1 THEN ww.monday WHEN 2 THEN ww.tuesday
                                WHEN 3 THEN ww.wednesday WHEN 4 THEN ww.thursday WHEN 5 THEN ww.friday
                                WHEN 6 THEN ww.saturday ELSE TRUE END
                        INTO v_is_working_day FROM public.work_weeks ww WHERE id = v_work_week_id;

                        IF COALESCE(v_is_working_day, TRUE) = FALSE THEN
                            v_status := 'weekoff';
                        ELSE
                            v_status := 'absent';
                        END IF;
                    ELSE
                        v_status := 'absent';
                    END IF;
                END IF;
            END IF;
        END IF;

        /* ----------------------------------------------------
           UPDATE TABLES (Sync Dashboard & General Attendance)
        ---------------------------------------------------- */
        
        -- 1. Update general attendance table
        INSERT INTO public.employee_attendance (employee_id, attendance_date, status, first_punch_in)
        VALUES (emp.id, v_yesterday, v_status::public.attendance_status, v_first_punch)
        ON CONFLICT (employee_id, attendance_date) DO UPDATE SET 
            status = EXCLUDED.status,
            first_punch_in = COALESCE(EXCLUDED.first_punch_in, employee_attendance.first_punch_in);

        -- 2. Update Dashboard Table (THE CRITICAL FIX)
        INSERT INTO public.attendance_day_counting (employee_id, counting_date, is_counted, reason)
        VALUES (emp.id, v_yesterday, (v_status = 'present'), v_status)
        ON CONFLICT (employee_id, counting_date) DO UPDATE SET 
            reason = EXCLUDED.reason, 
            is_counted = EXCLUDED.is_counted,
            updated_at = CURRENT_TIMESTAMP;

        /* ----------------------------------------------------
           INCREMENT COUNTER & ACCRUE LEAVE
        ---------------------------------------------------- */
        IF v_status = 'present' THEN
            -- Increment counter
            UPDATE public.employees SET consecutive_attendance_counter = consecutive_attendance_counter + 1 WHERE id = emp.id;
            
            -- Check for 50-day milestone
            FOR v_accrual_rule IN 
                SELECT lar.*, cl.days_allowed as cap FROM public.leave_accrual_rules lar
                JOIN public.contract_leaves cl ON cl.leave_type_id = lar.leave_type_id
                WHERE cl.contract_id = v_contract_id AND lar.rule_type = 'CONSECUTIVE_ATTENDANCE'
            LOOP
                -- Use the updated counter value from the database
                DECLARE
                    v_updated_counter INTEGER;
                BEGIN
                    SELECT consecutive_attendance_counter INTO v_updated_counter FROM public.employees WHERE id = emp.id;
                    
                    IF v_updated_counter > 0 AND v_updated_counter % 50 = 0 THEN
                        -- Award Leave
                        INSERT INTO public.leave_balances (employee_id, leave_type_id, year, earned_days, used_days, carried_forward, encashed_days, contract_id)
                        VALUES (emp.id, v_accrual_rule.leave_type_id, v_current_year, v_updated_counter / 50, 0, 0, 0, v_contract_id)
                        ON CONFLICT (employee_id, leave_type_id, year, contract_id) 
                        DO UPDATE SET earned_days = leave_balances.earned_days + EXCLUDED.earned_days;

                        -- Reset Counter & Move Start Date to the following day
                        UPDATE public.employees SET 
                            consecutive_attendance_counter = 0,
                            attendance_counting_start_date = v_yesterday + INTERVAL '1 day'
                        WHERE id = emp.id;
                    END IF;
                END;
            END LOOP;
        END IF;
    END LOOP;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.process_daily_leave_accrual() TO authenticated;

-- Add comment
COMMENT ON FUNCTION public.process_daily_leave_accrual() 
IS 'Daily cron job to process leave accrual based on attendance. Uses contract_id for shift/week-off lookup and handles consecutive attendance milestones.';
