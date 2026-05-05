-- Income Records Module - Full CRUD with Cash & Bank Integration
-- Migration: 20260415000000
-- Purpose: Create income_records table for tracking company income
-- Notes: Income auto-creates RECEIVED transaction in payment_transactions_registry
--        Cancel/Edit cascades to keep Cash & Bank balances in sync

-- ============================================================================
-- 1. UPDATE payment_transactions_registry ENUM to include 'INCOME'
-- ============================================================================

-- Drop existing constraint
ALTER TABLE public.payment_transactions_registry
DROP CONSTRAINT IF EXISTS payment_transactions_registry_transaction_type_check;

-- Add new constraint with INCOME included
ALTER TABLE public.payment_transactions_registry
ADD CONSTRAINT payment_transactions_registry_transaction_type_check
CHECK (transaction_type IN (
  'OPENING_BALANCE', 'EXPENSE', 'SERVICE_ORDER', 'PAYROLL',
  'PURCHASE_ORDER', 'TRANSFER', 'BALANCE_ADJUSTMENT', 'INCOME'
));

-- ============================================================================
-- 2. CREATE income_records TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.income_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  income_date DATE NOT NULL,
  income_name VARCHAR(255) NOT NULL,
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  bank_account_id UUID NOT NULL REFERENCES public.bank_accounts(id),
  payment_mode VARCHAR(50) NOT NULL CHECK (payment_mode IN ('cash', 'cheque', 'card', 'upi', 'bank_transfer', 'online')),
  reference_number VARCHAR(100),
  client_id UUID REFERENCES public.clients(id),
  employee_id UUID REFERENCES public.employees(id),
  remarks TEXT,
  status VARCHAR(20) NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'cancelled')),
  transaction_id UUID REFERENCES public.payment_transactions_registry(id),
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  cancelled_at TIMESTAMP WITH TIME ZONE,
  cancelled_by UUID REFERENCES auth.users(id),
  cancellation_reason TEXT
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_income_date ON public.income_records(income_date);
CREATE INDEX IF NOT EXISTS idx_income_bank_account ON public.income_records(bank_account_id);
CREATE INDEX IF NOT EXISTS idx_income_status ON public.income_records(status);
CREATE INDEX IF NOT EXISTS idx_income_client ON public.income_records(client_id) WHERE client_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_income_employee ON public.income_records(employee_id) WHERE employee_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_income_transaction ON public.income_records(transaction_id) WHERE transaction_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_income_created_by ON public.income_records(created_by);

-- Add comments
COMMENT ON TABLE public.income_records IS 'Records of income received into company accounts';
COMMENT ON COLUMN public.income_records.transaction_id IS 'Links to auto-created payment transaction for balance sync';
COMMENT ON COLUMN public.income_records.payment_mode IS 'cash, cheque, card, upi, bank_transfer, online';

-- ============================================================================
-- 3. CREATE updated_at TRIGGER
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_income_records_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_income_records_updated_at
BEFORE UPDATE ON public.income_records
FOR EACH ROW
EXECUTE FUNCTION public.update_income_records_updated_at();

-- ============================================================================
-- 4. ENABLE ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE public.income_records ENABLE ROW LEVEL SECURITY;

-- Policy: Allow authenticated users full access
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
    AND tablename = 'income_records'
    AND policyname = 'Allow authenticated users to manage income records'
  ) THEN
    CREATE POLICY "Allow authenticated users to manage income records"
    ON public.income_records
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);
  END IF;
END $$;

-- ============================================================================
-- 5. ADD TO GLOBAL SEARCH INDEX
-- ============================================================================

-- This will be added to the global_search_index materialized view.
-- The materialized view is refreshed automatically via the refresh_search_index function.
-- We add the income UNION clause to the view definition.

-- NOTE: Since global_search_index is a materialized view, we need to recreate it.
-- The latest global_search migration (20260405000001) defines the full structure.
-- We create a new migration that adds the income UNION ALL clause and recreates the view.

-- For now, we create a helper that will be called after this migration to update the materialized view.
-- The actual materialized view update is in migration 20260415000001_global_search_income.sql.
