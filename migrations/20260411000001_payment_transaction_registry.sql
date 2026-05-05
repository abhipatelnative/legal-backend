-- Cash & Bank Module - Payment Transactions Registry Table
-- Migration: 20260411000001
-- Purpose: Create payment_transactions_registry table for all payment records

-- Create payment_transactions_registry table
CREATE TABLE IF NOT EXISTS public.payment_transactions_registry (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_date DATE NOT NULL,
  transaction_type VARCHAR(50) NOT NULL CHECK (transaction_type IN (
    'OPENING_BALANCE', 'EXPENSE', 'SERVICE_ORDER', 'PAYROLL', 
    'PURCHASE_ORDER', 'TRANSFER', 'BALANCE_ADJUSTMENT'
  )),
  direction VARCHAR(20) NOT NULL CHECK (direction IN ('RECEIVED', 'GIVEN')),
  total_amount DECIMAL(15,2) NOT NULL CHECK (total_amount > 0),
  source_type VARCHAR(50),
  source_id UUID,
  party_id UUID,
  party_type VARCHAR(50) CHECK (party_type IN ('employee', 'client', 'vendor')),
  reference_number VARCHAR(100),
  remarks TEXT,
  status VARCHAR(20) NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'cancelled')),
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  cancelled_at TIMESTAMP WITH TIME ZONE,
  cancelled_by UUID REFERENCES auth.users(id),
  cancellation_reason TEXT
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_ptr_transaction_date ON public.payment_transactions_registry(transaction_date);
CREATE INDEX IF NOT EXISTS idx_ptr_transaction_type ON public.payment_transactions_registry(transaction_type);
CREATE INDEX IF NOT EXISTS idx_ptr_direction ON public.payment_transactions_registry(direction);
CREATE INDEX IF NOT EXISTS idx_ptr_source ON public.payment_transactions_registry(source_type, source_id) WHERE source_type IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ptr_status ON public.payment_transactions_registry(status);
CREATE INDEX IF NOT EXISTS idx_ptr_created_by ON public.payment_transactions_registry(created_by);

-- Add comments
COMMENT ON TABLE public.payment_transactions_registry IS 'Header record for all payment transactions';
COMMENT ON COLUMN public.payment_transactions_registry.direction IS 'RECEIVED = money in, GIVEN = money out';
COMMENT ON COLUMN public.payment_transactions_registry.source_type IS 'Module that originated this payment: expense, service_order, payroll, purchase_order';
COMMENT ON COLUMN public.payment_transactions_registry.source_id IS 'Reference ID to the source record';
COMMENT ON COLUMN public.payment_transactions_registry.status IS 'completed or cancelled';

-- Create updated_at trigger
CREATE OR REPLACE FUNCTION public.update_payment_transactions_registry_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_payment_transactions_registry_updated_at
BEFORE UPDATE ON public.payment_transactions_registry
FOR EACH ROW
EXECUTE FUNCTION public.update_payment_transactions_registry_updated_at();
