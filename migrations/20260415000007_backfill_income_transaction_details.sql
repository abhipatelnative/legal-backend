-- Migration: 20260415000007 - Backfill payment_transaction_details for existing income records
-- Purpose: Income records created before the API fix have a payment_transactions_registry row
--          but NO payment_transaction_details row, so calculate_account_balance() (which joins
--          on ptd.bank_account_id) never credits the bank account. This migration inserts the
--          missing detail rows so existing income-linked balances become correct.
-- Safety:  Only inserts where a details row does not already exist for that transaction.
--          Source of truth for amount / bank_account_id / payment_mode is income_records.

INSERT INTO public.payment_transaction_details (
  payment_id,
  bank_account_id,
  payment_mode,
  amount,
  transaction_reference,
  remarks
)
SELECT
  ir.transaction_id,
  ir.bank_account_id,
  ir.payment_mode,
  ir.amount,
  ir.reference_number,
  COALESCE(ir.remarks, 'Income: ' || ir.income_name)
FROM public.income_records ir
WHERE ir.transaction_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.payment_transaction_details ptd
    WHERE ptd.payment_id = ir.transaction_id
  );

-- Also backfill source_type / source_id on registry rows that reference income but are missing
-- the link back to income_records.id (useful for audit/reporting).
UPDATE public.payment_transactions_registry ptr
SET
  source_type = 'income',
  source_id   = ir.id
FROM public.income_records ir
WHERE ir.transaction_id = ptr.id
  AND ptr.transaction_type = 'INCOME'
  AND (ptr.source_type IS NULL OR ptr.source_id IS NULL);
