-- ============================================
-- Migration: 20260501000001 - Make income_records.bank_account_id nullable
-- ============================================
-- Purpose: Support Cash & Bank module-OFF mode for income records.
-- When the Cash & Bank module is disabled, the income dialog never collects a
-- bank account, and the registry/balance side-effects are skipped. The
-- income_records row should still persist; the NOT NULL constraint blocks that.
-- Drop the NOT NULL — the FK is preserved, so any provided id still validates.
-- ============================================

ALTER TABLE public.income_records
  ALTER COLUMN bank_account_id DROP NOT NULL;
