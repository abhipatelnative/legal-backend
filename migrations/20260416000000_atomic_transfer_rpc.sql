-- Create Atomic Transfer Function
-- Migration: 20260416000000
-- Purpose: Ensures inter-account transfers are performed in a single atomic transaction

CREATE OR REPLACE FUNCTION public.perform_account_transfer(
  p_from_account_id UUID,
  p_to_account_id UUID,
  p_amount DECIMAL(15,2),
  p_transfer_date DATE DEFAULT CURRENT_DATE,
  p_remarks TEXT DEFAULT NULL
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

  -- 2. Validate using existing logic (Balance check, account existence, etc.)
  v_val := public.validate_transfer(p_from_account_id, p_to_account_id, p_amount);
  IF NOT (v_val->>'valid')::BOOLEAN THEN
    RETURN jsonb_build_object('success', false, 'error', v_val->>'error');
  END IF;

  -- 3. Create Debit Transaction Header (GIVEN)
  INSERT INTO public.payment_transactions_registry (
    transaction_date, 
    transaction_type, 
    direction, 
    total_amount, 
    status, 
    remarks, 
    created_by, 
    source_type,
    created_at,
    updated_at
  ) VALUES (
    p_transfer_date, 
    'TRANSFER', 
    'GIVEN', 
    p_amount, 
    'completed', 
    COALESCE(p_remarks, 'Account Transfer (Out)'), 
    v_user_id, 
    'transfer',
    NOW(),
    NOW()
  ) RETURNING id INTO v_debit_id;

  -- 4. Create Debit Transaction Detail
  INSERT INTO public.payment_transaction_details (
    payment_id, 
    bank_account_id, 
    payment_mode, 
    amount, 
    remarks,
    created_at
  ) VALUES (
    v_debit_id, 
    p_from_account_id, 
    'bank_transfer', 
    p_amount, 
    p_remarks,
    NOW()
  );

  -- 5. Create Credit Transaction Header (RECEIVED)
  INSERT INTO public.payment_transactions_registry (
    transaction_date, 
    transaction_type, 
    direction, 
    total_amount, 
    status, 
    remarks, 
    created_by, 
    source_type,
    created_at,
    updated_at
  ) VALUES (
    p_transfer_date, 
    'TRANSFER', 
    'RECEIVED', 
    p_amount, 
    'completed', 
    COALESCE(p_remarks, 'Account Transfer (In)'), 
    v_user_id, 
    'transfer',
    NOW(),
    NOW()
  ) RETURNING id INTO v_credit_id;

  -- 6. Create Credit Transaction Detail
  INSERT INTO public.payment_transaction_details (
    payment_id, 
    bank_account_id, 
    payment_mode, 
    amount, 
    remarks,
    created_at
  ) VALUES (
    v_credit_id, 
    p_to_account_id, 
    'bank_transfer', 
    p_amount, 
    p_remarks,
    NOW()
  );

  -- 7. Create Account Transfer Log Record linking both legs
  INSERT INTO public.account_transfers (
    from_account_id, 
    to_account_id, 
    amount, 
    transfer_date, 
    remarks, 
    debit_transaction_id, 
    credit_transaction_id, 
    created_by,
    created_at
  ) VALUES (
    p_from_account_id, 
    p_to_account_id, 
    p_amount, 
    p_transfer_date, 
    p_remarks,
    v_debit_id, 
    v_credit_id, 
    v_user_id,
    NOW()
  ) RETURNING id INTO v_transfer_id;

  -- 8. Backfill source_id on the registry rows for circular traceability
  UPDATE public.payment_transactions_registry 
  SET source_id = v_transfer_id 
  WHERE id IN (v_debit_id, v_credit_id);

  RETURN jsonb_build_object(
    'success', true,
    'transfer_id', v_transfer_id,
    'debit_id', v_debit_id,
    'credit_id', v_credit_id
  );
EXCEPTION WHEN OTHERS THEN
  -- PostgreSQL automatically rolls back if any part of the function fails
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION public.perform_account_transfer IS 'Performs an atomic money transfer between two bank accounts, creating all necessary ledger entries and logs.';
