-- Cash & Bank Module - Transaction Time Support
-- Migration: 20260417000010
-- Purpose: Support recording and displaying transaction times for better chronological sorting.

-- 1. Alter table columns to support time
ALTER TABLE public.payment_transactions_registry 
  ALTER COLUMN transaction_date TYPE TIMESTAMP WITH TIME ZONE;

ALTER TABLE public.account_transfers 
  ALTER COLUMN transfer_date TYPE TIMESTAMP WITH TIME ZONE;

-- 2. Update calculate_account_balance to handle precise timestamps
-- We need to ensure that when we say "as of a date", we include the whole day if just a date is passed, 
-- or use the exact timestamp if time is present.
CREATE OR REPLACE FUNCTION public.calculate_account_balance(
  p_account_id UUID,
  p_as_of_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
)
RETURNS DECIMAL(15,2)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_opening_balance DECIMAL(15,2);
  v_total_received DECIMAL(15,2);
  v_total_given DECIMAL(15,2);
  v_balance DECIMAL(15,2);
BEGIN
  -- Get opening balance from bank_accounts
  SELECT opening_balance INTO v_opening_balance
  FROM public.bank_accounts
  WHERE id = p_account_id AND deleted_at IS NULL;

  IF v_opening_balance IS NULL THEN
    RETURN 0;
  END IF;

  -- Calculate total received as of the exact timestamp
  SELECT COALESCE(SUM(ptd.amount), 0) INTO v_total_received
  FROM public.payment_transaction_details ptd
  INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
  WHERE ptd.bank_account_id = p_account_id
    AND ptr.direction = 'RECEIVED'
    AND ptr.status = 'completed'
    AND ptr.transaction_date <= p_as_of_date;

  -- Calculate total given as of the exact timestamp
  SELECT COALESCE(SUM(ptd.amount), 0) INTO v_total_given
  FROM public.payment_transaction_details ptd
  INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
  WHERE ptd.bank_account_id = p_account_id
    AND ptr.direction = 'GIVEN'
    AND ptr.status = 'completed'
    AND ptr.transaction_date <= p_as_of_date;

  -- Calculate balance
  v_balance := v_opening_balance + v_total_received - v_total_given;

  RETURN v_balance;
END;
$$;

-- 3. Update get_account_ledger to return TIMESTAMP WITH TIME ZONE
-- Note: We drop and recreate to ensure signature and return types are updated
DROP FUNCTION IF EXISTS public.get_account_ledger(UUID, TIMESTAMP, TIMESTAMP, VARCHAR, VARCHAR, VARCHAR) CASCADE;

CREATE OR REPLACE FUNCTION public.get_account_ledger(
  p_account_id UUID,
  p_start_date TIMESTAMP WITH TIME ZONE,
  p_end_date TIMESTAMP WITH TIME ZONE,
  p_direction VARCHAR(20) DEFAULT NULL,
  p_payment_mode VARCHAR(50) DEFAULT NULL,
  p_transaction_type VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (
  transaction_date TIMESTAMP WITH TIME ZONE,
  description TEXT,
  payment_mode VARCHAR(50),
  cheque_number VARCHAR(100),
  received_amount DECIMAL(15,2),
  given_amount DECIMAL(15,2),
  running_balance DECIMAL(15,2)
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_opening_balance DECIMAL(15,2);
BEGIN
  -- Calculate opening balance BEFORE the start of the requested period
  -- (i.e., everything prior to p_start_date)
  SELECT public.calculate_account_balance(p_account_id, p_start_date - INTERVAL '1 microsecond') INTO v_opening_balance;

  RETURN QUERY
  WITH all_transactions AS (
    -- 1. Virtual Opening Balance Row (Brought Forward)
    SELECT
      p_start_date AS txn_date,
      'Opening Balance (Brought Forward)'::TEXT AS description,
      NULL::VARCHAR(50) AS payment_mode,
      NULL::VARCHAR(100) AS cheque_number,
      0::DECIMAL(15,2) AS received_amount,
      0::DECIMAL(15,2) AS given_amount,
      '00000000-0000-0000-0000-000000000000'::UUID AS txn_id,
      NULL::VARCHAR(20) AS direction,
      'OPENING'::VARCHAR(50) AS txn_type

    UNION ALL

    -- 2. Actual Transaction Rows
    SELECT
      ptr.transaction_date AS txn_date,
      CASE
        WHEN ptr.transaction_type = 'OPENING_BALANCE' THEN 'Initial Opening Balance'
        WHEN ptr.transaction_type = 'TRANSFER' AND ptr.direction = 'RECEIVED' THEN 'Transfer In'
        WHEN ptr.transaction_type = 'TRANSFER' AND ptr.direction = 'GIVEN' THEN 'Transfer Out'
        WHEN ptr.transaction_type = 'BALANCE_ADJUSTMENT' AND ptr.direction = 'RECEIVED' THEN 'Balance Adjustment (Add)'
        WHEN ptr.transaction_type = 'BALANCE_ADJUSTMENT' AND ptr.direction = 'GIVEN' THEN 'Balance Adjustment (Reduce)'
        WHEN ptr.transaction_type = 'EXPENSE' AND ptr.direction = 'GIVEN' THEN 'Expense Payment'
        WHEN ptr.transaction_type = 'SERVICE_ORDER' AND ptr.direction = 'RECEIVED' THEN 'Service Order Payment'
        WHEN ptr.transaction_type = 'PAYROLL' AND ptr.direction = 'GIVEN' THEN 'Salary Payment'
        WHEN ptr.transaction_type = 'PURCHASE_ORDER' AND ptr.direction = 'GIVEN' THEN 'PO Payment'
        WHEN ptr.transaction_type = 'INCOME' AND ptr.direction = 'RECEIVED' THEN 'Income'
        ELSE ptr.transaction_type || ' - ' || ptr.direction
      END AS description,
      ptd.payment_mode,
      ptd.cheque_number,
      CASE WHEN ptr.direction = 'RECEIVED' THEN ptd.amount ELSE 0 END AS received_amount,
      CASE WHEN ptr.direction = 'GIVEN' THEN ptd.amount ELSE 0 END AS given_amount,
      ptr.id AS txn_id,
      ptr.direction,
      ptr.transaction_type AS txn_type
    FROM public.payment_transaction_details ptd
    INNER JOIN public.payment_transactions_registry ptr ON ptr.id = ptd.payment_id
    WHERE ptd.bank_account_id = p_account_id
      AND ptr.status = 'completed'
      AND ptr.transaction_date BETWEEN p_start_date AND p_end_date
  ),
  computed_ledger AS (
    -- Calculate running balance on the FULL set for the date range
    -- We order by txn_date ASC and txn_id ASC to ensure stable running balance
    SELECT
      t.txn_date,
      t.description,
      t.payment_mode,
      t.cheque_number,
      t.received_amount,
      t.given_amount,
      (v_opening_balance + SUM(t.received_amount - t.given_amount) OVER (ORDER BY t.txn_date ASC, t.txn_id ASC)) AS balance,
      t.txn_id,
      t.direction,
      t.txn_type
    FROM all_transactions t
  )
  -- Finally, filter the results based on user selection
  SELECT
    c.txn_date,
    c.description,
    c.payment_mode,
    c.cheque_number,
    c.received_amount,
    c.given_amount,
    c.balance AS running_balance
  FROM computed_ledger c
  WHERE 
    c.txn_id = '00000000-0000-0000-0000-000000000000' -- Always keep opening balance row
    OR (
      (p_direction IS NULL OR c.direction = p_direction)
      AND (p_payment_mode IS NULL OR c.payment_mode = p_payment_mode)
      AND (p_transaction_type IS NULL OR c.txn_type = p_transaction_type)
    )
  ORDER BY c.txn_date ASC, c.txn_id ASC;
END;
$$;

-- 4. Update record_payment_v2 to accept TIMESTAMP WITH TIME ZONE
CREATE OR REPLACE FUNCTION public.record_payment_v2(
  p_source_type        VARCHAR,
  p_source_id          UUID,
  p_amount             DECIMAL(15,2),
  p_payment_method     VARCHAR,
  p_bank_account_id    UUID,
  p_reference_number   VARCHAR    DEFAULT NULL,
  p_notes              TEXT       DEFAULT NULL,
  p_metadata           JSONB      DEFAULT '{}'::JSONB,
  p_created_by         UUID       DEFAULT NULL,
  p_payment_date       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_registry_id     UUID;
  v_direction       VARCHAR(20);
  v_transaction_type VARCHAR(50);
  v_party_id        UUID;
  v_party_type      VARCHAR(50);
  v_remarks         TEXT;
  v_payment_mode    VARCHAR(50);
  v_account_balance DECIMAL(15,2);
  v_module_result   JSONB := '{}'::JSONB;

  -- Inherited variables...
  v_po_total DECIMAL(15,2); v_po_paid DECIMAL(15,2); v_po_new_paid DECIMAL(15,2); v_po_pay_status VARCHAR(20); v_po_payment_id UUID;
  v_exp_total DECIMAL(15,2); v_exp_paid DECIMAL(15,2); v_exp_new_paid DECIMAL(15,2); v_exp_status VARCHAR(20); v_exp_payment_id UUID;
  v_so_paid_amount DECIMAL(15,2); v_agent_payout_id UUID; v_so_commission DECIMAL(15,2); v_so_total_paid_commission DECIMAL(15,2);
  v_adv_txn_id UUID;
BEGIN
  -- Re-using the logic from the previous version but with TIMESTAMP support
  -- (Copying the logic carefully)
  
  -- STEP 0: Input validation
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Amount must be greater than zero');
  END IF;

  IF p_bank_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bank account is required');
  END IF;

  -- STEP 1: Determine direction, types, etc.
  v_transaction_type := UPPER(p_source_type);

  CASE UPPER(p_source_type)
    WHEN 'PURCHASE_ORDER' THEN
      v_direction := 'GIVEN';
      SELECT po.total_amount, COALESCE(po.advance_paid_amount, 0), po.supplier_id INTO v_po_total, v_po_paid, v_party_id FROM public.purchase_orders po WHERE po.id = p_source_id;
      IF v_po_total IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Purchase order not found'); END IF;
      SELECT v_po_paid + COALESCE(SUM(pt.amount), 0) INTO v_po_paid FROM public.payment_transactions pt WHERE pt.purchase_order_id = p_source_id AND pt.payment_status != 'cancelled';
      v_party_type := 'vendor'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'PO Payment');

    WHEN 'EXPENSE' THEN
      v_direction := 'GIVEN';
      SELECT e.total_amount, COALESCE(e.total_paid_amount, 0) INTO v_exp_total, v_exp_paid FROM public.expenses e WHERE e.id = p_source_id;
      IF v_exp_total IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Expense not found'); END IF;
      v_party_type := 'vendor'; v_party_id := (p_metadata->>'party_id')::UUID; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Expense Payment');

    WHEN 'SERVICE_ORDER' THEN
      v_direction := COALESCE(UPPER(p_metadata->>'direction'), 'RECEIVED');
      SELECT so.paid_amount, so.client_id INTO v_so_paid_amount, v_party_id FROM public.service_orders so WHERE so.id = p_source_id;
      IF v_so_paid_amount IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Service order not found'); END IF;
      v_party_type := 'client'; v_remarks := COALESCE(NULLIF(p_notes, ''), CASE WHEN v_direction = 'RECEIVED' THEN 'Service Order Payment' ELSE 'Service Order Expense' END);

    WHEN 'AGENT_PAYOUT' THEN
      v_direction := 'GIVEN'; v_party_id := (p_metadata->>'agent_id')::UUID; v_party_type := 'agent';
      IF NOT EXISTS (SELECT 1 FROM public.service_orders WHERE id = p_source_id) THEN RETURN jsonb_build_object('success', false, 'error', 'Service order not found'); END IF;
      v_remarks := COALESCE(NULLIF(p_notes, ''), 'Agent Commission Payout');

    WHEN 'ADVANCE_DISBURSEMENT' THEN
      v_direction := 'GIVEN'; SELECT ea.employee_id INTO v_party_id FROM public.employee_advances ea WHERE ea.id = p_source_id;
      IF v_party_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Employee advance not found'); END IF;
      v_party_type := 'employee'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Advance Disbursement');

    WHEN 'LOAN_DISBURSEMENT' THEN
      v_direction := 'GIVEN'; SELECT el.employee_id INTO v_party_id FROM public.employee_loans el WHERE el.id = p_source_id;
      IF v_party_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Employee loan not found'); END IF;
      v_party_type := 'employee'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Loan Disbursement');

    WHEN 'LOAN_REPAYMENT' THEN
      v_direction := 'RECEIVED'; SELECT el.employee_id INTO v_party_id FROM public.employee_loans el WHERE el.id = p_source_id;
      IF v_party_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Employee loan not found'); END IF;
      v_party_type := 'employee'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Loan Repayment');

    WHEN 'SECURITY_DEPOSIT' THEN
      v_direction := 'RECEIVED'; SELECT sd.employee_id INTO v_party_id FROM public.security_deposits sd WHERE sd.id = p_source_id;
      IF v_party_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Security deposit not found'); END IF;
      v_party_type := 'employee'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Security Deposit Collection');

    WHEN 'SECURITY_DEPOSIT_REFUND' THEN
      v_direction := 'GIVEN'; SELECT sd.employee_id INTO v_party_id FROM public.security_deposits sd WHERE sd.id = p_source_id;
      IF v_party_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Security deposit not found'); END IF;
      v_party_type := 'employee'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Security Deposit Refund');

    WHEN 'INCOME' THEN
      v_direction := 'RECEIVED'; v_party_id := (p_metadata->>'party_id')::UUID; v_party_type := COALESCE(p_metadata->>'party_type', 'client'); v_remarks := COALESCE(NULLIF(p_notes, ''), 'Income');

    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'Unknown source_type: ' || p_source_type);
  END CASE;

  -- STEP 2: Balance validation
  IF v_direction = 'GIVEN' THEN
    SELECT public.calculate_account_balance(p_bank_account_id) INTO v_account_balance;
    IF v_account_balance < p_amount THEN
      RETURN jsonb_build_object('success', false, 'error', 'Insufficient balance', 'current_balance', v_account_balance, 'required_amount', p_amount);
    END IF;
  END IF;

  -- STEP 3: Map payment method
  v_payment_mode := CASE LOWER(p_payment_method)
    WHEN 'cash' THEN 'cash' WHEN 'cheque' THEN 'cheque' WHEN 'check' THEN 'cheque' WHEN 'card' THEN 'card'
    WHEN 'upi' THEN 'upi' WHEN 'bank transfer' THEN 'bank_transfer' WHEN 'bank_transfer' THEN 'bank_transfer'
    WHEN 'neft' THEN 'bank_transfer' WHEN 'rtgs' THEN 'bank_transfer' WHEN 'imps' THEN 'bank_transfer'
    WHEN 'online' THEN 'online' ELSE 'bank_transfer'
  END;

  -- STEP 4: Create GL records
  INSERT INTO public.payment_transactions_registry (
    transaction_date, transaction_type, direction, total_amount, source_type, source_id, party_id, party_type, reference_number, remarks, status, created_by
  ) VALUES (
    p_payment_date, v_transaction_type, v_direction, p_amount, LOWER(p_source_type), p_source_id, v_party_id, v_party_type, p_reference_number, v_remarks, 'completed', p_created_by
  ) RETURNING id INTO v_registry_id;

  INSERT INTO public.payment_transaction_details (
    payment_id, bank_account_id, payment_mode, amount, cheque_number, cheque_date, cheque_bank_name, transaction_reference, remarks
  ) VALUES (
    v_registry_id, p_bank_account_id, v_payment_mode, p_amount, p_metadata->>'cheque_number', (p_metadata->>'cheque_date')::DATE, p_metadata->>'cheque_bank_name', p_reference_number, v_remarks
  );

  -- STEP 5: Module-specific hooks
  CASE UPPER(p_source_type)
    WHEN 'PURCHASE_ORDER' THEN
      v_po_new_paid := v_po_paid + p_amount;
      v_po_pay_status := CASE WHEN v_po_new_paid >= v_po_total THEN 'paid' WHEN v_po_new_paid > 0 THEN 'partial' ELSE 'unpaid' END;
      INSERT INTO public.payment_transactions (purchase_order_id, payment_date, amount, payment_method, payment_type, payment_status, notes, created_by)
      VALUES (p_source_id, p_payment_date::DATE, p_amount, p_payment_method, COALESCE(p_metadata->>'payment_type', 'partial'), 'completed', p_notes, p_created_by) RETURNING id INTO v_po_payment_id;
      UPDATE public.purchase_orders SET updated_at = NOW() WHERE id = p_source_id;
      v_module_result := jsonb_build_object('payment_status', v_po_pay_status, 'total_paid', v_po_new_paid, 'remaining_balance', GREATEST(0, v_po_total - v_po_new_paid), 'po_payment_id', v_po_payment_id);

    WHEN 'EXPENSE' THEN
      v_exp_new_paid := v_exp_paid + p_amount;
      v_exp_status := CASE WHEN v_exp_new_paid >= v_exp_total THEN 'paid' WHEN v_exp_new_paid > 0 THEN 'partially_paid' ELSE 'approved' END;
      INSERT INTO public.expense_payments (expense_id, payment_date, payment_amount, payment_method, payment_reference, notes, processed_by, bank_account_id)
      VALUES (p_source_id, p_payment_date::DATE, p_amount, p_payment_method, p_reference_number, p_notes, p_created_by, p_bank_account_id) RETURNING id INTO v_exp_payment_id;
      UPDATE public.expenses SET status = v_exp_status, total_paid_amount = v_exp_new_paid, remaining_amount = GREATEST(0, v_exp_total - v_exp_new_paid), updated_at = NOW() WHERE id = p_source_id;
      v_module_result := jsonb_build_object('expense_status', v_exp_status, 'total_paid', v_exp_new_paid, 'remaining_amount', GREATEST(0, v_exp_total - v_exp_new_paid), 'expense_payment_id', v_exp_payment_id);

    WHEN 'SERVICE_ORDER' THEN
      INSERT INTO public.payment_transactions_service_orders (service_order_id, transaction_type, amount, payment_method, bank_account_id, transaction_reference, notes, created_by, status)
      VALUES (p_source_id, CASE WHEN v_direction = 'RECEIVED' THEN 'Income' ELSE 'Expense' END, p_amount, p_payment_method, p_bank_account_id, p_reference_number, p_notes, p_created_by, 'completed');
      UPDATE public.service_orders SET paid_amount = COALESCE(paid_amount, 0) + (CASE WHEN v_direction = 'RECEIVED' THEN p_amount ELSE -p_amount END), updated_at = NOW() WHERE id = p_source_id;
      SELECT so.paid_amount INTO v_so_paid_amount FROM public.service_orders so WHERE so.id = p_source_id;
      v_module_result := jsonb_build_object('direction', v_direction, 'paid_amount', v_so_paid_amount);

    WHEN 'AGENT_PAYOUT' THEN
      INSERT INTO public.agent_payouts (agent_id, service_order_id, amount, payment_method, payment_date, transaction_reference, status, bank_account_id, created_by)
      VALUES (v_party_id, p_source_id, p_amount, p_payment_method, p_payment_date::DATE, p_reference_number, 'paid', p_bank_account_id, p_created_by) RETURNING id INTO v_agent_payout_id;
      SELECT so.agent_commission_amount INTO v_so_commission FROM public.service_orders so WHERE so.id = p_source_id;
      SELECT COALESCE(SUM(ap.amount), 0) INTO v_so_total_paid_commission FROM public.agent_payouts ap WHERE ap.service_order_id = p_source_id AND ap.status = 'paid';
      UPDATE public.service_orders SET agent_payout_status = CASE WHEN v_so_total_paid_commission >= COALESCE(v_so_commission, 0) THEN 'paid' WHEN v_so_total_paid_commission > 0 THEN 'partially_paid' ELSE 'due' END, updated_at = NOW() WHERE id = p_source_id;
      v_module_result := jsonb_build_object('agent_payout_id', v_agent_payout_id, 'total_paid_commission', v_so_total_paid_commission);

    WHEN 'ADVANCE_DISBURSEMENT' THEN
      INSERT INTO public.employee_advance_transactions (advance_id, transaction_type, amount, transaction_date, description, bank_account_id, created_by)
      VALUES (p_source_id, 'disbursement', p_amount, p_payment_date::DATE, v_remarks, p_bank_account_id, p_created_by) RETURNING id INTO v_adv_txn_id;
      UPDATE public.employee_advances SET bank_account_id = p_bank_account_id WHERE id = p_source_id;
      v_module_result := jsonb_build_object('advance_transaction_id', v_adv_txn_id);

    WHEN 'SECURITY_DEPOSIT_REFUND' THEN
      UPDATE public.security_deposits SET status = 'refunded', refund_date = p_payment_date::DATE, refund_amount = p_amount, interest_amount = COALESCE((p_metadata->>'interest_amount')::DECIMAL, 0), bank_account_id = p_bank_account_id, updated_at = NOW() WHERE id = p_source_id;
      INSERT INTO public.security_deposit_transactions (security_deposit_id, transaction_type, amount, transaction_date, description, bank_account_id)
      VALUES (p_source_id, 'refund', p_amount, p_payment_date::DATE, COALESCE(p_metadata->>'refund_description', 'Security deposit refund'), p_bank_account_id);
      v_module_result := jsonb_build_object('note', 'Security deposit refund processed');

    ELSE NULL;
  END CASE;

  RETURN jsonb_build_object('success', true, 'registry_id', v_registry_id, 'direction', v_direction, 'transaction_type', v_transaction_type, 'amount', p_amount) || v_module_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- 5. Update perform_account_transfer to accept TIMESTAMP WITH TIME ZONE
CREATE OR REPLACE FUNCTION public.perform_account_transfer(
  p_from_account_id UUID,
  p_to_account_id UUID,
  p_amount DECIMAL(15,2),
  p_transfer_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
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
  v_user_id := auth.uid();
  v_val := public.validate_transfer(p_from_account_id, p_to_account_id, p_amount);
  IF NOT (v_val->>'valid')::BOOLEAN THEN RETURN jsonb_build_object('success', false, 'error', v_val->>'error'); END IF;

  INSERT INTO public.payment_transactions_registry (transaction_date, transaction_type, direction, total_amount, status, remarks, created_by, source_type)
  VALUES (p_transfer_date, 'TRANSFER', 'GIVEN', p_amount, 'completed', COALESCE(p_remarks, 'Account Transfer (Out)'), v_user_id, 'transfer') RETURNING id INTO v_debit_id;

  INSERT INTO public.payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, remarks)
  VALUES (v_debit_id, p_from_account_id, 'bank_transfer', p_amount, p_remarks);

  INSERT INTO public.payment_transactions_registry (transaction_date, transaction_type, direction, total_amount, status, remarks, created_by, source_type)
  VALUES (p_transfer_date, 'TRANSFER', 'RECEIVED', p_amount, 'completed', COALESCE(p_remarks, 'Account Transfer (In)'), v_user_id, 'transfer') RETURNING id INTO v_credit_id;

  INSERT INTO public.payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, remarks)
  VALUES (v_credit_id, p_to_account_id, 'bank_transfer', p_amount, p_remarks);

  INSERT INTO public.account_transfers (from_account_id, to_account_id, amount, transfer_date, remarks, debit_transaction_id, credit_transaction_id, created_by)
  VALUES (p_from_account_id, p_to_account_id, p_amount, p_transfer_date, p_remarks, v_debit_id, v_credit_id, v_user_id) RETURNING id INTO v_transfer_id;

  UPDATE public.payment_transactions_registry SET source_id = v_transfer_id WHERE id IN (v_debit_id, v_credit_id);

  RETURN jsonb_build_object('success', true, 'transfer_id', v_transfer_id, 'debit_id', v_debit_id, 'credit_id', v_credit_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
