-- Add notes column to order_cases table
-- Used by case-matter UI to store arbitrary notes on a case.

ALTER TABLE public.order_cases
  ADD COLUMN IF NOT EXISTS notes TEXT;
