-- Migration: Create backfill_attendance_counting function
-- Description: Backfill employee attendance and PL counting from punch records
-- This function processes all dates from start_date to yesterday, filling gaps
-- and determining status based on punches, week-offs, holidays, leaves, or absents

-- Drop existing function if it exists
DROP FUNCTION IF EXISTS public.backfill_attendance_counting(UUID, DATE);

-- Create the backfill_attendance_counting function
CREATE OR REPLACE FUNCTION public.backfill_attendance_counting(
    p_employee_id UUID,
    p_start_date DATE
)
RETURNS TABLE(
    total_days_processed INTEGER,
    present_days INTEGER,
    absent_days INTEGER,
    weekoff_days INTEGER,
    holiday_days INTEGER,
    leave_days INTEGER,
    days_counted_for_pl INTEGER,
    pls_awarded INTEGER,
    current_counter INTEGER,
    next_pl_at INTEGER,
    message TEXT
) AS $$
DECLARE
    v_user_id UUID;
    v_biometric_code TEXT;
    v_contract_id UUID;
    v_work_week_id UUID;
    v_work_week_found BOOLEAN := FALSE;
    
    -- Work week configuration (individual fields instead of RECORD)
    v_ww_monday BOOLEAN;
    v_ww_tuesday BOOLEAN;
    v_ww_wednesday BOOLEAN;
    v_ww_thursday BOOLEAN;
    v_ww_friday BOOLEAN;
    v_ww_saturday BOOLEAN;
    v_ww_sunday BOOLEAN;
    
    v_end_date DATE;
    
    -- Counters
    v_total_processed INTEGER := 0;
    v_present_count INTEGER := 0;
    v_absent_count INTEGER := 0;
    v_weekoff_count INTEGER := 0;
    v_holiday_count INTEGER := 0;
    v_leave_count INTEGER := 0;
    
    -- PL counting variables
    v_pl_leave_type_id UUID;
    v_current_counter INTEGER := 0;
    v_counting_start_date DATE;
    v_days_counted INTEGER := 0;
    v_pls_to_award INTEGER := 0;
    v_new_counter INTEGER := 0;
    v_new_start_date DATE;
    v_completion_year INTEGER;
    
    -- Loop variables
    v_current_date DATE;
    v_status TEXT;
    v_first_punch TIMESTAMP WITH TIME ZONE;
    v_is_working_day BOOLEAN;
    v_holiday_id UUID;
    v_leave_id UUID;
    v_day_of_week INTEGER;
BEGIN
    /* ----------------------------------------------------
       STEP 1 — Validate input and get employee info
    ---------------------------------------------------- */
    IF p_start_date IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 'ERROR: start date is required'::TEXT;
        RETURN;
    END IF;

    -- Get employee's user_id
    SELECT e.user_id
    INTO v_user_id
    FROM public.employees e
    WHERE e.id = p_employee_id
      AND e.is_active = TRUE
      AND e.is_deleted = FALSE;

    IF v_user_id IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 'ERROR: employee not found or inactive'::TEXT;
        RETURN;
    END IF;

    -- Get employee's biometric code
    SELECT up.biometric_code
    INTO v_biometric_code
    FROM public.user_profiles up
    WHERE up.id = v_user_id;

    IF v_biometric_code IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 'ERROR: biometric code not found'::TEXT;
        RETURN;
    END IF;

    /* ----------------------------------------------------
       STEP 2 — Get active contract and work week
    ---------------------------------------------------- */
    SELECT c.id
    INTO v_contract_id
    FROM public.contracts c
    WHERE c.employee_id = p_employee_id
      AND LOWER(c.status::TEXT) = 'active'
      AND c.is_active = TRUE
      AND c.is_deleted = FALSE
    LIMIT 1;

    IF v_contract_id IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 'ERROR: active contract not found'::TEXT;
        RETURN;
    END IF;

    -- Get work week configuration from employee_shifts table
    SELECT es.work_week_id
    INTO v_work_week_id
    FROM public.employee_shifts es
    WHERE es.employee_id = p_employee_id
      AND es.is_active = TRUE
      AND es.is_deleted = FALSE
    LIMIT 1;

    IF v_work_week_id IS NOT NULL THEN
        SELECT 
            ww.monday, ww.tuesday, ww.wednesday, ww.thursday,
            ww.friday, ww.saturday, ww.sunday
        INTO 
            v_ww_monday, v_ww_tuesday, v_ww_wednesday, v_ww_thursday,
            v_ww_friday, v_ww_saturday, v_ww_sunday
        FROM public.work_weeks ww
        WHERE ww.id = v_work_week_id
          AND ww.is_active = TRUE
          AND ww.is_deleted = FALSE;
        
        IF FOUND THEN
            v_work_week_found := TRUE;
        END IF;
    END IF;

    /* ----------------------------------------------------
       STEP 3 — Set date range (exclude current date)
    ---------------------------------------------------- */
    v_end_date := CURRENT_DATE - 1;

    IF p_start_date > v_end_date THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 'ERROR: start date is in the future or today'::TEXT;
        RETURN;
    END IF;

    /* ----------------------------------------------------
       STEP 4 — Process each date in range
    ---------------------------------------------------- */
    FOR v_current_date IN 
        SELECT generate_series(
            p_start_date::DATE,
            v_end_date::DATE,
            '1 day'::INTERVAL
        )::DATE
    LOOP
        v_status := NULL;
        v_first_punch := NULL;
        v_is_working_day := TRUE;
        v_holiday_id := NULL;
        v_leave_id := NULL;

        -- Get day of week (0=Sunday, 1=Monday, ..., 6=Saturday)
        v_day_of_week := EXTRACT(DOW FROM v_current_date);

        /* ----------------------------------------------------
           Priority 1: Check for punch records (4 AM cutoff)
        ---------------------------------------------------- */
        SELECT MIN(pr.punch_time)
        INTO v_first_punch
        FROM public.punch_records pr
        WHERE pr.enroll_number::TEXT = v_biometric_code
          AND CASE
              WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
              THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
              ELSE pr.punch_time::DATE
          END = v_current_date
          AND pr.is_active = TRUE
          AND pr.is_deleted = FALSE;

        IF v_first_punch IS NOT NULL THEN
            -- Has punch: mark as present
            v_status := 'present';
            v_present_count := v_present_count + 1;
        ELSE
            -- No punch: check other conditions in priority order
            
            /* ----------------------------------------------------
               Priority 2: Check for approved leaves
            ---------------------------------------------------- */
            SELECT lr.id
            INTO v_leave_id
            FROM public.leave_requests lr
            WHERE lr.employee_id = p_employee_id
              AND lr.start_date <= v_current_date
              AND lr.end_date >= v_current_date
              AND LOWER(lr.status::TEXT) = 'approved'
              AND lr.is_active = TRUE
              AND lr.is_deleted = FALSE
            LIMIT 1;

            IF v_leave_id IS NOT NULL THEN
                v_status := 'leave';
                v_leave_count := v_leave_count + 1;
            ELSE
                /* ----------------------------------------------------
                   Priority 3: Check for holidays
                ---------------------------------------------------- */
                SELECT h.id
                INTO v_holiday_id
                FROM public.holidays h
                LEFT JOIN public.contract_holidays ch 
                    ON ch.holiday_id = h.id 
                    AND ch.contract_id = v_contract_id
                WHERE h.start_date <= v_current_date
                  AND h.end_date >= v_current_date
                  AND h.is_active = TRUE
                  AND h.is_deleted = FALSE
                  AND (ch.is_applicable IS NULL OR ch.is_applicable = TRUE)
                LIMIT 1;

                IF v_holiday_id IS NOT NULL THEN
                    v_status := 'holiday';
                    v_holiday_count := v_holiday_count + 1;
                ELSE
                    /* ----------------------------------------------------
                       Priority 4: Check if it's a week-off (non-working day)
                    ---------------------------------------------------- */
                    IF v_work_week_found THEN
                        -- Determine if this day is a working day based on work week configuration
                        v_is_working_day := CASE v_day_of_week
                            WHEN 0 THEN v_ww_sunday
                            WHEN 1 THEN v_ww_monday
                            WHEN 2 THEN v_ww_tuesday
                            WHEN 3 THEN v_ww_wednesday
                            WHEN 4 THEN v_ww_thursday
                            WHEN 5 THEN v_ww_friday
                            WHEN 6 THEN v_ww_saturday
                            ELSE TRUE
                        END;

                        IF NOT v_is_working_day THEN
                            -- Non-working day: mark as weekoff
                            v_status := 'weekoff';
                            v_weekoff_count := v_weekoff_count + 1;
                        ELSE
                            -- Working day with no punch, leave, or holiday: mark as absent
                            v_status := 'absent';
                            v_absent_count := v_absent_count + 1;
                        END IF;
                    ELSE
                        -- No work week configured: mark as absent
                        v_status := 'absent';
                        v_absent_count := v_absent_count + 1;
                    END IF;
                END IF;
            END IF;
        END IF;

        /* ----------------------------------------------------
           Insert/Update employee_attendance
        ---------------------------------------------------- */
        INSERT INTO public.employee_attendance (
            employee_id,
            attendance_date,
            status,
            first_punch_in
        )
        VALUES (
            p_employee_id,
            v_current_date,
            v_status::attendance_status,
            v_first_punch
        )
        ON CONFLICT (employee_id, attendance_date)
        DO UPDATE SET
            status = EXCLUDED.status,
            first_punch_in = CASE
                WHEN EXCLUDED.first_punch_in IS NOT NULL
                THEN EXCLUDED.first_punch_in
                ELSE employee_attendance.first_punch_in
            END;

        v_total_processed := v_total_processed + 1;
    END LOOP;

    /* ----------------------------------------------------
       STEP 5 — PL Counting Logic
    ---------------------------------------------------- */
    
    -- Get PL leave type ID
    SELECT id INTO v_pl_leave_type_id
    FROM public.leave_types
    WHERE LOWER(code) = 'pl'
      AND is_active = TRUE
      AND is_deleted = FALSE
    LIMIT 1;

    -- Get employee's current counter and counting start date
    SELECT 
        COALESCE(consecutive_attendance_counter, 0),
        attendance_counting_start_date
    INTO v_current_counter, v_counting_start_date
    FROM public.employees
    WHERE id = p_employee_id;

    -- If no counting start date, set it to contract start date
    IF v_counting_start_date IS NULL THEN
        SELECT start_date INTO v_counting_start_date
        FROM public.contracts
        WHERE id = v_contract_id;
        
        -- Update employee with initial counting start date
        UPDATE public.employees
        SET attendance_counting_start_date = v_counting_start_date
        WHERE id = p_employee_id;
    END IF;

    -- Sync attendance_day_counting from employee_attendance
    INSERT INTO public.attendance_day_counting (
        employee_id,
        counting_date,
        is_counted,
        reason
    )
    SELECT
        p_employee_id,
        ea.attendance_date,
        CASE WHEN ea.status = 'present' THEN FALSE ELSE FALSE END,  -- Initially FALSE, will be marked TRUE when counted
        ea.status::TEXT
    FROM public.employee_attendance ea
    WHERE ea.employee_id = p_employee_id
      AND ea.attendance_date >= v_counting_start_date
      AND ea.attendance_date <= v_end_date
    ON CONFLICT (employee_id, counting_date) 
    DO UPDATE SET
        reason = EXCLUDED.reason;

    -- Process uncounted present days in chronological order
    FOR v_current_date IN
        SELECT adc.counting_date
        FROM public.attendance_day_counting adc
        WHERE adc.employee_id = p_employee_id
          AND adc.is_counted = FALSE
          AND adc.reason = 'present'
          AND adc.counting_date >= v_counting_start_date
        ORDER BY adc.counting_date ASC
    LOOP
        -- Increment counter
        v_current_counter := v_current_counter + 1;
        v_days_counted := v_days_counted + 1;

        -- Mark this day as counted
        UPDATE public.attendance_day_counting
        SET is_counted = TRUE,
            updated_at = CURRENT_TIMESTAMP
        WHERE employee_id = p_employee_id
          AND counting_date = v_current_date;

        -- Check if we've reached exactly a multiple of 50 days
        IF v_current_counter % 50 = 0 THEN
            -- Calculate how many PLs to award (should be counter / 50)
            v_pls_to_award := v_current_counter / 50;
            v_new_counter := 0;  -- Reset to 0 when exactly divisible by 50
            
            -- Get the year when the 50th day was completed (for leave_balance)
            v_completion_year := EXTRACT(YEAR FROM v_current_date);

            -- Find the new counting start date (next day after this milestone)
            v_new_start_date := v_current_date + INTERVAL '1 day';

            -- Award PLs to leave_balances (if PL leave type exists)
            IF v_pl_leave_type_id IS NOT NULL THEN
                INSERT INTO public.leave_balances (
                    employee_id,
                    leave_type_id,
                    contract_id,
                    year,
                    earned_days,
                    used_days,
                    carried_forward,
                    encashed_days
                )
                VALUES (
                    p_employee_id,
                    v_pl_leave_type_id,
                    v_contract_id,
                    v_completion_year,
                    v_pls_to_award,
                    0,
                    0,
                    0
                )
                ON CONFLICT (employee_id, leave_type_id, year, contract_id)
                DO UPDATE SET
                    earned_days = leave_balances.earned_days + EXCLUDED.earned_days;
                    -- remaining_days will be auto-calculated by the generated column
            END IF;

            -- Update employee's counter and start date
            UPDATE public.employees
            SET consecutive_attendance_counter = v_new_counter,
                attendance_counting_start_date = v_new_start_date
            WHERE id = p_employee_id;

            -- Update local variables
            v_current_counter := v_new_counter;
            v_counting_start_date := v_new_start_date;
        END IF;
    END LOOP;

    -- Always update employee's final counter after processing all days
    UPDATE public.employees
    SET consecutive_attendance_counter = v_current_counter,
        attendance_counting_start_date = COALESCE(v_counting_start_date, attendance_counting_start_date)
    WHERE id = p_employee_id;

    /* ----------------------------------------------------
       STEP 6 — SELF-CORRECTION: Final safety check
       Verify and fix counting_start_date if miscalculated
       This runs at the END to catch any errors in calculation
       WITHOUT affecting leave balances already awarded
    ---------------------------------------------------- */
    DECLARE
        v_counted_days_count INTEGER;
        v_expected_start_date DATE;
        v_old_start_date DATE;
    BEGIN
        -- Get current start date
        SELECT attendance_counting_start_date
        INTO v_old_start_date
        FROM public.employees
        WHERE id = p_employee_id;
        
        -- Count how many days are already marked as counted
        SELECT COUNT(*)
        INTO v_counted_days_count
        FROM public.attendance_day_counting
        WHERE employee_id = p_employee_id
          AND is_counted = TRUE
          AND reason = 'present';
        
        -- If there are counted days and a counter value, verify the start date
        IF v_counted_days_count > 0 AND v_current_counter > 0 THEN
            -- Find the correct start date: the day after the last counted batch
            -- Skip the current cycle's days (v_current_counter) to find the last milestone
            SELECT adc.counting_date + INTERVAL '1 day'
            INTO v_expected_start_date
            FROM public.attendance_day_counting adc
            WHERE adc.employee_id = p_employee_id
              AND adc.is_counted = TRUE
              AND adc.reason = 'present'
            ORDER BY adc.counting_date DESC
            OFFSET v_current_counter  -- Skip current cycle's days
            LIMIT 1;
            
            -- If we found an expected start date and it's different, fix it
            IF v_expected_start_date IS NOT NULL AND v_expected_start_date != v_old_start_date THEN
                UPDATE public.employees
                SET attendance_counting_start_date = v_expected_start_date
                WHERE id = p_employee_id;
                
                RAISE NOTICE 'SELF-CORRECTION: Fixed attendance_counting_start_date from % to % (counter=%)', 
                    v_old_start_date, v_expected_start_date, v_current_counter;
            END IF;
        END IF;
    END;

    /* ----------------------------------------------------
       STEP 7 — Return summary
    ---------------------------------------------------- */
    RETURN QUERY SELECT
        v_total_processed,
        v_present_count,
        v_absent_count,
        v_weekoff_count,
        v_holiday_count,
        v_leave_count,
        v_days_counted,
        v_pls_to_award,
        v_current_counter,
        (50 - v_current_counter)::INTEGER AS next_pl_at,
        'SUCCESS: Processed ' || v_total_processed || ' days, counted ' || v_days_counted || 
        ' for PL, awarded ' || v_pls_to_award || ' PL(s), counter at ' || v_current_counter || '/50'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION public.backfill_attendance_counting(UUID, DATE) TO authenticated;

-- Add comment explaining the function
COMMENT ON FUNCTION public.backfill_attendance_counting IS 
'Master function to fix employee attendance and calculate PL (Paid Leave) accrual.

ATTENDANCE PROCESSING:
Processes all dates from start_date to yesterday (excluding current date).
Fills gaps in attendance data and determines status based on priority:
1. Punch records (with 4 AM cutoff) → present
2. Approved leaves → leave
3. Holidays → holiday
4. Week-offs (from work_week configuration) → weekoff
5. Default → absent

PL COUNTING:
- Syncs attendance_day_counting table from employee_attendance
- Processes uncounted present days in chronological order
- Awards 1 PL for every 50 consecutive present days
- Handles overflow (e.g., 64 days = 1 PL + 14 counter, 103 days = 2 PLs + 3 counter)
- Calculates new counting start date as the date of the (PLs * 50 + 1)th counted day
- Awards PLs to leave_balances for the year when 50th day was completed
- Updates employees table with consecutive_attendance_counter and attendance_counting_start_date

All status values are stored in lowercase.';
