-- Add color field to leave_types table for calendar leave rendering
ALTER TABLE public.leave_types ADD COLUMN IF NOT EXISTS color VARCHAR(7) DEFAULT '#3B82F6';
