-- ============================================================================
-- Migration: 20260411000013 - Fix record_po_payment with Cash & Bank Integration
-- Purpose: Clean drop, recreate, and fix race conditions in payment details insert
-- ============================================================================

-- Step 1: Drop ALL existing versions of the function safely
-- Bare "DROP FUNCTION name" only works when exactly one overload exists; iterating
-- pg_proc and dropping by OID handles any mix of overloads from earlier migrations.
-- CASCADE ensures dependent views/functions are updated automatically.
DO $$
DECLARE
  func_record RECORD;
BEGIN
  FOR func_record IN
    SELECT oid
    FROM pg_proc
    WHERE proname = 'record_po_payment'
      AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', func_record.oid::regprocedure);
  END LOOP;
END $$;

-- Step 2: Create the corrected version
CREATE OR REPLACE FUNCTION public.record_po_payment(
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
  v_registry_id UUID;
  v_po_status VARCHAR(50);
  v_po_total DECIMAL(15,2);
  v_advance_paid DECIMAL(15,2);
  v_new_paid_amount DECIMAL(15,2);
  v_payment_status VARCHAR(20);
BEGIN
  -- 1. Validate & Fetch PO Details
  SELECT status, total_amount, COALESCE(advance_paid_amount, 0)
  INTO v_po_status, v_po_total, v_advance_paid
  FROM public.purchase_orders
  WHERE id = p_po_id;

  IF v_po_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Purchase order not found');
  END IF;

  -- 2. Calculate Payment Status
  v_new_paid_amount := v_advance_paid + p_amount;
  
  IF v_new_paid_amount >= v_po_total THEN
    v_payment_status := 'paid';
  ELSIF v_new_paid_amount > 0 THEN
    v_payment_status := 'partial';
  ELSE
    v_payment_status := 'unpaid';
  END IF;

  -- 3. Record in PO-Specific Payment Log
  INSERT INTO public.payment_transactions (
    purchase_order_id,
    payment_date,
    payment_amount,
    payment_method,
    payment_reference,
    payment_type,
    payment_status,
    notes,
    created_by
  ) VALUES (
    p_po_id,
    CURRENT_DATE,
    p_amount,
    p_payment_method,
    p_reference_number,
    p_payment_type,
    v_payment_status,
    p_notes,
    p_created_by
  ) RETURNING id INTO v_payment_id;

  -- 4. Cash & Bank Integration: Record in Global Registry
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
    ) RETURNING id INTO v_registry_id; -- FIX: Capture ID immediately to avoid race conditions

    -- 5. Create Transaction Details linked to Registry
    INSERT INTO public.payment_transaction_details (
      payment_id,
      bank_account_id,
      payment_mode,
      amount,
      transaction_reference,
      remarks
    ) VALUES (
      v_registry_id, -- FIX: Use captured registry ID
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
    );
  END IF;

  -- 6. Update Purchase Order Balances
  UPDATE public.purchase_orders
  SET
    total_paid_amount = v_new_paid_amount,
    remaining_balance = GREATEST(0, v_po_total - v_new_paid_amount),
    payment_status = v_payment_status,
    updated_at = NOW()
  WHERE id = p_po_id;

  -- 7. Return Success Response
  RETURN jsonb_build_object(
    'success', true,
    'payment_id', v_payment_id,
    'registry_id', v_registry_id,
    'payment_status', v_payment_status,
    'total_paid', v_new_paid_amount,
    'remaining_balance', GREATEST(0, v_po_total - v_new_paid_amount)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION public.record_po_payment IS 'Record PO payment with Cash & Bank registry integration. Returns payment IDs and updated status.';

-- Step 3: Verification
SELECT 
  proname AS function_name, 
  pronargs AS argument_count,
  proargnames AS argument_names
FROM pg_proc
WHERE proname = 'record_po_payment' 
  AND pronamespace = 'public'::regnamespace;

-- Expected Output: 1 row, 8 arguments
