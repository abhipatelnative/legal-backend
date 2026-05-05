-- Migration: Update backfill_attendance_counting to exclude current date
-- Description: Modify the function to not consider the current date for any calculation
-- This ensures only completed days are counted towards attendance

-- Drop the existing function first to avoid return type conflicts
DROP FUNCTION IF EXISTS public.backfill_attendance_counting(UUID, DATE);

-- Create the updated function
CREATE OR REPLACE FUNCTION public.backfill_attendance_counting(
    p_employee_id UUID,
    p_start_date DATE
)
RETURNS TABLE(
    total_days_counted INTEGER,
    current_counter INTEGER,
    leaves_earned INTEGER,
    message TEXT
) AS $$
DECLARE
    v_user_id UUID;
    v_biometric_code TEXT;
    v_contract_id UUID;
    v_old_contract_start_date DATE;

    v_counted_days INTEGER := 0;
    v_current_counter INTEGER := 0;

    v_pl_leave_type_id UUID;
    v_should_have_pl INTEGER := 0;
    v_already_have_pl INTEGER := 0;
    v_pl_delta INTEGER := 0;
BEGIN
    /* ----------------------------------------------------
       STEP 1 — Validate input
    ---------------------------------------------------- */
    IF p_start_date IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 'ERROR: contract start date is required';
        RETURN;
    END IF;

    /* ----------------------------------------------------
       STEP 2 — Resolve employee & biometric
    ---------------------------------------------------- */
    SELECT e.user_id
    INTO v_user_id
    FROM public.employees e
    WHERE e.id = p_employee_id
      AND e.is_active = TRUE
      AND e.is_deleted = FALSE;

    IF v_user_id IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 'ERROR: employee not found';
        RETURN;
    END IF;

    SELECT up.biometric_code
    INTO v_biometric_code
    FROM public.user_profiles up
    WHERE up.id = v_user_id;

    IF v_biometric_code IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 'ERROR: biometric code not found';
        RETURN;
    END IF;

    /* ----------------------------------------------------
       STEP 3 — Resolve active contract
    ---------------------------------------------------- */
    SELECT c.id, c.start_date
    INTO v_contract_id, v_old_contract_start_date
    FROM public.contracts c
    WHERE c.employee_id = p_employee_id
      AND LOWER(c.status::TEXT) = 'active'
      AND c.is_deleted = FALSE
    LIMIT 1;

    IF v_contract_id IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 'ERROR: active contract not found';
        RETURN;
    END IF;

    /* ----------------------------------------------------
       STEP 4 — Update contract start date
    ---------------------------------------------------- */
    UPDATE public.contracts
    SET start_date = p_start_date
    WHERE id = v_contract_id;

    /* ----------------------------------------------------
       STEP 5 — PRESENT (4 AM cutoff) - EXCLUDE CURRENT DATE
    ---------------------------------------------------- */
    INSERT INTO public.employee_attendance (
        employee_id,
        attendance_date,
        status,
        first_punch_in
    )
    SELECT
        p_employee_id,
        CASE
            WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
            THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
            ELSE pr.punch_time::DATE
        END AS effective_date,
        'present',
        MIN(pr.punch_time)
    FROM public.punch_records pr
    WHERE pr.enroll_number::TEXT = v_biometric_code
      AND CASE
            WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
            THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
            ELSE pr.punch_time::DATE
          END >= p_start_date
      AND CASE
            WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
            THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
            ELSE pr.punch_time::DATE
          END < CURRENT_DATE  -- EXCLUDE CURRENT DATE
      AND pr.is_active = TRUE
      AND pr.is_deleted = FALSE
    GROUP BY effective_date
    ON CONFLICT (employee_id, attendance_date)
    DO UPDATE
    SET status = 'present',
        first_punch_in = CASE
            WHEN employee_attendance.first_punch_in IS NULL
            THEN EXCLUDED.first_punch_in
            ELSE employee_attendance.first_punch_in
        END;

    /* ----------------------------------------------------
       STEP 6 — attendance_day_counting (PRESENT) - EXCLUDE CURRENT DATE
    ---------------------------------------------------- */
    INSERT INTO public.attendance_day_counting (
        employee_id,
        counting_date,
        is_counted,
        reason
    )
    SELECT
        p_employee_id,
        CASE
            WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
            THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
            ELSE pr.punch_time::DATE
        END,
        TRUE,
        'present'
    FROM public.punch_records pr
    WHERE pr.enroll_number::TEXT = v_biometric_code
      AND CASE
            WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
            THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
            ELSE pr.punch_time::DATE
          END >= p_start_date
      AND CASE
            WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
            THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
            ELSE pr.punch_time::DATE
          END < CURRENT_DATE  -- EXCLUDE CURRENT DATE
      AND pr.is_active = TRUE
      AND pr.is_deleted = FALSE
    GROUP BY 2
    ON CONFLICT (employee_id, counting_date)
    DO UPDATE
    SET is_counted = TRUE,
        reason = 'present',
        updated_at = CURRENT_TIMESTAMP;

    /* ----------------------------------------------------
       STEP 7 — NO PUNCH → fallback from employee_attendance - EXCLUDE CURRENT DATE
    ---------------------------------------------------- */
    INSERT INTO public.attendance_day_counting (
        employee_id,
        counting_date,
        is_counted,
        reason
    )
    SELECT
        ea.employee_id,
        ea.attendance_date,
        FALSE,
        LOWER(ea.status::TEXT)
    FROM public.employee_attendance ea
    WHERE ea.employee_id = p_employee_id
      AND ea.attendance_date >= p_start_date
      AND ea.attendance_date < CURRENT_DATE  -- EXCLUDE CURRENT DATE
      AND NOT EXISTS (
          SELECT 1
          FROM public.punch_records pr
          WHERE pr.enroll_number::TEXT = v_biometric_code
            AND CASE
                WHEN EXTRACT(HOUR FROM pr.punch_time) < 4
                THEN (pr.punch_time::DATE - INTERVAL '1 day')::DATE
                ELSE pr.punch_time::DATE
            END = ea.attendance_date
            AND pr.is_active = TRUE
            AND pr.is_deleted = FALSE
      )
      AND NOT EXISTS (
          SELECT 1
          FROM public.attendance_day_counting adc
          WHERE adc.employee_id = ea.employee_id
            AND adc.counting_date = ea.attendance_date
      );

    /* ----------------------------------------------------
       STEP 8 — Recompute counter - EXCLUDE CURRENT DATE
    ---------------------------------------------------- */
    SELECT COUNT(*)
    INTO v_counted_days
    FROM public.attendance_day_counting
    WHERE employee_id = p_employee_id
      AND is_counted = TRUE
      AND reason = 'present'
      AND counting_date >= p_start_date
      AND counting_date < CURRENT_DATE;  -- EXCLUDE CURRENT DATE

    v_current_counter := v_counted_days % 50;

    UPDATE public.employees
    SET consecutive_attendance_counter = v_current_counter,
        attendance_counting_start_date = p_start_date
    WHERE id = p_employee_id;

    /* ----------------------------------------------------
       STEP 9 — Paid Leave
    ---------------------------------------------------- */
    SELECT id
    INTO v_pl_leave_type_id
    FROM public.leave_types
    WHERE LOWER(code) = 'pl'
      AND is_active = TRUE
      AND is_deleted = FALSE
    LIMIT 1;

    IF v_pl_leave_type_id IS NOT NULL THEN
        v_should_have_pl := v_counted_days / 50;

        SELECT COALESCE(SUM(earned_days), 0)
        INTO v_already_have_pl
        FROM public.leave_balances
        WHERE employee_id = p_employee_id
          AND leave_type_id = v_pl_leave_type_id
          AND contract_id = v_contract_id
          AND is_active = TRUE
          AND is_deleted = FALSE;

        v_pl_delta := GREATEST(v_should_have_pl - v_already_have_pl, 0);

        IF v_pl_delta > 0 THEN
            UPDATE public.leave_balances
            SET earned_days = earned_days + v_pl_delta
            WHERE employee_id = p_employee_id
              AND leave_type_id = v_pl_leave_type_id
              AND contract_id = v_contract_id
              AND is_active = TRUE
              AND is_deleted = FALSE;

            IF NOT FOUND THEN
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
                    p_employee_id,
                    v_pl_leave_type_id,
                    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
                    v_pl_delta,
                    v_contract_id,
                    TRUE,
                    FALSE
                );
            END IF;
        END IF;
    END IF;

    /* ----------------------------------------------------
       SUCCESS
    ---------------------------------------------------- */
    RETURN QUERY
    SELECT
        v_counted_days,
        v_current_counter,
        v_pl_delta,
        'SUCCESS'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION public.backfill_attendance_counting(UUID, DATE) TO authenticated;

-- Add a comment explaining the function
COMMENT ON FUNCTION public.backfill_attendance_counting IS 
'Backfills attendance counting data for an employee from a specific start date. 
Excludes the current date from all calculations to ensure only completed days are counted.
Returns: total_days_counted, current_counter, leaves_earned, message';
