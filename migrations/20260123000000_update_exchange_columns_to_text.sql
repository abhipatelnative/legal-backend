-- Change exchange_work_date and exchange_type to TEXT to support multiple values (comma-separated)
-- This enables multi-day compensation leaves where each day has its own exchange work date

ALTER TABLE public.leave_requests 
ALTER COLUMN exchange_work_date TYPE TEXT USING exchange_work_date::TEXT;

ALTER TABLE public.leave_requests 
ALTER COLUMN exchange_type TYPE TEXT USING exchange_type::TEXT;

COMMENT ON COLUMN public.leave_requests.exchange_work_date IS 'Can store multiple dates separated by commas for multi-day exchange leaves';
COMMENT ON COLUMN public.leave_requests.exchange_type IS 'Can store multiple types (past/future) separated by commas matching exchange_work_date';
