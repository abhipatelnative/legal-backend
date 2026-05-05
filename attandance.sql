
DECLARE
    processing_date DATE := CURRENT_DATE;
    emp RECORD;
    is_on_leave BOOLEAN;
    is_contract_holiday BOOLEAN;
    is_week_off BOOLEAN;
    punch_count INTEGER;
BEGIN
    -- Process all active employees
    FOR emp IN
        SELECT e.id, c.id as contract_id
        FROM public.employees e
        JOIN public.contracts c ON e.id = c.employee_id
        WHERE e.is_active = true
          AND e.employment_status = 'active'
          AND c.status = 'active'
          AND c.is_active = true
    LOOP
        -- Step 1: Check for approved leave first
        SELECT EXISTS (
            SELECT 1 FROM public.leave_requests
            WHERE employee_id = emp.id
              AND status = 'approved'
              AND processing_date BETWEEN start_date AND end_date
        ) INTO is_on_leave;

        IF is_on_leave THEN
            INSERT INTO public.employee_attendance (employee_id, attendance_date, status)
            VALUES (emp.id, processing_date, 'Leave'::public.attendance_status)
            ON CONFLICT (employee_id, attendance_date) DO UPDATE SET status = 'Leave'::public.attendance_status;
            CONTINUE;
        END IF;

        -- Step 2: Check contract-based holidays using holiday_master_id and current year
        SELECT EXISTS (
            SELECT 1 FROM public.contract_holidays ch
            JOIN public.holidays h ON ch.holiday_master_id = h.holiday_master_id
            WHERE ch.contract_id = emp.contract_id
              AND ch.is_applicable = true
              AND h.is_active = true
              AND EXTRACT(YEAR FROM h.start_date) = EXTRACT(YEAR FROM processing_date)
              AND processing_date BETWEEN h.start_date AND h.end_date
        ) INTO is_contract_holiday;

        IF is_contract_holiday THEN
            INSERT INTO public.employee_attendance (employee_id, attendance_date, status)
            VALUES (emp.id, processing_date, 'Holiday'::public.attendance_status)
            ON CONFLICT (employee_id, attendance_date) DO UPDATE SET status = 'Holiday'::public.attendance_status;
            CONTINUE;
        END IF;

        -- Step 3: Check employee shift for week-off
        SELECT NOT (
            CASE EXTRACT(DOW FROM processing_date)
              WHEN 0 THEN ww.sunday
              WHEN 1 THEN ww.monday
              WHEN 2 THEN ww.tuesday
              WHEN 3 THEN ww.wednesday
              WHEN 4 THEN ww.thursday
              WHEN 5 THEN ww.friday
              WHEN 6 THEN ww.saturday
              ELSE true
            END
        ) INTO is_week_off
        FROM public.employee_shifts es
        JOIN public.work_weeks ww ON es.work_week_id = ww.id
        WHERE es.employee_id = emp.id
          AND es.is_active = true;

        IF COALESCE(is_week_off, false) THEN
            INSERT INTO public.employee_attendance (employee_id, attendance_date, status)
            VALUES (emp.id, processing_date, 'WeekOff'::public.attendance_status)
            ON CONFLICT (employee_id, attendance_date) DO UPDATE SET status = 'WeekOff'::public.attendance_status;
            CONTINUE;
        END IF;

        -- Step 4: Check punch records for attendance
        SELECT COUNT(*) INTO punch_count
        FROM public.punch_records pr
        JOIN public.user_profiles up ON pr.enroll_number::text = up.biometric_code
        WHERE up.id = (SELECT user_id FROM public.employees WHERE id = emp.id)
          AND pr.punch_time::date = processing_date;

        IF punch_count > 0 THEN
            -- Get first punch time
            INSERT INTO public.employee_attendance (employee_id, attendance_date, status, first_punch_in)
            SELECT emp.id, processing_date, 'Present'::public.attendance_status, MIN(pr.punch_time)
            FROM public.punch_records pr
            JOIN public.user_profiles up ON pr.enroll_number::text = up.biometric_code
            WHERE up.id = (SELECT user_id FROM public.employees WHERE id = emp.id)
              AND pr.punch_time::date = processing_date
            ON CONFLICT (employee_id, attendance_date) DO UPDATE 
            SET status = 'Present'::public.attendance_status, first_punch_in = EXCLUDED.first_punch_in;
        ELSE
            -- No punch records - mark as Absent
            INSERT INTO public.employee_attendance (employee_id, attendance_date, status)
            VALUES (emp.id, processing_date, 'Absent'::public.attendance_status)
            ON CONFLICT (employee_id, attendance_date) DO UPDATE SET status = 'Absent'::public.attendance_status;
        END IF;

    END LOOP;
END;




create table public.employee_attendance (
  id uuid not null default gen_random_uuid (),
  employee_id uuid not null,
  attendance_date date not null,
  status public.attendance_status not null,
  first_punch_in timestamp with time zone null,
  notes text null,
  created_at timestamp with time zone not null default CURRENT_TIMESTAMP,
  constraint employee_attendance_pkey primary key (id),
  constraint employee_attendance_unique unique (employee_id, attendance_date),
  constraint employee_attendance_employee_id_fkey foreign KEY (employee_id) references employees (id) on delete CASCADE
) TABLESPACE pg_default;

create index IF not exists idx_attendance_employee_date on public.employee_attendance using btree (employee_id, attendance_date) TABLESPACE pg_default;