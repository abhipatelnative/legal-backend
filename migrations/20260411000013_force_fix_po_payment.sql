-- Cash & Bank Integration - Patch: Force Fix record_po_payment Function
-- Migration: 20260411000013
-- Purpose: Completely remove all versions of record_po_payment and recreate cleanly

-- Step 1: Find and drop ALL versions of the function
DO $$
DECLARE
  func_record RECORD;
BEGIN
  -- Loop through all versions of record_po_payment in public schema
  FOR func_record IN 
    SELECT proname, oid, proargtypes::regtype[] as arg_types
    FROM pg_proc
    WHERE proname = 'record_po_payment' 
      AND pronamespace = 'public'::regnamespace
  LOOP
    -- Drop each version by its OID (works regardless of signature)
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', func_record.oid::regprocedure);
    RAISE NOTICE 'Dropped function version: %', func_record.oid::regprocedure;
  END LOOP;
END $$;

-- Step 2: Verify all versions are dropped
DO $$
DECLARE
  count INT;
BEGIN
  SELECT COUNT(*) INTO count
  FROM pg_proc
  WHERE proname = 'record_po_payment' 
    AND pronamespace = 'public'::regnamespace;
  
  IF count > 0 THEN
    RAISE EXCEPTION 'Still found % versions of record_po_payment. Manual cleanup required.', count;
  ELSE
    RAISE NOTICE 'All versions of record_po_payment successfully dropped.';
  END IF;
END $$;

-- Step 3: Create the new version with Cash & Bank integration
CREATE FUNCTION public.record_po_payment(
  p_po_id UUID,
  p_amount DECIMAL(15,2),
  p_payment_type VARCHAR(20),
  p_payment_method VARCHAR(50),
  p_reference_number VARCHAR(100),
  p_notes TEXT,
  p_created_by UUID,
  p_bank_account_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_payment_id UUID;
  v_po_status VARCHAR(50);
  v_po_total DECIMAL(15,2);
  v_advance_paid DECIMAL(15,2);
  v_new_paid_amount DECIMAL(15,2);
  v_payment_status VARCHAR(20);
BEGIN
  -- Get PO details
  SELECT status, total_amount, advance_paid_amount
  INTO v_po_status, v_po_total, v_advance_paid
  FROM public.purchase_orders
  WHERE id = p_po_id;

  IF v_po_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Purchase order not found');
  END IF;

  -- Calculate new paid amount
  v_new_paid_amount := COALESCE(v_advance_paid, 0) + p_amount;

  -- Determine payment status
  IF v_new_paid_amount >= v_po_total THEN
    v_payment_status := 'paid';
  ELSIF v_new_paid_amount > 0 THEN
    v_payment_status := 'partial';
  ELSE
    v_payment_status := 'unpaid';
  END IF;

  -- Record payment
  INSERT INTO public.payment_transactions (
    purchase_order_id,
    payment_date,
    payment_amount,
    payment_method,
    payment_reference,
    payment_type,
    payment_status,
    notes,
    created_by,
    bank_account_id
  ) VALUES (
    p_po_id,
    CURRENT_DATE,
    p_amount,
    p_payment_method,
    p_reference_number,
    p_payment_type,
    v_payment_status,
    p_notes,
    p_created_by,
    p_bank_account_id
  ) RETURNING id INTO v_payment_id;

  -- Update PO paid amount and status
  UPDATE public.purchase_orders
  SET
    total_paid_amount = v_new_paid_amount,
    remaining_balance = GREATEST(0, v_po_total - v_new_paid_amount),
    payment_status = v_payment_status,
    updated_at = NOW()
  WHERE id = p_po_id;

  -- Cash & Bank Integration: Create entry in payment_transactions_registry
  IF p_bank_account_id IS NOT NULL THEN
    INSERT INTO public.payment_transactions_registry (
      transaction_date,
      transaction_type,
      direction,
      total_amount,
      source_type,
      source_id,
      reference_number,
      remarks,
      status,
      created_by
    ) VALUES (
      CURRENT_DATE,
      'PURCHASE_ORDER',
      'GIVEN',
      p_amount,
      'purchase_order',
      p_po_id,
      p_reference_number,
      p_notes,
      'completed',
      p_created_by
    );

    -- Create payment_transaction_details
    INSERT INTO public.payment_transaction_details (
      payment_id,
      bank_account_id,
      payment_mode,
      amount,
      transaction_reference,
      remarks
    )
    SELECT
      id,
      p_bank_account_id,
      CASE LOWER(p_payment_method)
        WHEN 'cash' THEN 'cash'
        WHEN 'cheque' THEN 'cheque'
        WHEN 'card' THEN 'card'
        WHEN 'upi' THEN 'upi'
        WHEN 'bank transfer' THEN 'bank_transfer'
        ELSE 'bank_transfer'
      END,
      p_amount,
      p_reference_number,
      p_notes
    FROM public.payment_transactions_registry
    WHERE source_type = 'purchase_order'
      AND source_id = p_po_id
      AND created_by = p_created_by
    ORDER BY created_at DESC
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'payment_id', v_payment_id,
    'payment_status', v_payment_status,
    'total_paid', v_new_paid_amount
  );
END;
$$;

COMMENT ON FUNCTION public.record_po_payment IS 'Record payment for purchase order with Cash & Bank integration';

-- Step 4: Verify exactly one version exists
SELECT proname, pronargs, proargnames
FROM pg_proc
WHERE proname = 'record_po_payment' AND pronamespace = 'public'::regnamespace;
-- Expected: Exactly 1 row with 8 arguments
