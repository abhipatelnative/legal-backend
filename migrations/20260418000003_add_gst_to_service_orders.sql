-- Per-service-order GST fields
-- Decision: pre-fill from company default, but editable per order.

ALTER TABLE public.service_orders
  ADD COLUMN IF NOT EXISTS gst_enabled BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS gst_rate NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS gst_amount NUMERIC(15,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_with_gst NUMERIC(15,2);
