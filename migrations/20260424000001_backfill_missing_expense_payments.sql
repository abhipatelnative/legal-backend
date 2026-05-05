-- Backfill missing expense_payments rows.
--
-- Background: a prior bug in the AddExpense frontend guarded the
-- expense_payments INSERT behind `!saveAsDraft`, while still writing
-- `total_paid_amount` to the parent expenses row in both draft and non-draft
-- paths. Drafts that were later submitted/approved therefore ended up with a
-- non-zero total_paid_amount on the expense but no matching history in
-- expense_payments. The Payments tab rendered empty and the summary was
-- inconsistent.
--
-- The frontend is now fixed, but existing records need a catch-up payment
-- row so the data reconciles. This migration creates exactly one row per
-- orphaned expense, sized to close the gap between the claimed paid amount
-- and the sum of currently-active payments.
--
-- We intentionally DO NOT insert into payment_transactions_registry or
-- payment_transaction_details. The original bank account is unknown; charging
-- an arbitrary account would silently corrupt bank balances. The payment
-- history becomes visible after this migration, and operators can reconcile
-- the bank ledger through the normal Add-Payment flow once they can identify
-- the affected expenses.

-- ---------------------------------------------------------------------------
-- STEP 0 (optional preview) — run this by itself first to see what will change.
-- Comment the INSERT below, run just the SELECT, verify row counts and
-- amounts, then uncomment and re-run the whole file.
-- ---------------------------------------------------------------------------
--
-- SELECT
--     e.id,
--     e.expense_number,
--     e.status,
--     e.total_paid_amount AS claimed_paid,
--     COALESCE(p.paid_sum, 0) AS actual_paid,
--     e.total_paid_amount - COALESCE(p.paid_sum, 0) AS gap_to_backfill,
--     COALESCE(e.first_payment_date, e.expense_date) AS backfill_date,
--     COALESCE(NULLIF(e.payment_method, ''), 'cash') AS backfill_method
-- FROM public.expenses e
-- LEFT JOIN (
--     SELECT expense_id, SUM(payment_amount) AS paid_sum
--     FROM public.expense_payments
--     WHERE is_active = true
--     GROUP BY expense_id
-- ) p ON p.expense_id = e.id
-- WHERE e.is_deleted = false
--   AND COALESCE(e.total_paid_amount, 0) > 0
--   AND COALESCE(p.paid_sum, 0) < e.total_paid_amount
-- ORDER BY e.created_at;

-- ---------------------------------------------------------------------------
-- STEP 1 — insert one catch-up payment row per orphaned expense.
-- ---------------------------------------------------------------------------
INSERT INTO public.expense_payments (
    expense_id,
    payment_date,
    payment_amount,
    payment_method,
    payment_reference,
    notes,
    processed_by,
    is_active,
    created_at,
    created_by
)
SELECT
    e.id                                                                 AS expense_id,
    COALESCE(e.first_payment_date, e.expense_date, CURRENT_DATE)         AS payment_date,
    e.total_paid_amount - COALESCE(p.paid_sum, 0)                        AS payment_amount,
    COALESCE(NULLIF(e.payment_method, ''), 'cash')                       AS payment_method,
    NULL                                                                 AS payment_reference,
    'Backfilled by migration 20260424000001. Original payment record '
    || 'was lost due to the draft-save bug in AddExpense. Bank ledger '
    || 'was NOT touched — reconcile the disbursement account manually '
    || 'if needed.'                                                      AS notes,
    e.created_by                                                         AS processed_by,
    true                                                                 AS is_active,
    NOW()                                                                AS created_at,
    e.created_by                                                         AS created_by
FROM public.expenses e
LEFT JOIN (
    SELECT expense_id, SUM(payment_amount) AS paid_sum
    FROM public.expense_payments
    WHERE is_active = true
    GROUP BY expense_id
) p ON p.expense_id = e.id
WHERE e.is_deleted = false
  AND COALESCE(e.total_paid_amount, 0) > 0
  AND COALESCE(p.paid_sum, 0) < e.total_paid_amount;

-- ---------------------------------------------------------------------------
-- STEP 2 — verification. After running, these should both return 0 rows.
-- Re-run this section any time to confirm the table stays consistent.
-- ---------------------------------------------------------------------------
--
-- -- a) Any expense still missing payments it claims?
-- SELECT e.id, e.expense_number, e.total_paid_amount, COALESCE(p.paid_sum, 0) AS paid_sum
-- FROM public.expenses e
-- LEFT JOIN (
--     SELECT expense_id, SUM(payment_amount) AS paid_sum
--     FROM public.expense_payments
--     WHERE is_active = true
--     GROUP BY expense_id
-- ) p ON p.expense_id = e.id
-- WHERE e.is_deleted = false
--   AND COALESCE(e.total_paid_amount, 0) > COALESCE(p.paid_sum, 0);
--
-- -- b) Any backfilled rows that need operator attention (to reconcile bank)?
-- SELECT expense_id, payment_date, payment_amount, payment_method
-- FROM public.expense_payments
-- WHERE notes LIKE 'Backfilled by migration 20260424000001%'
-- ORDER BY payment_date DESC;
