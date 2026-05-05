-- Migration: Add registry_id to payment_transactions_service_orders
-- Description: Adds registry_id column to track the GL registry entry for each service order transaction.
-- Date: 2026-04-24

ALTER TABLE public.payment_transactions_service_orders
ADD COLUMN IF NOT EXISTS registry_id UUID REFERENCES public.payment_transactions_registry(id);

CREATE INDEX IF NOT EXISTS idx_ptso_registry_id ON public.payment_transactions_service_orders(registry_id);

COMMENT ON COLUMN public.payment_transactions_service_orders.registry_id IS 'Reference to the GL registry entry in payment_transactions_registry';
