-- Add soft-delete audit columns to service_orders
-- Required by cascade_cancel_so_payments trigger which references NEW.deleted_by
ALTER TABLE public.service_orders
  ADD COLUMN IF NOT EXISTS deleted_at timestamp with time zone NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS idx_service_orders_deleted_by
  ON public.service_orders (deleted_by);
