-- Cash & Bank Module - Fix Missing Schema Column
-- Migration: 20260417000013
-- Purpose: Add the missing 'status' column to payment_transactions_service_orders
--          which is required by the record_payment_v2 and cancel_payment_v2 functions.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payment_transactions_service_orders'
      AND column_name = 'status'
  ) THEN
    ALTER TABLE public.payment_transactions_service_orders
    ADD COLUMN status VARCHAR(20) DEFAULT 'completed';

    RAISE NOTICE 'Added status column to payment_transactions_service_orders';
  ELSE
    RAISE NOTICE 'status column already exists in payment_transactions_service_orders';
  END IF;
END $$;
