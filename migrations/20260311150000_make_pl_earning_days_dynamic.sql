-- Migration: Make PL earning day thresholds dynamically configurable
-- Description: Replaces hardcoded 50-day PL milestone logic with leave_types.pl_earning_days

-- 1) Add configurable PL earning days on leave types
ALTER TABLE public.leave_types
ADD COLUMN IF NOT EXISTS pl_earning_days INTEGER;

UPDATE public.leave_types
SET pl_earning_days = 50
WHERE pl_earning_days IS NULL OR pl_earning_days <= 0;

ALTER TABLE public.leave_types
ALTER COLUMN pl_earning_days SET DEFAULT 50;

ALTER TABLE public.leave_types
ALTER COLUMN pl_earning_days SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'leave_types_pl_earning_days_check'
    ) THEN
        ALTER TABLE public.leave_types
        ADD CONSTRAINT leave_types_pl_earning_days_check CHECK (pl_earning_days > 0);
    END IF;
END $$;

-- 2) Update process_daily_leave_accrual to use configurable PL earning days
DROP FUNCTION IF EXISTS public.process_daily_leave_accrual();

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
IS 'Daily cron job for attendance-based leave accrual using configurable leave_types.pl_earning_days milestone.';

-- 3) Update backfill_attendance_counting to use configurable PL earning days
DROP FUNCTION IF EXISTS public.backfill_attendance_counting(UUID, DATE);

CREATE OR REPLACE FUNCTION public.backfill_attendance_counting(p_employee_id UUID, p_start_date DATE)
RETURNS TABLE(total_days_processed INTEGER, present_days INTEGER, absent_days INTEGER, weekoff_days INTEGER, holiday_days INTEGER, leave_days INTEGER, days_counted_for_pl INTEGER, pls_awarded INTEGER, current_counter INTEGER, next_pl_at INTEGER, message TEXT) AS $$
DECLARE
    v_user_id UUID; v_biometric_code TEXT; v_contract_id UUID; v_work_week_id UUID; v_work_week_found BOOLEAN := FALSE;
    v_ww_monday BOOLEAN; v_ww_tuesday BOOLEAN; v_ww_wednesday BOOLEAN; v_ww_thursday BOOLEAN; v_ww_friday BOOLEAN; v_ww_saturday BOOLEAN; v_ww_sunday BOOLEAN;
    v_end_date DATE; v_total_processed INTEGER := 0; v_present_count INTEGER := 0; v_absent_count INTEGER := 0; v_weekoff_count INTEGER := 0; v_holiday_count INTEGER := 0; v_leave_count INTEGER := 0;
    v_pl_leave_type_id UUID; v_pl_earning_days INTEGER := 50; v_current_counter INTEGER := 0; v_counting_start_date DATE; v_days_counted INTEGER := 0; v_pls_to_award INTEGER := 0; v_new_counter INTEGER := 0; v_new_start_date DATE; v_completion_year INTEGER;
    v_current_date DATE; v_status TEXT; v_first_punch TIMESTAMP WITH TIME ZONE; v_is_working_day BOOLEAN; v_holiday_id UUID; v_leave_id UUID; v_day_of_week INTEGER;
    v_leave_total_days numeric; v_leave_salary_payable boolean; v_leave_allow_hourly boolean; v_leave_max_hours integer; v_leave_has_time_window boolean;
BEGIN
    IF p_start_date IS NULL THEN RETURN QUERY SELECT 0,0,0,0,0,0,0,0,0,0,'ERROR: start date required'::TEXT; RETURN; END IF;
    SELECT e.user_id INTO v_user_id FROM public.employees e WHERE e.id = p_employee_id AND e.is_active = TRUE;
    IF v_user_id IS NULL THEN RETURN QUERY SELECT 0,0,0,0,0,0,0,0,0,0,'ERROR: employee not found'::TEXT; RETURN; END IF;
    SELECT up.biometric_code INTO v_biometric_code FROM public.user_profiles up WHERE up.id = v_user_id;
    SELECT c.id INTO v_contract_id FROM public.contracts c WHERE c.employee_id = p_employee_id AND LOWER(c.status::TEXT) = 'active' LIMIT 1;
    IF v_contract_id IS NULL THEN RETURN QUERY SELECT 0,0,0,0,0,0,0,0,0,0,'ERROR: active contract not found'::TEXT; RETURN; END IF;
    SELECT es.work_week_id INTO v_work_week_id FROM public.employee_shifts es WHERE es.contract_id = v_contract_id AND es.is_active = TRUE LIMIT 1;
    IF v_work_week_id IS NOT NULL THEN
        SELECT ww.monday, ww.tuesday, ww.wednesday, ww.thursday, ww.friday, ww.saturday, ww.sunday INTO v_ww_monday, v_ww_tuesday, v_ww_wednesday, v_ww_thursday, v_ww_friday, v_ww_saturday, v_ww_sunday FROM public.work_weeks ww WHERE ww.id = v_work_week_id;
        v_work_week_found := TRUE;
    END IF;
    v_end_date := CURRENT_DATE - 1;
    FOR v_current_date IN SELECT generate_series(p_start_date::DATE, v_end_date::DATE, '1 day'::INTERVAL)::DATE LOOP
        v_status := NULL; v_first_punch := NULL; v_day_of_week := EXTRACT(DOW FROM v_current_date);
        SELECT MIN(pr.punch_time) INTO v_first_punch FROM public.punch_records pr WHERE pr.enroll_number::TEXT = v_biometric_code AND CASE WHEN EXTRACT(HOUR FROM pr.punch_time) < 4 THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE ELSE pr.punch_time::DATE END = v_current_date;
        IF v_first_punch IS NOT NULL THEN v_status := 'present'; v_present_count := v_present_count + 1;
        ELSE
            SELECT lr.id, lr.total_days, COALESCE(lt.salary_payable, FALSE), COALESCE(lt.allow_hourly, FALSE), lt.max_hours_per_day, (lr.start_time IS NOT NULL AND lr.end_time IS NOT NULL)
            INTO v_leave_id, v_leave_total_days, v_leave_salary_payable, v_leave_allow_hourly, v_leave_max_hours, v_leave_has_time_window
            FROM public.leave_requests lr
            JOIN public.leave_types lt ON lt.id = lr.leave_type_id
            WHERE lr.employee_id = p_employee_id
              AND lr.start_date <= v_current_date
              AND lr.end_date >= v_current_date
              AND LOWER(lr.status::TEXT) = 'approved'
            LIMIT 1;

            IF v_leave_id IS NOT NULL THEN
                IF COALESCE(v_leave_total_days, 0) = 0.5 THEN
                    v_status := 'absent'; v_absent_count := v_absent_count + 1;
                ELSIF v_leave_salary_payable
                      AND v_leave_allow_hourly
                      AND v_leave_max_hours IS NOT NULL
                      AND v_leave_max_hours > 0
                      AND v_leave_has_time_window
                THEN
                    v_status := 'present'; v_present_count := v_present_count + 1;
                ELSE
                    v_status := 'leave'; v_leave_count := v_leave_count + 1;
                END IF;
            ELSE
                SELECT h.id INTO v_holiday_id FROM public.holidays h LEFT JOIN public.contract_holidays ch ON ch.holiday_master_id = h.holiday_master_id AND ch.contract_id = v_contract_id WHERE h.start_date <= v_current_date AND h.end_date >= v_current_date AND h.is_active = TRUE AND (ch.is_applicable IS NULL OR ch.is_applicable = TRUE) LIMIT 1;
                IF v_holiday_id IS NOT NULL THEN v_status := 'holiday'; v_holiday_count := v_holiday_count + 1;
                ELSE
                    IF v_work_week_found THEN
                        v_is_working_day := CASE v_day_of_week WHEN 0 THEN v_ww_sunday WHEN 1 THEN v_ww_monday WHEN 2 THEN v_ww_tuesday WHEN 3 THEN v_ww_wednesday WHEN 4 THEN v_ww_thursday WHEN 5 THEN v_ww_friday WHEN 6 THEN v_ww_saturday ELSE TRUE END;
                        IF NOT v_is_working_day THEN v_status := 'weekoff'; v_weekoff_count := v_weekoff_count + 1; ELSE v_status := 'absent'; v_absent_count := v_absent_count + 1; END IF;
                    ELSE v_status := 'absent'; v_absent_count := v_absent_count + 1; END IF;
                END IF;
            END IF;
        END IF;
        INSERT INTO public.employee_attendance (employee_id, attendance_date, status, first_punch_in) VALUES (p_employee_id, v_current_date, v_status::attendance_status, v_first_punch) ON CONFLICT (employee_id, attendance_date) DO UPDATE SET status = EXCLUDED.status, first_punch_in = COALESCE(EXCLUDED.first_punch_in, employee_attendance.first_punch_in);
        v_total_processed := v_total_processed + 1;
    END LOOP;

    SELECT id, GREATEST(COALESCE(pl_earning_days, 50), 1)
    INTO v_pl_leave_type_id, v_pl_earning_days
    FROM public.leave_types
    WHERE LOWER(code) = 'pl' AND is_active = TRUE
    LIMIT 1;

    v_pl_earning_days := GREATEST(COALESCE(v_pl_earning_days, 50), 1);

    SELECT COALESCE(consecutive_attendance_counter, 0), attendance_counting_start_date INTO v_current_counter, v_counting_start_date FROM public.employees WHERE id = p_employee_id;
    IF v_counting_start_date IS NULL THEN SELECT start_date INTO v_counting_start_date FROM public.contracts WHERE id = v_contract_id; UPDATE public.employees SET attendance_counting_start_date = v_counting_start_date WHERE id = p_employee_id; END IF;
    INSERT INTO public.attendance_day_counting (employee_id, counting_date, is_counted, reason) SELECT p_employee_id, ea.attendance_date, FALSE, ea.status::TEXT FROM public.employee_attendance ea WHERE ea.employee_id = p_employee_id AND ea.attendance_date >= v_counting_start_date AND ea.attendance_date <= v_end_date ON CONFLICT (employee_id, counting_date) DO UPDATE SET reason = EXCLUDED.reason;
    FOR v_current_date IN SELECT adc.counting_date FROM public.attendance_day_counting adc WHERE adc.employee_id = p_employee_id AND adc.is_counted = FALSE AND adc.reason = 'present' AND adc.counting_date >= v_counting_start_date ORDER BY adc.counting_date ASC LOOP
        v_current_counter := v_current_counter + 1; v_days_counted := v_days_counted + 1;
        UPDATE public.attendance_day_counting SET is_counted = TRUE, updated_at = CURRENT_TIMESTAMP WHERE employee_id = p_employee_id AND counting_date = v_current_date;
        IF v_current_counter % v_pl_earning_days = 0 THEN
            v_pls_to_award := v_current_counter / v_pl_earning_days; v_new_counter := 0; v_completion_year := EXTRACT(YEAR FROM v_current_date); v_new_start_date := v_current_date + INTERVAL '1 day';
            IF v_pl_leave_type_id IS NOT NULL THEN INSERT INTO public.leave_balances (employee_id, leave_type_id, contract_id, year, earned_days) VALUES (p_employee_id, v_pl_leave_type_id, v_contract_id, v_completion_year, v_pls_to_award) ON CONFLICT (employee_id, leave_type_id, year, contract_id) DO UPDATE SET earned_days = leave_balances.earned_days + EXCLUDED.earned_days; END IF;
            UPDATE public.employees SET consecutive_attendance_counter = v_new_counter, attendance_counting_start_date = v_new_start_date WHERE id = p_employee_id;
            v_current_counter := v_new_counter; v_counting_start_date := v_new_start_date;
        END IF;
    END LOOP;
    UPDATE public.employees SET consecutive_attendance_counter = v_current_counter, attendance_counting_start_date = COALESCE(v_counting_start_date, attendance_counting_start_date) WHERE id = p_employee_id;
    RETURN QUERY SELECT v_total_processed, v_present_count, v_absent_count, v_weekoff_count, v_holiday_count, v_leave_count, v_days_counted, v_pls_to_award, v_current_counter, GREATEST(v_pl_earning_days - v_current_counter, 0)::INTEGER, 'SUCCESS'::TEXT;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION public.backfill_attendance_counting(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION public.backfill_attendance_counting(UUID, DATE)
IS 'Backfills attendance/PL accrual using configurable leave_types.pl_earning_days milestone.';

-- 4) Update fix_attendance_from_punches to use configurable PL earning days
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
    v_pl_earning_days INTEGER := 50;
    v_leave_balance_id UUID;
    v_current_counter INTEGER;
    v_already_counted BOOLEAN;
BEGIN
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

    FOR processing_date IN
        SELECT generate_series(
            CURRENT_DATE - backfill_days + 1,
            CURRENT_DATE,
            INTERVAL '1 day'
        )::DATE
    LOOP
        FOR rec IN
            SELECT ea.employee_id, ea.attendance_date
            FROM public.employee_attendance ea
            WHERE ea.attendance_date = processing_date
              AND LOWER(ea.status::TEXT) IN ('absent', 'weekoff', 'holiday')
        LOOP
            BEGIN
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

                SELECT e.user_id, e.consecutive_attendance_counter
                INTO v_user_id, v_current_counter
                FROM public.employees e
                WHERE e.id = rec.employee_id
                  AND e.is_active = TRUE
                  AND e.is_deleted = FALSE;

                IF v_user_id IS NULL THEN
                    CONTINUE;
                END IF;

                SELECT up.biometric_code
                INTO v_biometric_code
                FROM public.user_profiles up
                WHERE up.id = v_user_id;

                IF v_biometric_code IS NULL THEN
                    CONTINUE;
                END IF;

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

                UPDATE public.employee_attendance ea
                SET status = 'present',
                    first_punch_in = CASE
                        WHEN ea.first_punch_in IS NULL THEN v_first_punch_in
                        ELSE ea.first_punch_in
                    END
                WHERE ea.employee_id = rec.employee_id
                  AND ea.attendance_date = rec.attendance_date;

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

                v_current_counter := v_current_counter + 1;

                IF v_current_counter >= v_pl_earning_days THEN
                    UPDATE public.employees
                    SET consecutive_attendance_counter = 0,
                        attendance_counting_start_date = CURRENT_DATE
                    WHERE id = rec.employee_id;
                ELSE
                    UPDATE public.employees
                    SET consecutive_attendance_counter = v_current_counter
                    WHERE id = rec.employee_id;
                END IF;

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

GRANT EXECUTE ON FUNCTION public.fix_attendance_from_punches() TO authenticated;

COMMENT ON FUNCTION public.fix_attendance_from_punches()
IS 'Backfills attendance from punch records using configurable leave_types.pl_earning_days milestone.';
