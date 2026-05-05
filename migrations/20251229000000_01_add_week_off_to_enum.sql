-- Migration 1: Add 'weekoff' to attendance_status enum
-- Description: Adds the 'weekoff' value to the attendance_status enum type (lowercase, no underscore)

-- Add 'weekoff' to the attendance_status enum
ALTER TYPE attendance_status ADD VALUE IF NOT EXISTS 'weekoff';

-- Add comment
COMMENT ON TYPE attendance_status IS 'Employee attendance status: present, absent, half_day, holiday, leave, weekoff';
