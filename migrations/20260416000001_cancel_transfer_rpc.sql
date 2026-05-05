-- Add Status to Account Transfers and Create Cancellation RPC
-- Migration: 20260416000001
-- Purpose: Support atomic cancellation of inter-account transfers

-- 1. Add status and cancellation fields to account_transfers
ALTER TABLE public.account_transfers 
ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'completed' CHECK (status IN ('completed', 'cancelled')),
ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;

-- 2. Create the Cancellation RPC
CREATE OR REPLACE FUNCTION public.cancel_account_transfer(
  p_transfer_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_debit_id UUID;
  v_credit_id UUID;
  v_status VARCHAR;
BEGIN
  -- 1. Get current user ID
  v_user_id := auth.uid();

  -- 2. Get transfer record and current status
  SELECT status, debit_transaction_id, credit_transaction_id 
  INTO v_status, v_debit_id, v_credit_id
  FROM public.account_transfers
  WHERE id = p_transfer_id;

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfer record not found');
  END IF;

  IF v_status = 'cancelled' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfer is already cancelled');
  END IF;

  -- 3. Atomically cancel everything
  -- Update Transfer Log
  UPDATE public.account_transfers 
  SET 
    status = 'cancelled',
    cancelled_at = NOW(),
    cancelled_by = v_user_id,
    cancellation_reason = p_reason
  WHERE id = p_transfer_id;

  -- Update Registry Header for Debit Leg
  UPDATE public.payment_transactions_registry
  SET 
    status = 'cancelled',
    cancelled_at = NOW(),
    cancelled_by = v_user_id,
    cancellation_reason = COALESCE(p_reason, 'Transfer Cancelled')
  WHERE id = v_debit_id;

  -- Update Registry Header for Credit Leg
  UPDATE public.payment_transactions_registry
  SET 
    status = 'cancelled',
    cancelled_at = NOW(),
    cancelled_by = v_user_id,
    cancellation_reason = COALESCE(p_reason, 'Transfer Cancelled')
  WHERE id = v_credit_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Transfer and linked ledger entries cancelled successfully'
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION public.cancel_account_transfer IS 'Atomically cancels an inter-account transfer and its corresponding ledger entries.';
