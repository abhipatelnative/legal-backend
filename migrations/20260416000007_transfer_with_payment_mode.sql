-- Cash & Bank Module - Transfer with Payment Mode
-- Migration: 20260416000007
-- Purpose: Allow specifying a payment mode for inter-account transfers

-- Drop existing to change signature
DROP FUNCTION IF EXISTS public.perform_account_transfer(UUID, UUID, DECIMAL, DATE, TEXT) CASCADE;

CREATE OR REPLACE FUNCTION public.perform_account_transfer(
  p_from_account_id UUID,
  p_to_account_id UUID,
  p_amount DECIMAL(15,2),
  p_transfer_date DATE DEFAULT CURRENT_DATE,
  p_remarks TEXT DEFAULT NULL,
  p_payment_mode VARCHAR(50) DEFAULT 'bank_transfer'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_debit_id UUID;
  v_credit_id UUID;
  v_transfer_id UUID;
  v_val JSONB;
BEGIN
  -- 1. Get current user ID from Supabase context
  v_user_id := auth.uid();

  -- 2. Validate using existing logic
  v_val := public.validate_transfer(p_from_account_id, p_to_account_id, p_amount);
  IF NOT (v_val->>'valid')::BOOLEAN THEN
    RETURN jsonb_build_object('success', false, 'error', v_val->>'error');
  END IF;

  -- 3. Create Debit Transaction Header (GIVEN)
  INSERT INTO public.payment_transactions_registry (
    transaction_date, transaction_type, direction, total_amount, status, remarks, created_by, source_type
  ) VALUES (
    p_transfer_date, 'TRANSFER', 'GIVEN', p_amount, 'completed', COALESCE(p_remarks, 'Account Transfer (Out)'), v_user_id, 'transfer'
  ) RETURNING id INTO v_debit_id;

  -- 4. Create Debit Transaction Detail
  INSERT INTO public.payment_transaction_details (
    payment_id, bank_account_id, payment_mode, amount, remarks
  ) VALUES (
    v_debit_id, p_from_account_id, p_payment_mode, p_amount, p_remarks
  );

  -- 5. Create Credit Transaction Header (RECEIVED)
  INSERT INTO public.payment_transactions_registry (
    transaction_date, transaction_type, direction, total_amount, status, remarks, created_by, source_type
  ) VALUES (
    p_transfer_date, 'TRANSFER', 'RECEIVED', p_amount, 'completed', COALESCE(p_remarks, 'Account Transfer (In)'), v_user_id, 'transfer'
  ) RETURNING id INTO v_credit_id;

  -- 6. Create Credit Transaction Detail
  INSERT INTO public.payment_transaction_details (
    payment_id, bank_account_id, payment_mode, amount, remarks
  ) VALUES (
    v_credit_id, p_to_account_id, p_payment_mode, p_amount, p_remarks
  );

  -- 7. Create Account Transfer Log Record
  INSERT INTO public.account_transfers (
    from_account_id, to_account_id, amount, transfer_date, remarks, debit_transaction_id, credit_transaction_id, created_by
  ) VALUES (
    p_from_account_id, p_to_account_id, p_amount, p_transfer_date, p_remarks, v_debit_id, v_credit_id, v_user_id
  ) RETURNING id INTO v_transfer_id;

  -- 8. Backfill source_id
  UPDATE public.payment_transactions_registry SET source_id = v_transfer_id WHERE id IN (v_debit_id, v_credit_id);

  RETURN jsonb_build_object(
    'success', true,
    'transfer_id', v_transfer_id,
    'debit_id', v_debit_id,
    'credit_id', v_credit_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
