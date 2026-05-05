-- Migration 2: Update attendance_records CHECK constraint to include 'weekoff'
-- Description: Updates the status CHECK constraint on attendance_records table to allow 'weekoff' value

-- Drop the old CHECK constraint
ALTER TABLE public.attendance_records 
DROP CONSTRAINT IF EXISTS attendance_records_status_check;

-- Add new CHECK constraint with 'weekoff' included (case-insensitive)
ALTER TABLE public.attendance_records
ADD CONSTRAINT attendance_records_status_check CHECK (
    LOWER((status)::text) = ANY (
        ARRAY[
            'present'::text,
            'absent'::text,
            'half_day'::text,
            'holiday'::text,
            'leave'::text,
            'weekoff'::text  -- ADDED (lowercase)
        ]
    )
);

-- Add comment
COMMENT ON CONSTRAINT attendance_records_status_check ON public.attendance_records 
IS 'Valid status values (case-insensitive): present, absent, half_day, holiday, leave, weekoff';
