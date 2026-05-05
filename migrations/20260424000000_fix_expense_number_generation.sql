-- Fix expense_number auto-generation.
--
-- The previous trigger used `SUBSTRING(expense_number FROM 9)` to extract the
-- numeric suffix, but "EXP-YYYY-" is 9 characters so the numeric part starts
-- at position 10. FROM 9 returned "-0001", which CAST parsed as -1, and the
-- MAX(+1) calculation then oscillated between 0000 and 0001 — producing
-- identical expense numbers on every new insert and UNIQUE violations.
--
-- This migration:
--   1. Drops the buggy trigger + function.
--   2. Backfills NULL/empty/duplicate expense_number rows with fresh values.
--   3. Restores NOT NULL + UNIQUE constraints.
--   4. Recreates the trigger using a regex extractor that is prefix-length
--      agnostic, guarded by a per-year advisory lock.

-- 1. Reset any existing trigger/function so we start clean.
DROP TRIGGER IF EXISTS trigger_generate_expense_number ON public.expenses;
DROP FUNCTION IF EXISTS public.generate_expense_number();

-- 2. Backfill. We nullify duplicates (keeping the earliest per group) and then
--    renumber every row with a NULL/empty expense_number. Soft-deleted rows
--    participate because the UNIQUE constraint applies to all rows.
DO $$
DECLARE
    rec RECORD;
    v_year VARCHAR(4);
    v_sequence INTEGER;
    v_new_number VARCHAR(50);
BEGIN
    -- Nullify duplicate expense_numbers, keeping the earliest created row.
    UPDATE public.expenses
    SET expense_number = NULL
    WHERE id IN (
        SELECT id
        FROM (
            SELECT id,
                   ROW_NUMBER() OVER (
                       PARTITION BY expense_number
                       ORDER BY created_at ASC, id ASC
                   ) AS rn
            FROM public.expenses
            WHERE expense_number IS NOT NULL
              AND expense_number <> ''
        ) d
        WHERE d.rn > 1
    );

    -- Assign fresh EXP-YYYY-#### numbers to every un-numbered row, grouped by
    -- the year of the expense_date (falling back to created_at).
    FOR rec IN
        SELECT id,
               TO_CHAR(COALESCE(expense_date, created_at::date, CURRENT_DATE), 'YYYY') AS year
        FROM public.expenses
        WHERE expense_number IS NULL OR expense_number = ''
        ORDER BY created_at ASC, id ASC
    LOOP
        v_year := rec.year;

        SELECT COALESCE(
                   MAX(CAST(substring(expense_number FROM '(\d+)$') AS INTEGER)),
                   0
               ) + 1
        INTO v_sequence
        FROM public.expenses
        WHERE expense_number LIKE 'EXP-' || v_year || '-%';

        v_new_number := 'EXP-' || v_year || '-' || LPAD(v_sequence::TEXT, 4, '0');

        UPDATE public.expenses
        SET expense_number = v_new_number
        WHERE id = rec.id;
    END LOOP;
END $$;

-- 3. Restore NOT NULL + UNIQUE now that every row has a valid value.
ALTER TABLE public.expenses
    ALTER COLUMN expense_number SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'expenses_expense_number_key'
          AND conrelid = 'public.expenses'::regclass
    ) THEN
        ALTER TABLE public.expenses
            ADD CONSTRAINT expenses_expense_number_key UNIQUE (expense_number);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_expenses_number
    ON public.expenses(expense_number);

-- 4. Correct generator. `substring(value FROM '(\d+)$')` captures the trailing
--    digits regardless of prefix length. The advisory lock is scoped per-year
--    so concurrent inserts serialize only against each other.
CREATE OR REPLACE FUNCTION public.generate_expense_number()
RETURNS TRIGGER AS $$
DECLARE
    v_year VARCHAR(4);
    v_sequence INTEGER;
    v_lock_key BIGINT;
BEGIN
    v_year := TO_CHAR(CURRENT_DATE, 'YYYY');
    v_lock_key := hashtext('expense_number_' || v_year);

    PERFORM pg_advisory_xact_lock(v_lock_key);

    SELECT COALESCE(
               MAX(CAST(substring(expense_number FROM '(\d+)$') AS INTEGER)),
               0
           ) + 1
    INTO v_sequence
    FROM public.expenses
    WHERE expense_number LIKE 'EXP-' || v_year || '-%';

    NEW.expense_number := 'EXP-' || v_year || '-' || LPAD(v_sequence::TEXT, 4, '0');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 5. Reattach trigger. Only fires when the caller did not supply a number.
CREATE TRIGGER trigger_generate_expense_number
    BEFORE INSERT ON public.expenses
    FOR EACH ROW
    WHEN (NEW.expense_number IS NULL OR NEW.expense_number = '')
    EXECUTE FUNCTION public.generate_expense_number();
