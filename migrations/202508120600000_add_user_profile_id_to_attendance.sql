-- Replace employee_id with user_profile_id in attendance_records table

-- Add the user_profile_id column
ALTER TABLE public.attendance_records 
ADD COLUMN user_profile_id UUID REFERENCES public.user_profiles(id);

-- Update existing records to populate user_profile_id from employee_id
UPDATE public.attendance_records 
SET user_profile_id = e.user_id
FROM public.employees e
WHERE attendance_records.employee_id = e.id;

-- Set user_profile_id as NOT NULL
ALTER TABLE public.attendance_records 
ALTER COLUMN user_profile_id SET NOT NULL;

-- Drop the old employee_id column and its constraints
ALTER TABLE public.attendance_records 
DROP CONSTRAINT IF EXISTS attendance_records_employee_id_fkey,
DROP CONSTRAINT IF EXISTS unique_employee_attendance_date,
DROP COLUMN employee_id;

-- Add new unique constraint with user_profile_id
ALTER TABLE public.attendance_records 
ADD CONSTRAINT unique_user_profile_attendance_date UNIQUE (user_profile_id, attendance_date);

-- Create index for better performance
CREATE INDEX IF NOT EXISTS idx_attendance_records_user_profile ON public.attendance_records(user_profile_id);
CREATE INDEX IF NOT EXISTS idx_attendance_records_user_profile_date ON public.attendance_records(user_profile_id, attendance_date);