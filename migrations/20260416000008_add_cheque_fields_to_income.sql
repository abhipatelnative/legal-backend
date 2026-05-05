-- Migration: Add cheque details to income_records
-- Description: Standardizes cheque information storage across income tracking and accounting detail layers.

ALTER TABLE public.income_records
ADD COLUMN IF NOT EXISTS cheque_number TEXT,
ADD COLUMN IF NOT EXISTS cheque_date DATE,
ADD COLUMN IF NOT EXISTS cheque_bank_name TEXT;

-- Add comments for documentation
COMMENT ON COLUMN public.income_records.cheque_number IS 'Cheque number for cheque payments';
COMMENT ON COLUMN public.income_records.cheque_date IS 'The date printed on the cheque';
COMMENT ON COLUMN public.income_records.cheque_bank_name IS 'The name of the bank the cheque belongs to';
