-- Cash & Bank Integration - Database Schema Updates
-- Migration: 20260411000009
-- Purpose: Add bank_account_id to existing payment tables for full integration

-- ============================================
-- 1. Add bank_account_id to expense_payments
-- ============================================
DO $$
BEGIN
  -- Check if column already exists
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'expense_payments'
      AND column_name = 'bank_account_id'
  ) THEN
    ALTER TABLE public.expense_payments
    ADD COLUMN bank_account_id UUID REFERENCES public.bank_accounts(id);

    CREATE INDEX IF NOT EXISTS idx_expense_payments_bank_account ON public.expense_payments(bank_account_id);

    RAISE NOTICE 'Added bank_account_id to expense_payments';
  ELSE
    RAISE NOTICE 'bank_account_id already exists in expense_payments';
  END IF;
END $$;

-- ============================================
-- 2. Add bank_account_id to payment_transactions_service_orders
-- ============================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payment_transactions_service_orders'
      AND column_name = 'bank_account_id'
  ) THEN
    ALTER TABLE public.payment_transactions_service_orders
    ADD COLUMN bank_account_id UUID REFERENCES public.bank_accounts(id);

    CREATE INDEX IF NOT EXISTS idx_ptso_bank_account ON public.payment_transactions_service_orders(bank_account_id);

    RAISE NOTICE 'Added bank_account_id to payment_transactions_service_orders';
  ELSE
    RAISE NOTICE 'bank_account_id already exists in payment_transactions_service_orders';
  END IF;
END $$;

-- ============================================
-- 3. Add bank_account_id to payment_transactions (POs)
-- ============================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payment_transactions'
      AND column_name = 'bank_account_id'
  ) THEN
    ALTER TABLE public.payment_transactions
    ADD COLUMN bank_account_id UUID REFERENCES public.bank_accounts(id);

    CREATE INDEX IF NOT EXISTS idx_pt_bank_account ON public.payment_transactions(bank_account_id);

    RAISE NOTICE 'Added bank_account_id to payment_transactions';
  ELSE
    RAISE NOTICE 'bank_account_id already exists in payment_transactions';
  END IF;
END $$;

-- ============================================
-- 4. Add bank account tracking to payroll
-- ============================================
DO $$
BEGIN
  -- Add paid_from_account_id
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payroll'
      AND column_name = 'paid_from_account_id'
  ) THEN
    ALTER TABLE public.payroll
    ADD COLUMN paid_from_account_id UUID REFERENCES public.bank_accounts(id);

    CREATE INDEX IF NOT EXISTS idx_payroll_paid_from_account ON public.payroll(paid_from_account_id);

    RAISE NOTICE 'Added paid_from_account_id to payroll';
  ELSE
    RAISE NOTICE 'paid_from_account_id already exists in payroll';
  END IF;

  -- Add payment_recorded_at
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payroll'
      AND column_name = 'payment_recorded_at'
  ) THEN
    ALTER TABLE public.payroll
    ADD COLUMN payment_recorded_at TIMESTAMP WITH TIME ZONE;

    RAISE NOTICE 'Added payment_recorded_at to payroll';
  ELSE
    RAISE NOTICE 'payment_recorded_at already exists in payroll';
  END IF;

  -- Add payment_recorded_by
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payroll'
      AND column_name = 'payment_recorded_by'
  ) THEN
    ALTER TABLE public.payroll
    ADD COLUMN payment_recorded_by UUID REFERENCES auth.users(id);

    RAISE NOTICE 'Added payment_recorded_by to payroll';
  ELSE
    RAISE NOTICE 'payment_recorded_by already exists in payroll';
  END IF;
END $$;

-- ============================================
-- Verification Queries
-- ============================================
-- SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'expense_payments' AND column_name LIKE '%bank%';
-- SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'payment_transactions_service_orders' AND column_name LIKE '%bank%';
-- SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'payment_transactions' AND column_name LIKE '%bank%';
-- SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'payroll' AND column_name LIKE '%paid%' OR column_name LIKE '%payment_recorded%';
