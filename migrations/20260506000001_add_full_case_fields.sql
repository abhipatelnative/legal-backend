-- Add structured fields to order_cases to mirror the official eCourt page layout
-- (filing/registration numbers, acts/sections, parties with advocates, judges,
-- processes, FIR details) and tighten the status enum from 4 values to 2:
-- Pending | Disposed.

-- ── 1. Tighten status to two values + migrate existing data ─────────────────
ALTER TABLE public.order_cases DROP CONSTRAINT IF EXISTS order_cases_status_check;

UPDATE public.order_cases
   SET status = CASE
     WHEN status IN ('Active', 'On Hold')      THEN 'Pending'
     WHEN status IN ('Closed', 'Transferred')  THEN 'Disposed'
     WHEN status IN ('Pending', 'Disposed')    THEN status
     ELSE 'Pending'
   END;

ALTER TABLE public.order_cases
  ALTER COLUMN status SET DEFAULT 'Pending';

ALTER TABLE public.order_cases
  ADD CONSTRAINT order_cases_status_check CHECK (status IN ('Pending', 'Disposed'));

-- ── 2. Add structured columns matching the eCourt layout ───────────────────
ALTER TABLE public.order_cases
  ADD COLUMN IF NOT EXISTS filing_number          TEXT,
  ADD COLUMN IF NOT EXISTS registration_number    TEXT,
  ADD COLUMN IF NOT EXISTS registration_date      DATE,
  ADD COLUMN IF NOT EXISTS e_filing_number        TEXT,
  ADD COLUMN IF NOT EXISTS e_filing_date          DATE,
  ADD COLUMN IF NOT EXISTS first_hearing_date     DATE,
  ADD COLUMN IF NOT EXISTS next_hearing_date      DATE,
  ADD COLUMN IF NOT EXISTS case_stage             TEXT,
  ADD COLUMN IF NOT EXISTS court_number_and_judge TEXT,
  ADD COLUMN IF NOT EXISTS acts                   TEXT,
  ADD COLUMN IF NOT EXISTS sections               TEXT,
  ADD COLUMN IF NOT EXISTS petitioners            JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS respondents            JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS judges                 JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS processes              JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS fir_details            JSONB;

CREATE INDEX IF NOT EXISTS order_cases_filing_number_idx
  ON public.order_cases (filing_number) WHERE filing_number IS NOT NULL;

CREATE INDEX IF NOT EXISTS order_cases_next_hearing_idx
  ON public.order_cases (next_hearing_date) WHERE next_hearing_date IS NOT NULL;
