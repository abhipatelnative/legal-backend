-- Migration 3: Fix process_daily_attendance() to use 'week_off' instead of 'weekoff'
-- Description: Updates the function to use the correct enum value

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
          and pr.punch_time::date = processing_date;

        if punch_count > 0 then
            insert into public.employee_attendance
                (employee_id, attendance_date, status, first_punch_in)
            select emp.id, processing_date, 'present', min(pr.punch_time)
            from public.punch_records pr
            join public.user_profiles up
              on pr.enroll_number::text = up.biometric_code
            where up.id = (select user_id from public.employees where id = emp.id)
              and pr.punch_time::date = processing_date
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
        where es.employee_id = emp.id
          and es.is_active = true;

        if coalesce(is_week_off, false) then
            insert into public.employee_attendance
                (employee_id, attendance_date, status)
            values (emp.id, processing_date, 'weekoff')  -- Lowercase, no underscore
            on conflict (employee_id, attendance_date)
            do update set status = 'weekoff';  -- Lowercase, no underscore
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

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.process_daily_attendance() TO authenticated;

-- Add comment
COMMENT ON FUNCTION public.process_daily_attendance() 
IS 'Daily cron job to process attendance. Uses lowercase weekoff for week-off days.';
