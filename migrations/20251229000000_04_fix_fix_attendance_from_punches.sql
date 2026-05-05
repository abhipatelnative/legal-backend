-- Migration 4: Fix fix_attendance_from_punches() to handle 'weekoff' (case-insensitive)
-- Description: Updates the function to check for weekoff in any case using LOWER()

DROP FUNCTION IF EXISTS public.fix_attendance_from_punches();

CREATE OR REPLACE FUNCTION public.fix_attendance_from_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    backfill_days INTEGER := 5;
    processing_date DATE;
    rec RECORD;
    v_user_id UUID;
    v_biometric_code TEXT;
    v_punch_exists BOOLEAN;
    v_first_punch_in TIMESTAMP;
    v_active_contract_id UUID;
    v_pl_leave_type_id UUID;
    v_leave_balance_id UUID;
    v_current_counter INTEGER;
    v_already_counted BOOLEAN;
BEGIN
    /* -----------------------------------------
       Resolve Paid Leave (PL)
    ----------------------------------------- */
    SELECT id
    INTO v_pl_leave_type_id
    FROM public.leave_types
    WHERE LOWER(code) = 'pl'
      AND is_active = TRUE
      AND is_deleted = FALSE
    LIMIT 1;
    
    IF v_pl_leave_type_id IS NULL THEN
        RAISE EXCEPTION 'Paid Leave (PL) leave_type not found';
    END IF;
    
    /* -----------------------------------------
       Loop over backfill window
    ----------------------------------------- */
    FOR processing_date IN
        SELECT generate_series(
            CURRENT_DATE - backfill_days + 1,
            CURRENT_DATE,
            INTERVAL '1 day'
        )::DATE
    LOOP
        /* -------------------------------------
           Candidate attendance rows (case-insensitive check for weekoff)
        ------------------------------------- */
        FOR rec IN
            SELECT ea.employee_id, ea.attendance_date
            FROM public.employee_attendance ea
            WHERE ea.attendance_date = processing_date
              AND LOWER(ea.status::TEXT) IN ('absent', 'weekoff', 'holiday')  -- Case-insensitive: accepts WeekOff, weekoff, etc.
        LOOP
            BEGIN
                /* ---------------------------------
                   Skip if already counted
                --------------------------------- */
                SELECT EXISTS (
                    SELECT 1
                    FROM public.attendance_day_counting adc
                    WHERE adc.employee_id = rec.employee_id
                      AND adc.counting_date = rec.attendance_date
                      AND adc.is_counted = TRUE
                )
                INTO v_already_counted;
                
                IF v_already_counted THEN
                    CONTINUE;
                END IF;
                
                /* ---------------------------------
                   Resolve employee
                --------------------------------- */
                SELECT e.user_id, e.consecutive_attendance_counter
                INTO v_user_id, v_current_counter
                FROM public.employees e
                WHERE e.id = rec.employee_id
                  AND e.is_active = TRUE
                  AND e.is_deleted = FALSE;
                  
                IF v_user_id IS NULL THEN
                    CONTINUE;
                END IF;
                
                /* ---------------------------------
                   Resolve biometric code
                --------------------------------- */
                SELECT up.biometric_code
                INTO v_biometric_code
                FROM public.user_profiles up
                WHERE up.id = v_user_id;
                
                IF v_biometric_code IS NULL THEN
                    CONTINUE;
                END IF;
                
                /* ---------------------------------
                   Check punch existence + get first punch
                   🌙 4 AM CUTOFF APPLIED HERE
                --------------------------------- */
                SELECT
                    COUNT(*) > 0,
                    MIN(pr.punch_time)
                INTO
                    v_punch_exists,
                    v_first_punch_in
                FROM public.punch_records pr
                WHERE pr.enroll_number::TEXT = v_biometric_code
                  AND CASE 
                        WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 
                        THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
                        ELSE pr.punch_time::DATE
                      END = rec.attendance_date
                  AND pr.is_active = TRUE
                  AND pr.is_deleted = FALSE;
                  
                IF NOT v_punch_exists THEN
                    CONTINUE;
                END IF;
                
                /* ---------------------------------
                   Mark attendance PRESENT
                   + set first_punch_in ONLY if NULL
                --------------------------------- */
                UPDATE public.employee_attendance ea
                SET status = 'present',
                    first_punch_in = CASE
                        WHEN ea.first_punch_in IS NULL
                        THEN v_first_punch_in
                        ELSE ea.first_punch_in
                    END
                WHERE ea.employee_id = rec.employee_id
                  AND ea.attendance_date = rec.attendance_date;
                  
                /* ---------------------------------
                   Insert attendance_day_counting
                --------------------------------- */
                INSERT INTO public.attendance_day_counting (
                    employee_id,
                    counting_date,
                    is_counted,
                    reason
                )
                VALUES (
                    rec.employee_id,
                    rec.attendance_date,
                    TRUE,
                    'present'
                )
                ON CONFLICT (employee_id, counting_date)
                DO UPDATE
                SET is_counted = TRUE,
                    reason = 'present',
                    updated_at = CURRENT_TIMESTAMP;
                    
                /* ---------------------------------
                   Increment consecutive counter
                --------------------------------- */
                v_current_counter := v_current_counter + 1;
                
                IF v_current_counter >= 50 THEN
                    UPDATE public.employees
                    SET consecutive_attendance_counter = 0,
                        attendance_counting_start_date = CURRENT_DATE
                    WHERE id = rec.employee_id;
                ELSE
                    UPDATE public.employees
                    SET consecutive_attendance_counter = v_current_counter
                    WHERE id = rec.employee_id;
                END IF;
                
                /* ---------------------------------
                   Resolve active contract
                --------------------------------- */
                SELECT c.id
                INTO v_active_contract_id
                FROM public.contracts c
                WHERE c.employee_id = rec.employee_id
                  AND LOWER(c.status::TEXT) = 'active'
                  AND c.is_deleted = FALSE
                LIMIT 1;
                
                IF v_active_contract_id IS NULL THEN
                    CONTINUE;
                END IF;
                
                /* ---------------------------------
                   Resolve leave balance (PL)
                --------------------------------- */
                SELECT lb.id
                INTO v_leave_balance_id
                FROM public.leave_balances lb
                WHERE lb.employee_id = rec.employee_id
                  AND lb.leave_type_id = v_pl_leave_type_id
                  AND lb.contract_id = v_active_contract_id
                  AND lb.is_active = TRUE
                  AND lb.is_deleted = FALSE
                LIMIT 1;
                
                IF v_leave_balance_id IS NOT NULL THEN
                    UPDATE public.leave_balances
                    SET earned_days = COALESCE(earned_days, 0) + 1
                    WHERE id = v_leave_balance_id;
                ELSE
                    INSERT INTO public.leave_balances (
                        employee_id,
                        leave_type_id,
                        year,
                        earned_days,
                        contract_id,
                        is_active,
                        is_deleted
                    )
                    VALUES (
                        rec.employee_id,
                        v_pl_leave_type_id,
                        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
                        1,
                        v_active_contract_id,
                        TRUE,
                        FALSE
                    );
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    CONTINUE;
            END;
        END LOOP;
    END LOOP;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.fix_attendance_from_punches() TO authenticated;

-- Add comment
COMMENT ON FUNCTION public.fix_attendance_from_punches() 
IS 'Backfills attendance for days with punch records. Uses case-insensitive check for weekoff (accepts WeekOff, weekoff, etc.)';
