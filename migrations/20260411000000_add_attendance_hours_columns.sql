-- ============================================================================
-- Migration: Add total_hours and check_out_time to employee_attendance
-- Date: 2026-04-11
-- ============================================================================

-- STEP 1: Add missing columns to employee_attendance
ALTER TABLE public.employee_attendance 
ADD COLUMN IF NOT EXISTS check_out_time timestamp with time zone,
ADD COLUMN IF NOT EXISTS total_hours numeric(10, 2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS total_break_minutes integer DEFAULT 0;

-- Add comments for documentation
COMMENT ON COLUMN public.employee_attendance.check_out_time IS 'Last punch time of the day (after 4 AM cutoff logic)';
COMMENT ON COLUMN public.employee_attendance.total_hours IS 'Total working hours excluding breaks, in decimal hours';
COMMENT ON COLUMN public.employee_attendance.total_break_minutes IS 'Total break time calculated from gaps between punches';
