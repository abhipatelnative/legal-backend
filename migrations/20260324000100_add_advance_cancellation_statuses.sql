-- Add new statuses to advance_status enum
-- Note: ALTER TYPE ... ADD VALUE cannot be executed in a transaction block in some versions,
-- so we run them separately if needed, but in migrations it's usually fine if the runner handles it.

DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_enum e ON t.oid = e.enumtypid WHERE t.typname = 'advance_status' AND e.enumlabel = 'pending_cancellation') THEN
        ALTER TYPE public.advance_status ADD VALUE 'pending_cancellation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_enum e ON t.oid = e.enumtypid WHERE t.typname = 'advance_status' AND e.enumlabel = 'cancelled') THEN
        ALTER TYPE public.advance_status ADD VALUE 'cancelled';
    END IF;
END $$;

-- Add cancellation_reason and previous_status columns to employee_advances
ALTER TABLE public.employee_advances 
ADD COLUMN IF NOT EXISTS cancellation_reason text,
ADD COLUMN IF NOT EXISTS previous_status public.advance_status;
