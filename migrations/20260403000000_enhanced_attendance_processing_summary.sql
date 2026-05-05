-- Migration: 20260403000000_enhanced_attendance_processing_summary.sql
-- Description: Drops conflicting process_daily_leave_accrual overloads and recreates
--              a single DATE-parameter version with default target date.
-- Priority: Working Hours > Leaves > Holidays > Weekoffs.

-- 1. DROP ALL EXISTING OVERLOADS TO AVOID AMBIGUOUS NO-ARG CALLS
DROP FUNCTION IF EXISTS public.process_daily_leave_accrual();
DROP FUNCTION IF EXISTS public.process_daily_leave_accrual(DATE);

-- 2. CREATE THE UPDATED FUNCTION
CREATE OR REPLACE FUNCTION public.process_daily_leave_accrual(
    p_target_date DATE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')::DATE - 1
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_today DATE := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Kolkata')::DATE;
    v_yesterday DATE := p_target_date;
    v_current_year INTEGER := EXTRACT(YEAR FROM v_yesterday);

    emp RECORD;
    v_biometric_code TEXT;
    v_contract_id UUID;
    v_work_week_id UUID;
    v_pl_leave_type_id UUID;
    v_pl_earning_days INTEGER := 50;

    v_status TEXT;
    v_first_punch TIMESTAMP WITH TIME ZONE;
    v_required_hours NUMERIC(5,2) := 8.0;
    v_total_hours NUMERIC(5,2) := 0.0;
    v_is_working_day BOOLEAN;
    v_day_of_week INTEGER;
    v_leave_id UUID;
    v_is_hour_leave BOOLEAN := FALSE;
    v_holiday_id UUID;

    v_accrual_rule RECORD;
BEGIN
    -- Setup PL accrual configuration
    SELECT id, GREATEST(COALESCE(pl_earning_days, 50), 1)
    INTO v_pl_leave_type_id, v_pl_earning_days
    FROM public.leave_types
    WHERE LOWER(code) = 'pl'
      AND is_active = TRUE
      AND is_deleted = FALSE
    LIMIT 1;

    v_pl_earning_days := GREATEST(COALESCE(v_pl_earning_days, 50), 1);

    -- Loop through active employees
    FOR emp IN
        SELECT
            e.id,
            e.user_id,
            e.consecutive_attendance_counter,
            e.attendance_counting_start_date,
            e.current_contract_id
        FROM public.employees e
        JOIN public.contracts c
          ON e.id = c.employee_id
        WHERE e.is_active = TRUE
          AND e.employment_status = 'active'
          AND c.status = 'active'
          AND c.is_active = TRUE
          AND c.is_deleted = FALSE
        GROUP BY
            e.id,
            e.user_id,
            e.consecutive_attendance_counter,
            e.attendance_counting_start_date,
            e.current_contract_id
    LOOP
        -- Fetch biometric code
        SELECT biometric_code
        INTO v_biometric_code
        FROM public.user_profiles
        WHERE id = emp.user_id;

        -- Resolve active contract, work week, and required hours
        SELECT
            c.id,
            c.work_week_id,
            COALESCE(
                EXTRACT(EPOCH FROM (s.end_time - s.start_time)) / 3600
                - COALESCE(s.break_duration, 60) / 60.0,
                8.0
            )
        INTO v_contract_id, v_work_week_id, v_required_hours
        FROM public.contracts c
        LEFT JOIN public.employee_shifts es
          ON es.contract_id = c.id
        LEFT JOIN public.shifts s
          ON es.shift_id = s.id
        WHERE c.employee_id = emp.id
          AND c.status = 'active'
          AND c.is_active = TRUE
        LIMIT 1;

        IF v_contract_id IS NULL
           OR (
               emp.attendance_counting_start_date IS NOT NULL
               AND v_yesterday < emp.attendance_counting_start_date
           ) THEN
            CONTINUE;
        END IF;

        -- Get processed hours from attendance_records
        SELECT total_hours, check_in
        INTO v_total_hours, v_first_punch
        FROM public.attendance_records
        WHERE user_profile_id = emp.user_id
          AND attendance_date = v_yesterday
        LIMIT 1;

        v_total_hours := COALESCE(v_total_hours, 0);
        v_day_of_week := EXTRACT(DOW FROM v_yesterday);

        -- Priority logic: Working Hours > Leaves > Holidays > Weekoffs
        IF v_total_hours >= v_required_hours THEN
            v_status := 'present';
        ELSE
            SELECT
                lr.id,
                (lr.start_time IS NOT NULL AND lr.end_time IS NOT NULL)
            INTO v_leave_id, v_is_hour_leave
            FROM public.leave_requests lr
            WHERE lr.employee_id = emp.id
              AND v_yesterday BETWEEN lr.start_date AND lr.end_date
              AND lr.status = 'approved'
              AND lr.is_active = TRUE
              AND lr.is_deleted = FALSE
            LIMIT 1;

            IF v_leave_id IS NOT NULL THEN
                IF v_is_hour_leave THEN
                    v_status := 'present';
                ELSE
                    v_status := 'leave';
                END IF;
            ELSE
                SELECT h.id
                INTO v_holiday_id
                FROM public.holidays h
                LEFT JOIN public.contract_holidays ch
                  ON ch.holiday_master_id = h.holiday_master_id
                 AND ch.contract_id = v_contract_id
                WHERE v_yesterday BETWEEN h.start_date AND h.end_date
                  AND h.is_active = TRUE
                  AND h.is_deleted = FALSE
                  AND (ch.is_applicable IS NULL OR ch.is_applicable = TRUE)
                LIMIT 1;

                IF v_holiday_id IS NOT NULL THEN
                    v_status := 'holiday';
                ELSE
                    SELECT CASE v_day_of_week
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
                        v_status := CASE
                            WHEN v_total_hours > 0 THEN 'half_day'
                            ELSE 'absent'
                        END;
                    END IF;
                END IF;
            END IF;
        END IF;

        -- Finalize attendance summary
        INSERT INTO public.employee_attendance (
            employee_id,
            attendance_date,
            status,
            first_punch_in
        )
        VALUES (
            emp.id,
            v_yesterday,
            v_status::public.attendance_status,
            v_first_punch
        )
        ON CONFLICT (employee_id, attendance_date) DO UPDATE
        SET status = EXCLUDED.status,
            first_punch_in = COALESCE(
                EXCLUDED.first_punch_in,
                employee_attendance.first_punch_in
            );

        -- Record counting for leave accrual
        INSERT INTO public.attendance_day_counting (
            employee_id,
            counting_date,
            is_counted,
            reason
        )
        VALUES (
            emp.id,
            v_yesterday,
            (v_status = 'present'),
            v_status
        )
        ON CONFLICT (employee_id, counting_date) DO UPDATE
        SET reason = EXCLUDED.reason,
            is_counted = EXCLUDED.is_counted,
            updated_at = CURRENT_TIMESTAMP;

        -- Process accrual only for counted present days
        IF v_status = 'present' THEN
            UPDATE public.employees
            SET consecutive_attendance_counter = consecutive_attendance_counter + 1
            WHERE id = emp.id;

            FOR v_accrual_rule IN
                SELECT lar.*
                FROM public.leave_accrual_rules lar
                JOIN public.contract_leaves cl
                  ON cl.leave_type_id = lar.leave_type_id
                WHERE cl.contract_id = v_contract_id
                  AND lar.rule_type = 'CONSECUTIVE_ATTENDANCE'
            LOOP
                DECLARE
                    v_updated_counter INTEGER;
                BEGIN
                    SELECT consecutive_attendance_counter
                    INTO v_updated_counter
                    FROM public.employees
                    WHERE id = emp.id;

                    IF v_updated_counter > 0
                       AND v_updated_counter % v_pl_earning_days = 0 THEN
                        INSERT INTO public.leave_balances (
                            employee_id,
                            leave_type_id,
                            year,
                            earned_days,
                            used_days,
                            carried_forward,
                            encashed_days,
                            contract_id
                        )
                        VALUES (
                            emp.id,
                            v_accrual_rule.leave_type_id,
                            v_current_year,
                            1,
                            0,
                            0,
                            0,
                            v_contract_id
                        )
                        ON CONFLICT (employee_id, leave_type_id, year, contract_id)
                        DO UPDATE
                        SET earned_days = leave_balances.earned_days + EXCLUDED.earned_days;

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

GRANT EXECUTE ON FUNCTION public.process_daily_leave_accrual(DATE) TO authenticated;

COMMENT ON FUNCTION public.process_daily_leave_accrual(DATE)
IS 'Daily attendance summary and leave accrual processor. Keeps only the DATE signature to prevent ambiguous no-arg calls while allowing default-date execution.';
