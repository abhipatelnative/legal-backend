-- Migration to add contract_id to employee_shifts and backfill data

-- 1. Ensure the column exists (User said they want to "direct add thier contract ld")
-- Check if column exists, if not add it (idempotent)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'employee_shifts' AND column_name = 'contract_id') THEN
        ALTER TABLE public.employee_shifts ADD COLUMN contract_id uuid REFERENCES public.contracts(id) ON DELETE CASCADE;
    END IF;
END $$;

-- 2. Backfill contract_id for existing shifts
-- We assume the active contract is the one that applies.
-- If an employee has multiple active contracts, this might pick one arbitrarily or fail if not careful.
-- We will prioritize 'active' contracts.

UPDATE public.employee_shifts es
SET contract_id = c.id
FROM public.contracts c
WHERE es.employee_id = c.employee_id
  AND c.status = 'active'
  AND es.contract_id IS NULL;

-- 3. For employees with no active contract but maybe a draft or other status, we optionally update or leave null.
-- Let's stick to active for now as that's safe.

-- 4. Update constraints if needed (The user provided specific constraints they want)
-- Drop old constraints if they exist to avoid conflicts
ALTER TABLE public.employee_shifts DROP CONSTRAINT IF EXISTS unique_employee_shift; -- Assuming this was the old one
ALTER TABLE public.employee_shifts DROP CONSTRAINT IF EXISTS unique_employee_shift_contract;

-- Add the new unique constraint
ALTER TABLE public.employee_shifts
ADD CONSTRAINT unique_employee_shift_contract UNIQUE (employee_id, contract_id, shift_id, work_week_id);

-- Add foreign key if not exists (already done in step 1 but safe to reiterate or ensure naming)
-- ALTER TABLE public.employee_shifts DROP CONSTRAINT IF EXISTS employee_shifts_contract_id_fkey;
-- ALTER TABLE public.employee_shifts ADD CONSTRAINT employee_shifts_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE CASCADE;
