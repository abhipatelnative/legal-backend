-- Function to approve punch edit request and update attendance records
CREATE OR REPLACE FUNCTION approve_punch_edit_request(
    p_request_id UUID,
    p_reviewer_id UUID,
    p_review_comments TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_request RECORD;
    v_employee RECORD;
    v_attendance_date DATE;
    v_check_in TIMESTAMP;
    v_check_out TIMESTAMP;
    v_total_break_ms BIGINT := 0;
    v_total_work_ms BIGINT;
    v_total_hours DECIMAL(5,2);
    v_total_break_minutes INTEGER;
    v_shift_data RECORD;
    v_overtime_hours DECIMAL(5,2) := 0;
    v_shift_duration_hours DECIMAL(5,2);
    v_punch_count INTEGER;
    v_punch_times TIMESTAMP[];
    i INTEGER;
BEGIN
    -- Get the punch edit request
    SELECT * INTO v_request
    FROM punch_edit_requests
    WHERE id = p_request_id
    AND status = 'pending'
    AND is_active = true
    AND is_deleted = false;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Punch edit request not found or already processed';
    END IF;
    
    -- Get employee and profile data
    SELECT e.*, up.id as profile_id, up.biometric_code
    INTO v_employee
    FROM employees e
    JOIN user_profiles up ON e.user_id = up.id
    WHERE e.id = v_request.employee_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee not found';
    END IF;
    
    -- Update the request status
    UPDATE punch_edit_requests
    SET 
        status = 'approved',
        reviewed_by = p_reviewer_id,
        reviewed_at = CURRENT_TIMESTAMP,
        review_comments = p_review_comments,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_request_id;
    
    -- Update the specific punch record directly using punch_record_id
    DECLARE
        v_new_time TIMESTAMP;
    BEGIN
        -- Calculate new time from the request
        v_new_time := v_request.date + v_request.requested_time::TIME;
        
        RAISE NOTICE 'Updating punch record ID % to %', v_request.punch_record_id, v_new_time;
        
        -- Update the specific punch record directly
        UPDATE punch_records
        SET punch_time = v_new_time,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_request.punch_record_id
        AND is_active = true
        AND is_deleted = false;
        
        -- Check if update was successful
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Punch record not found or inactive: %', v_request.punch_record_id;
        END IF;
        
        RAISE NOTICE 'Successfully updated punch record ID % to %', v_request.punch_record_id, v_new_time;
        
    END;
    
    -- Now get updated punch times for recalculation
    SELECT ARRAY_AGG(punch_time ORDER BY punch_time), COUNT(*)
    INTO v_punch_times, v_punch_count
    FROM punch_records
    WHERE enroll_number = v_employee.biometric_code::INTEGER
    AND DATE(punch_time) = v_request.date
    AND is_active = true
    AND is_deleted = false;
    
    RAISE NOTICE 'Updated punch times: %, count: %', v_punch_times, v_punch_count;
    
    -- Calculate attendance from punch records
    v_attendance_date := v_request.date;
    
    IF v_punch_count > 0 THEN
        -- First punch is check-in, last punch is check-out
        v_check_in := v_punch_times[1];
        v_check_out := v_punch_times[v_punch_count];
        
        RAISE NOTICE 'Check-in: %, Check-out: %', v_check_in, v_check_out;
        
        -- Calculate breaks: from OUT punch to next IN punch
        -- Pattern: IN(1) -> OUT(2) -> IN(3) -> OUT(4)
        -- Break 1: OUT(2) to IN(3)
        -- Break 2: OUT(4) to IN(5) (if exists)
        v_total_break_ms := 0;
        FOR i IN 2..v_punch_count-1 BY 2 LOOP
            IF i + 1 <= v_punch_count THEN
                DECLARE
                    break_start TIMESTAMP := v_punch_times[i];     -- OUT punch
                    break_end TIMESTAMP := v_punch_times[i+1];     -- IN punch
                    break_duration_ms BIGINT;
                BEGIN
                    break_duration_ms := EXTRACT(EPOCH FROM break_end - break_start) * 1000;
                    v_total_break_ms := v_total_break_ms + break_duration_ms;
                    RAISE NOTICE 'Break %: % to % = % ms', (i/2), break_start, break_end, break_duration_ms;
                END;
            END IF;
        END LOOP;
        
        v_total_break_minutes := ROUND(v_total_break_ms / (1000.0 * 60));
        
        -- Calculate total work time
        v_total_work_ms := EXTRACT(EPOCH FROM v_check_out - v_check_in) * 1000 - v_total_break_ms;
        v_total_hours := ROUND((v_total_work_ms / (1000.0 * 60 * 60))::NUMERIC, 2);
        
        RAISE NOTICE 'Total break: % minutes, Total work: % hours', v_total_break_minutes, v_total_hours;
        
        -- Ensure non-negative values
        v_total_break_minutes := GREATEST(0, v_total_break_minutes);
        v_total_hours := GREATEST(0, v_total_hours);
        
        -- Get shift information for overtime calculation
        SELECT es.shift_id, s.start_time, s.end_time
        INTO v_shift_data
        FROM employee_shifts es
        JOIN shifts s ON es.shift_id = s.id
        WHERE es.employee_id = v_request.employee_id
        AND es.is_active = true
        AND es.is_deleted = false
        LIMIT 1;
        
        -- Calculate overtime
        IF v_shift_data.start_time IS NOT NULL AND v_shift_data.end_time IS NOT NULL THEN
            -- Calculate shift duration in hours
            v_shift_duration_hours := EXTRACT(EPOCH FROM 
                (v_attendance_date + v_shift_data.end_time::TIME) - 
                (v_attendance_date + v_shift_data.start_time::TIME)
            ) / 3600.0;
            
            v_overtime_hours := GREATEST(0, v_total_hours - v_shift_duration_hours);
        END IF;
        
        -- Update attendance_records
        INSERT INTO attendance_records (
            user_profile_id,
            attendance_date,
            check_in,
            check_out,
            total_break_duration_minutes,
            total_hours,
            overtime_hours,
            status,
            updated_at
        ) VALUES (
            v_employee.profile_id,
            v_attendance_date,
            v_check_in,
            v_check_out,
            v_total_break_minutes,
            v_total_hours,
            v_overtime_hours,
            'present',
            CURRENT_TIMESTAMP
        )
        ON CONFLICT (user_profile_id, attendance_date)
        DO UPDATE SET
            check_in = EXCLUDED.check_in,
            check_out = EXCLUDED.check_out,
            total_break_duration_minutes = EXCLUDED.total_break_duration_minutes,
            total_hours = EXCLUDED.total_hours,
            overtime_hours = EXCLUDED.overtime_hours,
            updated_at = CURRENT_TIMESTAMP;
            
        RAISE NOTICE 'Attendance updated for employee % on %', v_employee.profile_id, v_attendance_date;
    END IF;
    
    RETURN TRUE;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error approving punch edit request: %', SQLERRM;
END;
$$;

-- Function to reject punch edit request
CREATE OR REPLACE FUNCTION reject_punch_edit_request(
    p_request_id UUID,
    p_reviewer_id UUID,
    p_review_comments TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Update the request status
    UPDATE punch_edit_requests
    SET 
        status = 'rejected',
        reviewed_by = p_reviewer_id,
        reviewed_at = CURRENT_TIMESTAMP,
        review_comments = p_review_comments,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_request_id
    AND status = 'pending'
    AND is_active = true
    AND is_deleted = false;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Punch edit request not found or already processed';
    END IF;
    
    RETURN TRUE;
END;
$$;

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION approve_punch_edit_request(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION reject_punch_edit_request(UUID, UUID, TEXT) TO authenticated;