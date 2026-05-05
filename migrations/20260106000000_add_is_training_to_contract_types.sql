-- ============================================================================
-- Add is_training column to contract_types table
-- ============================================================================
-- This migration adds an is_training boolean column to identify training
-- contracts which may have different rules or handling in the system.
-- ============================================================================

-- Add is_training column to contract_types table
ALTER TABLE public.contract_types
ADD COLUMN IF NOT EXISTS is_training BOOLEAN NULL DEFAULT false;

-- Add comment to the column
COMMENT ON COLUMN public.contract_types.is_training IS 'Indicates whether this contract type is for training purposes. Training contracts may have different rules or handling.';

-- Create index for faster filtering by is_training
CREATE INDEX IF NOT EXISTS idx_contract_types_is_training 
ON public.contract_types USING btree (is_training) 
TABLESPACE pg_default;
