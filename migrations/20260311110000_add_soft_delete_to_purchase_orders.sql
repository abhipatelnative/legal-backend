-- Add soft-delete support for purchase orders
ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamp with time zone NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_is_deleted
  ON public.purchase_orders (is_deleted);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_deleted_at
  ON public.purchase_orders (deleted_at);
