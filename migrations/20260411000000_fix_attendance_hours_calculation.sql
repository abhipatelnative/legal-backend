-- ============================================================================
-- Migration: Fix attendance calculation to properly compute total_hours
-- Date: 2026-04-11
-- ============================================================================
-- Issues Fixed:
-- 1. total_hours not being calculated in employee_attendance
-- 2. check_out_time not being stored
-- 3. first_punch_in showing wrong times (after 4 AM cutoff issue)
-- 4. Hours calculation formula incorrect
-- ============================================================================

-- STEP 1: Add missing columns to employee_attendance
ALTER TABLE public.employee_attendance 
ADD COLUMN IF NOT EXISTS check_out_time timestamp with time zone,
ADD COLUMN IF NOT EXISTS total_hours numeric(10, 2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS total_break_minutes integer DEFAULT 0;

-- Add comments for documentation
COMMENT ON COLUMN public.employee_attendance.check_out_time IS 'Last punch time of the day (after 4 AM cutoff logic)';
COMMENT ON COLUMN public.employee_attendance.total_hours IS 'Total working hours excluding breaks, in decimal hours';
COMMENT ON COLUMN public.employee_attendance.total_break_minutes IS 'Total break time calculated from gaps between punches';

-- STEP 2: Update process_daily_attendance to calculate hours
DROP FUNCTION IF EXISTS public.process_daily_attendance();

CREATE OR REPLACE FUNCTION public.process_daily_attendance()
RETURNS void
LANGUAGE plpgsql
AS $$
declare
    processing_date date := current_date;
    emp record;
    punch_count integer;
    v_first_punch timestamptz;
    v_last_punch timestamptz;
    v_total_hours numeric(10, 2);
    v_total_break_minutes integer;
    v_punch_times timestamptz[];
    v_punch_count integer;
    i integer;
    break_start timestamptz;
    break_end timestamptz;
    break_duration_minutes integer;

    leave_found boolean;
    leave_salary_payable boolean;
    leave_allow_hourly boolean;
    leave_max_hours integer;
    is_half_day boolean;
    is_hourly_leave boolean;
    is_short_leave boolean;

    is_contract_holiday boolean;
    is_week_off boolean;
begin
    for emp in
        select e.id, c.id as contract_id
        from public.employees e
        join public.contracts c on e.id = c.employee_id
        where e.is_active = true
          and e.employment_status = 'active'
          and c.status = 'active'
          and c.is_active = true
          and c.is_deleted = false
    loop
        /* -------------------------------
           step 1 : leave (highest priority)
        -------------------------------- */
        select
            true,
            lt.salary_payable,
            lt.allow_hourly,
            lt.max_hours_per_day,
            (lr.total_days = 0.5),
            (lr.start_time is not null and lr.end_time is not null),
            (
                lt.code = 'sl'
                and lt.is_active = true
                and lt.is_deleted = false
            )
        into
            leave_found,
            leave_salary_payable,
            leave_allow_hourly,
            leave_max_hours,
            is_half_day,
            is_hourly_leave,
            is_short_leave
        from public.leave_requests lr
        join public.leave_types lt on lr.leave_type_id = lt.id
        where lr.employee_id = emp.id
          and lr.status = 'approved'
          and processing_date between lr.start_date and lr.end_date
          and lr.is_active = true
          and lr.is_deleted = false
        limit 1;

        if leave_found then
            if is_half_day then
                insert into public.employee_attendance
                    (employee_id, attendance_date, status, total_hours)
                values (emp.id, processing_date, 'absent', 0)
                on conflict (employee_id, attendance_date)
                do update set status = 'absent', total_hours = 0;
                continue;
            end if;

            if is_short_leave then
                insert into public.employee_attendance
                    (employee_id, attendance_date, status, total_hours)
                values (emp.id, processing_date, 'present', 0)
                on conflict (employee_id, attendance_date)
                do update set status = 'present', total_hours = 0;
                continue;
            end if;

            if leave_salary_payable
               and leave_allow_hourly
               and leave_max_hours is not null
               and is_hourly_leave
            then
                insert into public.employee_attendance
                    (employee_id, attendance_date, status, total_hours)
                values (emp.id, processing_date, 'present', 0)
                on conflict (employee_id, attendance_date)
                do update set status = 'present', total_hours = 0;
            else
                insert into public.employee_attendance
                    (employee_id, attendance_date, status, total_hours)
                values (emp.id, processing_date, 'absent', 0)
                on conflict (employee_id, attendance_date)
                do update set status = 'absent', total_hours = 0;
            end if;

            continue;
        end if;

        /* -------------------------------
           step 2 : punch (overrides holiday & weekoff)
           Use 4 AM cutoff: punches before 4 AM belong to previous day
        -------------------------------- */
        
        -- Collect all punch times for this employee on this date
        -- Apply 4 AM cutoff logic: if punch hour < 4, assign to previous day
        SELECT array_agg(
            CASE 
                WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 
                THEN pr.punch_time - INTERVAL '1 day'
                ELSE pr.punch_time
            END ORDER BY 
                CASE 
                    WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 
                    THEN pr.punch_time - INTERVAL '1 day'
                    ELSE pr.punch_time
                END
        )
        INTO v_punch_times
        FROM public.punch_records pr
        JOIN public.user_profiles up ON pr.enroll_number::text = up.biometric_code
        WHERE up.id = (SELECT user_id FROM public.employees WHERE id = emp.id)
          AND (
              -- Include punches from processing_date OR from next day before 4 AM
              (pr.punch_time::date = processing_date AND pr.punch_time::time >= time '04:00')
              OR 
              (pr.punch_time::date = processing_date + 1 AND pr.punch_time::time < time '04:00')
              OR
              (pr.punch_time::date = processing_date - 1 AND pr.punch_time::time >= time '04:00' AND EXTRACT(HOUR FROM pr.punch_time) < 4)
          )
          AND pr.is_active = true
          AND pr.is_deleted = false;

        -- Count punches for the processing date (with 4 AM cutoff)
        SELECT COUNT(*) INTO punch_count
        FROM public.punch_records pr
        JOIN public.user_profiles up ON pr.enroll_number::text = up.biometric_code
        WHERE up.id = (SELECT user_id FROM public.employees WHERE id = emp.id)
          AND (
              (pr.punch_time::date = processing_date AND pr.punch_time::time >= time '04:00')
              OR 
              (pr.punch_time::date = processing_date + 1 AND pr.punch_time::time < time '04:00')
          )
          AND pr.is_active = true
          AND pr.is_deleted = false;

        IF punch_count > 0 AND v_punch_times IS NOT NULL AND array_length(v_punch_times, 1) > 0 THEN
            -- First punch is check-in, last punch is check-out
            v_first_punch := v_punch_times[1];
            v_last_punch := v_punch_times[array_length(v_punch_times, 1)];
            v_punch_count := array_length(v_punch_times, 1);
            
            -- Calculate break time: gaps between OUT punch and next IN punch
            -- Assume alternating pattern: IN, OUT, IN, OUT, etc.
            v_total_break_minutes := 0;
            
            FOR i IN 2..v_punch_count-1 BY 2 LOOP
                IF i + 1 <= v_punch_count THEN
                    break_start := v_punch_times[i];
                    break_end := v_punch_times[i + 1];
                    break_duration_minutes := EXTRACT(EPOCH FROM (break_end - break_start)) / 60;
                    
                    -- Only count as break if gap is between 15 minutes and 4 hours
                    IF break_duration_minutes >= 15 AND break_duration_minutes <= 240 THEN
                        v_total_break_minutes := v_total_break_minutes + break_duration_minutes;
                    END IF;
                END IF;
            END LOOP;
            
            -- Calculate total working hours
            IF v_last_punch > v_first_punch THEN
                v_total_hours := ROUND(
                    GREATEST(0, 
                        (EXTRACT(EPOCH FROM (v_last_punch - v_first_punch)) / 3600.0) 
                        - (v_total_break_minutes / 60.0)
                    )::numeric, 
                    2
                );
            ELSE
                v_total_hours := 0;
            END IF;
            
            -- Insert/update attendance record
            INSERT INTO public.employee_attendance
                (employee_id, attendance_date, status, first_punch_in, check_out_time, total_hours, total_break_minutes)
            VALUES 
                (emp.id, processing_date, 'present', v_first_punch, v_last_punch, v_total_hours, v_total_break_minutes)
            ON CONFLICT (employee_id, attendance_date)
            DO UPDATE SET
                status = 'present',
                first_punch_in = EXCLUDED.first_punch_in,
                check_out_time = EXCLUDED.check_out_time,
                total_hours = EXCLUDED.total_hours,
                total_break_minutes = EXCLUDED.total_break_minutes;
            
            CONTINUE;
        END IF;

        /* -------------------------------
           step 3 : holiday
        -------------------------------- */
        select exists (
            select 1
            from public.contract_holidays ch
            join public.holidays h
              on ch.holiday_master_id = h.holiday_master_id
            where ch.contract_id = emp.contract_id
              and ch.is_applicable = true
              and h.is_active = true
              and processing_date between h.start_date and h.end_date
        ) into is_contract_holiday;

        if is_contract_holiday then
            insert into public.employee_attendance
                (employee_id, attendance_date, status, total_hours)
            values (emp.id, processing_date, 'holiday', 0)
            on conflict (employee_id, attendance_date)
            do update set status = 'holiday', total_hours = 0;
            continue;
        end if;

        /* -------------------------------
           step 4 : weekoff
        -------------------------------- */
        select exists (
            select 1
            from public.employee_shifts es
            join public.shifts s
              on es.shift_id = s.id
            join public.work_weeks ww
              on s.work_week_id = ww.id
            join public.work_week_days wwd
              on ww.id = wwd.work_week_id
            where es.employee_id = emp.id
              and es.is_active = true
              and wwd.day_of_week = extract(dow from processing_date)
              and lower(wwd.is_working_day) = 'false'
              and wwd.is_active = true
        ) into is_week_off;

        if is_week_off then
            insert into public.employee_attendance
                (employee_id, attendance_date, status, total_hours)
            values (emp.id, processing_date, 'weekoff', 0)
            on conflict (employee_id, attendance_date)
            do update set status = 'weekoff', total_hours = 0;
            continue;
        end if;

        /* -------------------------------
           step 5 : default absent
        -------------------------------- */
        insert into public.employee_attendance
            (employee_id, attendance_date, status, total_hours)
        values (emp.id, processing_date, 'absent', 0)
        on conflict (employee_id, attendance_date)
        do update set status = 'absent', total_hours = 0;
    end loop;
end;
$$;

COMMENT ON FUNCTION public.process_daily_attendance() 
IS 'Processes daily attendance with priority: Leave > Punch > Holiday > Weekoff > Absent. 
Calculates total_hours from punch records using 4 AM cutoff logic. 
First punch = check_in, last punch = check_out, gaps between punches = breaks.';

-- STEP 3: Update fix_attendance_from_punches to recalculate hours
DROP FUNCTION IF EXISTS public.fix_attendance_from_punches();

CREATE OR REPLACE FUNCTION public.fix_attendance_from_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_employee_id uuid;
    v_biometric_code text;
    v_date date;
    v_first_punch timestamptz;
    v_last_punch timestamptz;
    v_total_hours numeric(10, 2);
    v_total_break_minutes integer;
    v_punch_times timestamptz[];
    v_punch_count integer;
    v_status text;
    v_current_counter integer;
    v_pl_earning_days integer;
    i integer;
    break_start timestamptz;
    break_end timestamptz;
    break_duration_minutes integer;
    v_leave_type_code text;
BEGIN
    -- Get PL earning days configuration
    SELECT COALESCE(lt.pl_earning_days, 30)
    INTO v_pl_earning_days
    FROM public.leave_types lt
    WHERE lt.code = 'pl' 
      AND lt.is_active = true 
      AND lt.is_deleted = false
    LIMIT 1;
    
    v_pl_earning_days := COALESCE(v_pl_earning_days, 30);

    -- Loop through last 5 days
    FOR v_date IN 
        SELECT generate_series(current_date - INTERVAL '5 days', current_date - INTERVAL '1 day', '1 day')::date
    LOOP
        -- Find employees marked absent/weekoff/holiday who have punches
        FOR v_employee_id, v_biometric_code, v_status IN
            SELECT ea.employee_id, up.biometric_code, ea.status
            FROM public.employee_attendance ea
            JOIN public.employees e ON ea.employee_id = e.id
            JOIN public.user_profiles up ON e.user_id = up.id
            WHERE ea.attendance_date = v_date
              AND ea.status IN ('absent', 'weekoff', 'holiday')
              AND e.is_active = true
              AND e.employment_status = 'active'
              AND up.is_active = true
              AND up.is_deleted = false
        LOOP
            -- Get all punch times with 4 AM cutoff logic
            SELECT array_agg(
                CASE 
                    WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 
                    THEN pr.punch_time - INTERVAL '1 day'
                    ELSE pr.punch_time
                END ORDER BY 
                    CASE 
                        WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 
                        THEN pr.punch_time - INTERVAL '1 day'
                        ELSE pr.punch_time
                    END
            )
            INTO v_punch_times
            FROM public.punch_records pr
            WHERE pr.enroll_number::text = v_biometric_code
              AND (
                  (pr.punch_time::date = v_date AND pr.punch_time::time >= time '04:00')
                  OR 
                  (pr.punch_time::date = v_date + 1 AND pr.punch_time::time < time '04:00')
              )
              AND pr.is_active = true
              AND pr.is_deleted = false;

            -- If punches exist, correct the attendance
            IF v_punch_times IS NOT NULL AND array_length(v_punch_times, 1) > 0 THEN
                v_first_punch := v_punch_times[1];
                v_last_punch := v_punch_times[array_length(v_punch_times, 1)];
                v_punch_count := array_length(v_punch_times, 1);
                
                -- Calculate breaks
                v_total_break_minutes := 0;
                FOR i IN 2..v_punch_count-1 BY 2 LOOP
                    IF i + 1 <= v_punch_count THEN
                        break_start := v_punch_times[i];
                        break_end := v_punch_times[i + 1];
                        break_duration_minutes := EXTRACT(EPOCH FROM (break_end - break_start)) / 60;
                        
                        IF break_duration_minutes >= 15 AND break_duration_minutes <= 240 THEN
                            v_total_break_minutes := v_total_break_minutes + break_duration_minutes;
                        END IF;
                    END IF;
                END LOOP;
                
                -- Calculate total hours
                IF v_last_punch > v_first_punch THEN
                    v_total_hours := ROUND(
                        GREATEST(0, 
                            (EXTRACT(EPOCH FROM (v_last_punch - v_first_punch)) / 3600.0) 
                            - (v_total_break_minutes / 60.0)
                        )::numeric, 
                        2
                    );
                ELSE
                    v_total_hours := 0;
                END IF;
                
                -- Update attendance record
                UPDATE public.employee_attendance
                SET 
                    status = 'present',
                    first_punch_in = v_first_punch,
                    check_out_time = v_last_punch,
                    total_hours = v_total_hours,
                    total_break_minutes = v_total_break_minutes
                WHERE employee_id = v_employee_id
                  AND attendance_date = v_date;

                -- Increment consecutive attendance counter and award PL
                SELECT COALESCE(ea.consecutive_attendance_counter, 0)
                INTO v_current_counter
                FROM public.employee_attendance ea
                WHERE ea.employee_id = v_employee_id
                  AND ea.attendance_date = v_date;

                IF v_current_counter > 0 AND v_current_counter % v_pl_earning_days = 0 THEN
                    -- Get leave type code for PL earning
                    SELECT lt.code INTO v_leave_type_code
                    FROM public.leave_types lt
                    WHERE lt.pl_earning_days = v_pl_earning_days
                      AND lt.is_active = true
                      AND lt.is_deleted = false
                    LIMIT 1;

                    IF v_leave_type_code IS NOT NULL THEN
                        -- Award PL leave
                        INSERT INTO public.leave_requests 
                            (employee_id, leave_type_id, start_date, end_date, total_days, status, leave_balance_after)
                        SELECT 
                            v_employee_id,
                            lt.id,
                            v_date,
                            v_date,
                            1,
                            'approved',
                            COALESCE(lr.leave_balance, 0) + 1
                        FROM public.leave_types lt
                        LEFT JOIN public.leave_requests lr 
                            ON lr.employee_id = v_employee_id 
                            AND lr.leave_type_id = lt.id
                            AND lr.status = 'approved'
                        WHERE lt.code = v_leave_type_code
                          AND lt.is_active = true
                          AND lt.is_deleted = false
                        ON CONFLICT DO NOTHING;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.fix_attendance_from_punches()
IS 'Corrects attendance for the last 5 days when punch records exist but status was 
marked absent/weekoff/holiday. Calculates total_hours, check_out_time, and break minutes.';

-- STEP 4: Backfill attendance data for April 10, 2026 with correct calculations
-- This will recalculate hours for all employees who punched on April 10
DO $$
DECLARE
    v_employee_record record;
    v_first_punch timestamptz;
    v_last_punch timestamptz;
    v_total_hours numeric(10, 2);
    v_total_break_minutes integer;
    v_punch_times timestamptz[];
    v_punch_count integer;
    i integer;
    break_start timestamptz;
    break_end timestamptz;
    break_duration_minutes integer;
BEGIN
    FOR v_employee_record IN
        SELECT 
            e.id as employee_id,
            up.biometric_code
        FROM public.employees e
        JOIN public.user_profiles up ON e.user_id = up.id
        WHERE e.is_active = true
          AND e.is_deleted = false
          AND up.is_active = true
          AND up.is_deleted = false
    LOOP
        -- Get punch times for April 10, 2026
        SELECT array_agg(pr.punch_time ORDER BY pr.punch_time)
        INTO v_punch_times
        FROM public.punch_records pr
        WHERE pr.enroll_number::text = v_employee_record.biometric_code
          AND pr.punch_time >= '2026-04-10 04:00:00'::timestamptz
          AND pr.punch_time < '2026-04-11 04:00:00'::timestamptz
          AND pr.is_active = true
          AND pr.is_deleted = false;

        -- If punches exist, update attendance
        IF v_punch_times IS NOT NULL AND array_length(v_punch_times, 1) > 0 THEN
            v_first_punch := v_punch_times[1];
            v_last_punch := v_punch_times[array_length(v_punch_times, 1)];
            v_punch_count := array_length(v_punch_times, 1);
            
            -- Calculate breaks
            v_total_break_minutes := 0;
            FOR i IN 2..v_punch_count-1 BY 2 LOOP
                IF i + 1 <= v_punch_count THEN
                    break_start := v_punch_times[i];
                    break_end := v_punch_times[i + 1];
                    break_duration_minutes := EXTRACT(EPOCH FROM (break_end - break_start)) / 60;
                    
                    IF break_duration_minutes >= 15 AND break_duration_minutes <= 240 THEN
                        v_total_break_minutes := v_total_break_minutes + break_duration_minutes;
                    END IF;
                END IF;
            END LOOP;
            
            -- Calculate total hours
            IF v_last_punch > v_first_punch THEN
                v_total_hours := ROUND(
                    GREATEST(0, 
                        (EXTRACT(EPOCH FROM (v_last_punch - v_first_punch)) / 3600.0) 
                        - (v_total_break_minutes / 60.0)
                    )::numeric, 
                    2
                );
            ELSE
                v_total_hours := 0;
            END IF;
            
            -- Update attendance record
            UPDATE public.employee_attendance
            SET 
                first_punch_in = v_first_punch,
                check_out_time = v_last_punch,
                total_hours = v_total_hours,
                total_break_minutes = v_total_break_minutes
            WHERE employee_id = v_employee_record.employee_id
              AND attendance_date = '2026-04-10'::date;
        END IF;
    END LOOP;
END $$;

COMMENT ON COLUMN public.employee_attendance.total_hours IS 'Total working hours excluding breaks, in decimal hours (e.g., 4.83 = 4 hours 50 minutes)';
COMMENT ON COLUMN public.employee_attendance.check_out_time IS 'Last punch time of the day';
COMMENT ON COLUMN public.employee_attendance.total_break_minutes IS 'Total break time in minutes (gaps between 15-240 mins)';
