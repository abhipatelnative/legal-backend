-- GST configuration on company_settings
-- Decision: single default GST rate configured here; editable per service order.

ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS gstin TEXT,
  ADD COLUMN IF NOT EXISTS gst_enabled BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS default_gst_rate NUMERIC(5,2) DEFAULT 18.00;
