-- Migration: Fix process_daily_attendance() to use contract_id for shift lookups
-- Description: Updates the function to use contract_id instead of employee_id when fetching from employee_shifts

DROP FUNCTION IF EXISTS public.process_daily_attendance();

CREATE OR REPLACE FUNCTION public.process_daily_attendance()
RETURNS void
LANGUAGE plpgsql
AS $$
declare
    processing_date date := current_date;
    emp record;

    punch_count integer;

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
            (lr.total_days = 0.5), -- only half-day condition
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

            /* ❌ half-day leave = absent */
            if is_half_day then
                insert into public.employee_attendance
                    (employee_id, attendance_date, status)
                values (emp.id, processing_date, 'absent')
                on conflict (employee_id, attendance_date)
                do update set status = 'absent';
                continue;
            end if;

            /* ✅ short leave = present */
            if is_short_leave then
                insert into public.employee_attendance
                    (employee_id, attendance_date, status)
                values (emp.id, processing_date, 'present')
                on conflict (employee_id, attendance_date)
                do update set status = 'present';
                continue;
            end if;

            /* ✅ hourly leave (non-sl only, safety condition applied) */
            if leave_salary_payable
               and leave_allow_hourly
               and leave_max_hours is not null
               and is_hourly_leave
            then
                insert into public.employee_attendance
                    (employee_id, attendance_date, status)
                values (emp.id, processing_date, 'present')
                on conflict (employee_id, attendance_date)
                do update set status = 'present';
            else
                insert into public.employee_attendance
                    (employee_id, attendance_date, status)
                values (emp.id, processing_date, 'absent')
                on conflict (employee_id, attendance_date)
                do update set status = 'absent';
            end if;

            continue;
        end if;

        /* -------------------------------
           step 2 : punch
           (overrides holiday & weekoff)
        -------------------------------- */
        select count(*) into punch_count
        from public.punch_records pr
        join public.user_profiles up
          on pr.enroll_number::text = up.biometric_code
        where up.id = (select user_id from public.employees where id = emp.id)
          and pr.punch_time::date = processing_date
          and pr.is_active = true
          and pr.is_deleted = false;

        if punch_count > 0 then
            insert into public.employee_attendance
                (employee_id, attendance_date, status, first_punch_in)
            select emp.id, processing_date, 'present', min(pr.punch_time)
            from public.punch_records pr
            join public.user_profiles up
              on pr.enroll_number::text = up.biometric_code
            where up.id = (select user_id from public.employees where id = emp.id)
              and pr.punch_time::date = processing_date
              and pr.is_active = true
              and pr.is_deleted = false
            on conflict (employee_id, attendance_date)
            do update set
                status = 'present',
                first_punch_in = excluded.first_punch_in;
            continue;
        end if;

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
                (employee_id, attendance_date, status)
            values (emp.id, processing_date, 'holiday')
            on conflict (employee_id, attendance_date)
            do update set status = 'holiday';
            continue;
        end if;

        /* -------------------------------
           step 4 : weekoff (stores lowercase 'weekoff')
           FIX: Use contract_id instead of employee_id for shift lookup
        -------------------------------- */
        select not (
            case extract(dow from processing_date)
                when 0 then ww.sunday
                when 1 then ww.monday
                when 2 then ww.tuesday
                when 3 then ww.wednesday
                when 4 then ww.thursday
                when 5 then ww.friday
                when 6 then ww.saturday
            end
        )
        into is_week_off
        from public.employee_shifts es
        join public.work_weeks ww on es.work_week_id = ww.id
        where es.contract_id = emp.contract_id  -- Changed from es.employee_id = emp.id
          and es.is_active = true
          and es.is_deleted = false;

        if coalesce(is_week_off, false) then
            insert into public.employee_attendance
                (employee_id, attendance_date, status)
            values (emp.id, processing_date, 'weekoff')
            on conflict (employee_id, attendance_date)
            do update set status = 'weekoff';
            continue;
        end if;

        /* -------------------------------
           step 5 : absent
        -------------------------------- */
        insert into public.employee_attendance
            (employee_id, attendance_date, status)
        values (emp.id, processing_date, 'absent')
        on conflict (employee_id, attendance_date)
        do update set status = 'absent';

    end loop;
end;
$$;

-- Update backfill_attendance_counting to use contract_id for shift lookup
DROP FUNCTION IF EXISTS public.backfill_attendance_counting(UUID, DATE);
CREATE OR REPLACE FUNCTION public.backfill_attendance_counting(p_employee_id UUID, p_start_date DATE)
RETURNS TABLE(total_days_processed INTEGER, present_days INTEGER, absent_days INTEGER, weekoff_days INTEGER, holiday_days INTEGER, leave_days INTEGER, days_counted_for_pl INTEGER, pls_awarded INTEGER, current_counter INTEGER, next_pl_at INTEGER, message TEXT) AS $$
DECLARE
    v_user_id UUID; v_biometric_code TEXT; v_contract_id UUID; v_work_week_id UUID; v_work_week_found BOOLEAN := FALSE;
    v_ww_monday BOOLEAN; v_ww_tuesday BOOLEAN; v_ww_wednesday BOOLEAN; v_ww_thursday BOOLEAN; v_ww_friday BOOLEAN; v_ww_saturday BOOLEAN; v_ww_sunday BOOLEAN;
    v_end_date DATE; v_total_processed INTEGER := 0; v_present_count INTEGER := 0; v_absent_count INTEGER := 0; v_weekoff_count INTEGER := 0; v_holiday_count INTEGER := 0; v_leave_count INTEGER := 0;
    v_pl_leave_type_id UUID; v_current_counter INTEGER := 0; v_counting_start_date DATE; v_days_counted INTEGER := 0; v_pls_to_award INTEGER := 0; v_new_counter INTEGER := 0; v_new_start_date DATE; v_completion_year INTEGER;
    v_current_date DATE; v_status TEXT; v_first_punch TIMESTAMP WITH TIME ZONE; v_is_working_day BOOLEAN; v_holiday_id UUID; v_leave_id UUID; v_day_of_week INTEGER;
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
            SELECT lr.id INTO v_leave_id FROM public.leave_requests lr WHERE lr.employee_id = p_employee_id AND lr.start_date <= v_current_date AND lr.end_date >= v_current_date AND LOWER(lr.status::TEXT) = 'approved' LIMIT 1;
            IF v_leave_id IS NOT NULL THEN v_status := 'leave'; v_leave_count := v_leave_count + 1;
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
    SELECT id INTO v_pl_leave_type_id FROM public.leave_types WHERE LOWER(code) = 'pl' AND is_active = TRUE LIMIT 1;
    SELECT COALESCE(consecutive_attendance_counter, 0), attendance_counting_start_date INTO v_current_counter, v_counting_start_date FROM public.employees WHERE id = p_employee_id;
    IF v_counting_start_date IS NULL THEN SELECT start_date INTO v_counting_start_date FROM public.contracts WHERE id = v_contract_id; UPDATE public.employees SET attendance_counting_start_date = v_counting_start_date WHERE id = p_employee_id; END IF;
    INSERT INTO public.attendance_day_counting (employee_id, counting_date, is_counted, reason) SELECT p_employee_id, ea.attendance_date, FALSE, ea.status::TEXT FROM public.employee_attendance ea WHERE ea.employee_id = p_employee_id AND ea.attendance_date >= v_counting_start_date AND ea.attendance_date <= v_end_date ON CONFLICT (employee_id, counting_date) DO UPDATE SET reason = EXCLUDED.reason;
    FOR v_current_date IN SELECT adc.counting_date FROM public.attendance_day_counting adc WHERE adc.employee_id = p_employee_id AND adc.is_counted = FALSE AND adc.reason = 'present' AND adc.counting_date >= v_counting_start_date ORDER BY adc.counting_date ASC LOOP
        v_current_counter := v_current_counter + 1; v_days_counted := v_days_counted + 1;
        UPDATE public.attendance_day_counting SET is_counted = TRUE, updated_at = CURRENT_TIMESTAMP WHERE employee_id = p_employee_id AND counting_date = v_current_date;
        IF v_current_counter % 50 = 0 THEN
            v_pls_to_award := v_current_counter / 50; v_new_counter := 0; v_completion_year := EXTRACT(YEAR FROM v_current_date); v_new_start_date := v_current_date + INTERVAL '1 day';
            IF v_pl_leave_type_id IS NOT NULL THEN INSERT INTO public.leave_balances (employee_id, leave_type_id, contract_id, year, earned_days) VALUES (p_employee_id, v_pl_leave_type_id, v_contract_id, v_completion_year, v_pls_to_award) ON CONFLICT (employee_id, leave_type_id, year, contract_id) DO UPDATE SET earned_days = leave_balances.earned_days + EXCLUDED.earned_days; END IF;
            UPDATE public.employees SET consecutive_attendance_counter = v_new_counter, attendance_counting_start_date = v_new_start_date WHERE id = p_employee_id;
            v_current_counter := v_new_counter; v_counting_start_date := v_new_start_date;
        END IF;
    END LOOP;
    UPDATE public.employees SET consecutive_attendance_counter = v_current_counter, attendance_counting_start_date = COALESCE(v_counting_start_date, attendance_counting_start_date) WHERE id = p_employee_id;
    RETURN QUERY SELECT v_total_processed, v_present_count, v_absent_count, v_weekoff_count, v_holiday_count, v_leave_count, v_days_counted, v_pls_to_award, v_current_counter, (50 - v_current_counter)::INTEGER, 'SUCCESS'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Update auto_calculate_simple_attendance to use contract_id for shift lookup
CREATE OR REPLACE FUNCTION public.auto_calculate_simple_attendance() RETURNS TRIGGER AS $$
DECLARE v_employee_id UUID; v_contract_id UUID; v_shift_start TIME; v_shift_end TIME; v_late_minutes INTEGER := 0; v_actual_work_hours NUMERIC(5,2) := 0; v_status VARCHAR(50) := 'present';
BEGIN
  SELECT e.id, c.id INTO v_employee_id, v_contract_id FROM public.employees e JOIN public.contracts c ON e.id = c.employee_id WHERE e.user_id = NEW.user_profile_id AND (c.status = 'active' OR c.status = 'approved') AND c.is_active = true ORDER BY c.created_at DESC LIMIT 1;
  IF v_employee_id IS NULL THEN RETURN NEW; END IF;
  IF v_contract_id IS NOT NULL THEN SELECT s.start_time, s.end_time INTO v_shift_start, v_shift_end FROM public.employee_shifts es JOIN public.shifts s ON es.shift_id = s.id WHERE es.contract_id = v_contract_id AND es.is_active = true LIMIT 1; END IF;
  IF v_shift_start IS NULL THEN SELECT s.start_time, s.end_time INTO v_shift_start, v_shift_end FROM public.employee_shifts es JOIN public.shifts s ON es.shift_id = s.id WHERE es.employee_id = v_employee_id AND es.is_active = true LIMIT 1; END IF;
  IF v_shift_start IS NULL THEN v_shift_start := '09:30:00'::TIME; v_shift_end := '18:00:00'::TIME; END IF;
  IF NEW.check_in IS NOT NULL THEN v_late_minutes := GREATEST(0, EXTRACT(EPOCH FROM (NEW.check_in::TIME - v_shift_start)) / 60 - COALESCE(NEW.grace_period_minutes, 5)); END IF;
  IF NEW.check_in IS NOT NULL AND NEW.check_out IS NOT NULL THEN v_actual_work_hours := GREATEST(0, EXTRACT(EPOCH FROM (NEW.check_out - NEW.check_in)) / 3600 - COALESCE(NEW.total_break_duration_minutes, 30) / 60.0); END IF;
  IF v_actual_work_hours >= 8 THEN v_status := 'present'; ELSIF v_actual_work_hours >= 4 THEN v_status := 'half_day'; ELSIF v_actual_work_hours > 0 THEN v_status := 'half_day'; ELSE v_status := 'absent'; END IF;
  NEW.late_arrival_minutes := v_late_minutes; NEW.actual_work_hours := v_actual_work_hours; NEW.status := COALESCE(NEW.status, v_status); NEW.shift_start_time := v_shift_start; NEW.shift_end_time := v_shift_end; NEW.updated_at := CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION public.backfill_attendance_counting(UUID, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auto_calculate_simple_attendance() TO authenticated;


-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.process_daily_attendance() TO authenticated;

-- Add comment
COMMENT ON FUNCTION public.process_daily_attendance() 
IS 'Daily cron job to process attendance. Uses contract_id for shift/week-off lookup and stored lowercase weekoff.';
