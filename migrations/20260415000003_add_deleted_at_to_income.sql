-- Add deleted_at column to income_records table
-- Migration: 20260415000003
-- Purpose: Add soft delete support to income_records table

-- Add deleted_at column
ALTER TABLE public.income_records
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;

-- Add index for soft delete queries
CREATE INDEX IF NOT EXISTS idx_income_deleted_at ON public.income_records(deleted_at);

-- Add comment
COMMENT ON COLUMN public.income_records.deleted_at IS 'Soft delete timestamp - NULL means active';
