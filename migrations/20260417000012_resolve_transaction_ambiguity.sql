-- Cash & Bank Module - Resolve Function Ambiguity
-- Migration: 20260417000012
-- Purpose: Resolve ambiguity by dropping old versions of functions that use DATE or TIMESTAMP (without time zone)
--          since we have migrated to TIMESTAMP WITH TIME ZONE.

-- 1. Resolve ambiguity for record_payment_v2
-- We drop the version that takes DATE as the last parameter.
DROP FUNCTION IF EXISTS public.record_payment_v2(
  VARCHAR, -- p_source_type
  UUID,    -- p_source_id
  DECIMAL, -- p_amount
  VARCHAR, -- p_payment_method
  UUID,    -- p_bank_account_id
  VARCHAR, -- p_reference_number
  TEXT,    -- p_notes
  JSONB,   -- p_metadata
  UUID,    -- p_created_by
  DATE     -- p_payment_date (OLD VERSION)
) CASCADE;

-- 2. Resolve ambiguity for perform_account_transfer
-- We drop all versions that use DATE or TIMESTAMP WITHOUT TIME ZONE.
DROP FUNCTION IF EXISTS public.perform_account_transfer(UUID, UUID, DECIMAL, DATE, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.perform_account_transfer(UUID, UUID, DECIMAL, DATE, TEXT, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS public.perform_account_transfer(UUID, UUID, DECIMAL, TIMESTAMP WITHOUT TIME ZONE, TEXT) CASCADE;

-- 3. Re-verify that our new TIMESTAMPTZ version of calculate_account_balance remains the primary candidate
-- (This was already handled in 000011, but we do a final check)
COMMENT ON FUNCTION public.record_payment_v2(VARCHAR, UUID, DECIMAL, VARCHAR, UUID, VARCHAR, TEXT, JSONB, UUID, TIMESTAMP WITH TIME ZONE) 
  IS 'Primary payment RPC using TIMESTAMP WITH TIME ZONE for precision.';

COMMENT ON FUNCTION public.perform_account_transfer(UUID, UUID, DECIMAL, TIMESTAMP WITH TIME ZONE, TEXT) 
  IS 'Primary account transfer RPC using TIMESTAMP WITH TIME ZONE for precision.';
