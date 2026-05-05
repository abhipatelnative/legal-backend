-- Migration: 20260408000001_fix_attendance_from_punches_pl_award.sql
--
-- Two fixes:
--
-- 1) RESTORE process_daily_leave_accrual:
--    The April 3 migration switched presence detection from punch_records to
--    attendance_records (total_hours). This caused many employees to be wrongly
--    marked absent, which then triggered fix_attendance_from_punches to "correct"
--    them and award PL unconditionally. Restoring the original punch_records-based
--    function eliminates the root cause.
--
-- 2) FIX fix_attendance_from_punches:
--    Was awarding 1 PL for EVERY corrected day regardless of the 50-day threshold.
--    Now only awards PL when counter % pl_earning_days = 0 (milestone hit).

-- ============================================================
-- PART 1: Restore process_daily_leave_accrual (punch_records)
-- ============================================================
DROP FUNCTION IF EXISTS public.process_daily_leave_accrual();
DROP FUNCTION IF EXISTS public.process_daily_leave_accrual(DATE);

CREATE OR REPLACE FUNCTION public.process_daily_leave_accrual()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_today DATE := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')::DATE;
    v_yesterday DATE := v_today - 1;
    v_current_year INTEGER := EXTRACT(YEAR FROM v_yesterday);

    emp RECORD;
    v_biometric_code TEXT;
    v_contract_id UUID;
    v_work_week_id UUID;
    v_pl_leave_type_id UUID;
    v_pl_earning_days INTEGER := 50;

    v_status TEXT;
    v_first_punch TIMESTAMP WITH TIME ZONE;
    v_is_working_day BOOLEAN;
    v_day_of_week INTEGER;
    v_leave_id UUID;
    v_holiday_id UUID;

    v_accrual_rule RECORD;
BEGIN
    SELECT id, GREATEST(COALESCE(pl_earning_days, 50), 1)
    INTO v_pl_leave_type_id, v_pl_earning_days
    FROM public.leave_types
    WHERE LOWER(code) = 'pl' AND is_active = TRUE AND is_deleted = FALSE
    LIMIT 1;

    v_pl_earning_days := GREATEST(COALESCE(v_pl_earning_days, 50), 1);

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
        SELECT biometric_code INTO v_biometric_code FROM public.user_profiles WHERE id = emp.user_id;

        SELECT id INTO v_contract_id FROM public.contracts
        WHERE employee_id = emp.id AND status = 'active' AND is_active = TRUE AND is_deleted = FALSE
        LIMIT 1;

        IF emp.attendance_counting_start_date IS NULL AND v_contract_id IS NOT NULL THEN
            SELECT start_date INTO emp.attendance_counting_start_date FROM public.contracts WHERE id = v_contract_id;
            UPDATE public.employees SET attendance_counting_start_date = emp.attendance_counting_start_date WHERE id = emp.id;
        END IF;

        IF v_contract_id IS NULL OR (emp.attendance_counting_start_date IS NOT NULL AND v_yesterday < emp.attendance_counting_start_date) THEN
            CONTINUE;
        END IF;

        v_day_of_week := EXTRACT(DOW FROM v_yesterday);

        -- Presence detection: uses punch_records directly (not attendance_records)
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
            SELECT id INTO v_leave_id FROM public.leave_requests
            WHERE employee_id = emp.id AND v_yesterday BETWEEN start_date AND end_date
              AND status = 'approved' AND is_active = TRUE AND is_deleted = FALSE
            LIMIT 1;

            IF v_leave_id IS NOT NULL THEN
                v_status := 'leave';
            ELSE
                SELECT h.id INTO v_holiday_id FROM public.holidays h
                LEFT JOIN public.contract_holidays ch ON ch.holiday_master_id = h.holiday_master_id AND ch.contract_id = v_contract_id
                WHERE v_yesterday BETWEEN h.start_date AND h.end_date
                  AND h.is_active = TRUE AND h.is_deleted = FALSE
                  AND (ch.is_applicable IS NULL OR ch.is_applicable = TRUE)
                LIMIT 1;

                IF v_holiday_id IS NOT NULL THEN
                    v_status := 'holiday';
                ELSE
                    SELECT es.work_week_id INTO v_work_week_id FROM public.employee_shifts es
                    WHERE es.contract_id = v_contract_id AND es.is_active = TRUE AND es.is_deleted = FALSE
                    LIMIT 1;

                    IF v_work_week_id IS NOT NULL THEN
                        SELECT
                            CASE v_day_of_week
                                WHEN 0 THEN ww.sunday
                                WHEN 1 THEN ww.monday
                                WHEN 2 THEN ww.tuesday
                                WHEN 3 THEN ww.wednesday
                                WHEN 4 THEN ww.thursday
                                WHEN 5 THEN ww.friday
                                WHEN 6 THEN ww.saturday
                                ELSE TRUE
                            END
                        INTO v_is_working_day
                        FROM public.work_weeks ww
                        WHERE id = v_work_week_id;

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

        INSERT INTO public.employee_attendance (employee_id, attendance_date, status, first_punch_in)
        VALUES (emp.id, v_yesterday, v_status::public.attendance_status, v_first_punch)
        ON CONFLICT (employee_id, attendance_date) DO UPDATE SET
            status = EXCLUDED.status,
            first_punch_in = COALESCE(EXCLUDED.first_punch_in, employee_attendance.first_punch_in);

        INSERT INTO public.attendance_day_counting (employee_id, counting_date, is_counted, reason)
        VALUES (emp.id, v_yesterday, (v_status = 'present'), v_status)
        ON CONFLICT (employee_id, counting_date) DO UPDATE SET
            reason = EXCLUDED.reason,
            is_counted = EXCLUDED.is_counted,
            updated_at = CURRENT_TIMESTAMP;

        IF v_status = 'present' THEN
            UPDATE public.employees
            SET consecutive_attendance_counter = consecutive_attendance_counter + 1
            WHERE id = emp.id;

            FOR v_accrual_rule IN
                SELECT lar.*, cl.days_allowed as cap
                FROM public.leave_accrual_rules lar
                JOIN public.contract_leaves cl ON cl.leave_type_id = lar.leave_type_id
                WHERE cl.contract_id = v_contract_id
                  AND lar.rule_type = 'CONSECUTIVE_ATTENDANCE'
            LOOP
                DECLARE
                    v_updated_counter INTEGER;
                BEGIN
                    SELECT consecutive_attendance_counter INTO v_updated_counter
                    FROM public.employees
                    WHERE id = emp.id;

                    IF v_updated_counter > 0 AND v_updated_counter % v_pl_earning_days = 0 THEN
                        INSERT INTO public.leave_balances (employee_id, leave_type_id, year, earned_days, used_days, carried_forward, encashed_days, contract_id)
                        VALUES (emp.id, v_accrual_rule.leave_type_id, v_current_year, v_updated_counter / v_pl_earning_days, 0, 0, 0, v_contract_id)
                        ON CONFLICT (employee_id, leave_type_id, year, contract_id)
                        DO UPDATE SET earned_days = leave_balances.earned_days + EXCLUDED.earned_days;

                        UPDATE public.employees
                        SET consecutive_attendance_counter = 0,
                            attendance_counting_start_date = v_yesterday + INTERVAL '1 day'
                        WHERE id = emp.id;
                    END IF;
                END;
            END LOOP;
        END IF;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_daily_leave_accrual() TO authenticated;

COMMENT ON FUNCTION public.process_daily_leave_accrual()
IS 'Daily cron job for attendance-based leave accrual. Uses punch_records for presence
detection and configurable leave_types.pl_earning_days milestone (default 50).';


-- ============================================================
-- PART 2: Fix fix_attendance_from_punches (PL threshold check)
-- ============================================================
DROP FUNCTION IF EXISTS public.fix_attendance_from_punches();

CREATE OR REPLACE FUNCTION public.fix_attendance_from_punches()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    backfill_days         INTEGER := 5;
    processing_date       DATE;
    rec                   RECORD;
    v_user_id             UUID;
    v_biometric_code      TEXT;
    v_punch_exists        BOOLEAN;
    v_first_punch_in      TIMESTAMP;
    v_active_contract_id  UUID;
    v_pl_leave_type_id    UUID;
    v_pl_earning_days     INTEGER := 50;
    v_leave_balance_id    UUID;
    v_current_counter     INTEGER;
    v_already_counted     BOOLEAN;
BEGIN
    -- Fetch configurable PL threshold from leave_types
    SELECT id, GREATEST(COALESCE(pl_earning_days, 50), 1)
    INTO v_pl_leave_type_id, v_pl_earning_days
    FROM public.leave_types
    WHERE LOWER(code) = 'pl'
      AND is_active = TRUE
      AND is_deleted = FALSE
    LIMIT 1;

    IF v_pl_leave_type_id IS NULL THEN
        RAISE EXCEPTION 'Paid Leave (PL) leave_type not found';
    END IF;

    -- Process each of the last N days
    FOR processing_date IN
        SELECT generate_series(
            CURRENT_DATE - backfill_days + 1,
            CURRENT_DATE,
            INTERVAL '1 day'
        )::DATE
    LOOP
        -- For each employee currently marked absent/weekoff/holiday on this date
        FOR rec IN
            SELECT ea.employee_id, ea.attendance_date
            FROM public.employee_attendance ea
            WHERE ea.attendance_date = processing_date
              AND LOWER(ea.status::TEXT) IN ('absent', 'weekoff', 'holiday')
        LOOP
            BEGIN
                -- Skip if this day is already counted toward PL
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

                -- Get employee info and current counter
                SELECT e.user_id, e.consecutive_attendance_counter
                INTO v_user_id, v_current_counter
                FROM public.employees e
                WHERE e.id = rec.employee_id
                  AND e.is_active = TRUE
                  AND e.is_deleted = FALSE;

                IF v_user_id IS NULL THEN
                    CONTINUE;
                END IF;

                -- Get biometric code for punch lookup
                SELECT up.biometric_code
                INTO v_biometric_code
                FROM public.user_profiles up
                WHERE up.id = v_user_id;

                IF v_biometric_code IS NULL THEN
                    CONTINUE;
                END IF;

                -- Check if a punch record exists for this date (4 AM cutoff)
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

                -- No punch found — nothing to correct
                IF NOT v_punch_exists THEN
                    CONTINUE;
                END IF;

                -- Correct attendance status to present
                UPDATE public.employee_attendance ea
                SET status = 'present',
                    first_punch_in = CASE
                        WHEN ea.first_punch_in IS NULL THEN v_first_punch_in
                        ELSE ea.first_punch_in
                    END
                WHERE ea.employee_id = rec.employee_id
                  AND ea.attendance_date = rec.attendance_date;

                -- Mark this day as counted in the PL day-counting table
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
                SET is_counted  = TRUE,
                    reason      = 'present',
                    updated_at  = CURRENT_TIMESTAMP;

                -- Increment the in-memory counter
                v_current_counter := v_current_counter + 1;

                -- -------------------------------------------------------
                -- PL AWARD: only when milestone is hit (counter % threshold = 0)
                -- This matches the same logic in process_daily_leave_accrual.
                -- -------------------------------------------------------
                IF v_current_counter > 0 AND v_current_counter % v_pl_earning_days = 0 THEN

                    -- Milestone reached: reset counter and set new counting start date
                    UPDATE public.employees
                    SET consecutive_attendance_counter  = 0,
                        attendance_counting_start_date  = rec.attendance_date + INTERVAL '1 day'
                    WHERE id = rec.employee_id;

                    -- Get the employee's active contract
                    SELECT c.id
                    INTO v_active_contract_id
                    FROM public.contracts c
                    WHERE c.employee_id = rec.employee_id
                      AND LOWER(c.status::TEXT) = 'active'
                      AND c.is_deleted = FALSE
                    LIMIT 1;

                    IF v_active_contract_id IS NULL THEN
                        v_current_counter := 0;
                        CONTINUE;
                    END IF;

                    -- Award 1 PL to leave_balances
                    SELECT lb.id
                    INTO v_leave_balance_id
                    FROM public.leave_balances lb
                    WHERE lb.employee_id   = rec.employee_id
                      AND lb.leave_type_id = v_pl_leave_type_id
                      AND lb.contract_id   = v_active_contract_id
                      AND lb.is_active     = TRUE
                      AND lb.is_deleted    = FALSE
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
                            EXTRACT(YEAR FROM rec.attendance_date)::INTEGER,
                            1,
                            v_active_contract_id,
                            TRUE,
                            FALSE
                        );
                    END IF;

                    -- Reset local counter so subsequent dates start fresh
                    v_current_counter := 0;

                ELSE
                    -- Milestone not reached — just update the counter in DB
                    UPDATE public.employees
                    SET consecutive_attendance_counter = v_current_counter
                    WHERE id = rec.employee_id;

                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    CONTINUE;
            END;
        END LOOP;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fix_attendance_from_punches() TO authenticated;

COMMENT ON FUNCTION public.fix_attendance_from_punches()
IS 'Corrects attendance for the last 5 days when a punch record exists but status was
absent/weekoff/holiday. Increments the consecutive_attendance_counter for each corrected
day and awards 1 PL only when the counter reaches the configured milestone
(leave_types.pl_earning_days, default 50). Does NOT award PL on every correction.';
