-- Migration: 20260421000002
-- Purpose: Keep payment dialogs operational when Cash & Bank is disabled,
--          while skipping cash/bank ledger entries centrally.

-- Drop both potential signatures to avoid overloading conflicts
DROP FUNCTION IF EXISTS public.record_payment_v2(VARCHAR, UUID, DECIMAL, VARCHAR, UUID, VARCHAR, TEXT, JSONB, UUID, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.record_payment_v2(VARCHAR, UUID, DECIMAL, VARCHAR, UUID, VARCHAR, TEXT, JSONB, UUID, TIMESTAMP WITH TIME ZONE) CASCADE;

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
  v_registry_id      UUID;
  v_direction        VARCHAR(20);
  v_transaction_type VARCHAR(50);
  v_party_id         UUID;
  v_party_type       VARCHAR(50);
  v_remarks          TEXT;
  v_payment_mode     VARCHAR(50);
  v_account_balance  DECIMAL(15,2);
  v_module_result    JSONB := '{}'::JSONB;
  v_cash_bank_enabled BOOLEAN := FALSE;

  v_po_total DECIMAL(15,2); v_po_paid DECIMAL(15,2); v_po_new_paid DECIMAL(15,2); v_po_pay_status VARCHAR(20); v_po_payment_id UUID;
  v_exp_total DECIMAL(15,2); v_exp_paid DECIMAL(15,2); v_exp_new_paid DECIMAL(15,2); v_exp_status VARCHAR(20); v_exp_payment_id UUID;
  v_so_paid_amount DECIMAL(15,2); v_agent_payout_id UUID; v_so_commission DECIMAL(15,2); v_so_total_paid_commission DECIMAL(15,2);
  v_adv_txn_id UUID;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Amount must be greater than zero');
  END IF;

  SELECT COALESCE(cs.cash_bank_enabled, FALSE)
  INTO v_cash_bank_enabled
  FROM public.company_settings cs
  ORDER BY cs.updated_at DESC NULLS LAST, cs.created_at DESC NULLS LAST
  LIMIT 1;

  IF v_cash_bank_enabled AND p_bank_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bank account is required');
  END IF;

  v_transaction_type := UPPER(p_source_type);

  CASE UPPER(p_source_type)
    WHEN 'PURCHASE_ORDER' THEN
      v_direction := 'GIVEN';
      SELECT po.total_amount, COALESCE(po.advance_paid_amount, 0), po.supplier_id INTO v_po_total, v_po_paid, v_party_id
      FROM public.purchase_orders po
      WHERE po.id = p_source_id;
      IF v_po_total IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Purchase order not found'); END IF;
      SELECT v_po_paid + COALESCE(SUM(pt.amount), 0) INTO v_po_paid
      FROM public.payment_transactions pt
      WHERE pt.purchase_order_id = p_source_id AND pt.payment_status != 'cancelled';
      v_party_type := 'vendor'; v_remarks := COALESCE(NULLIF(p_notes, ''), 'PO Payment');

    WHEN 'EXPENSE' THEN
      v_direction := 'GIVEN';
      SELECT e.total_amount, COALESCE(e.total_paid_amount, 0) INTO v_exp_total, v_exp_paid
      FROM public.expenses e
      WHERE e.id = p_source_id;
      IF v_exp_total IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Expense not found'); END IF;
      v_party_type := 'vendor'; v_party_id := (p_metadata->>'party_id')::UUID; v_remarks := COALESCE(NULLIF(p_notes, ''), 'Expense Payment');

    WHEN 'SERVICE_ORDER' THEN
      v_direction := COALESCE(UPPER(p_metadata->>'direction'), 'RECEIVED');
      SELECT so.paid_amount, so.client_id INTO v_so_paid_amount, v_party_id
      FROM public.service_orders so
      WHERE so.id = p_source_id;
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

  IF v_cash_bank_enabled AND v_direction = 'GIVEN' THEN
    SELECT public.calculate_account_balance(p_bank_account_id) INTO v_account_balance;
    IF v_account_balance < p_amount THEN
      RETURN jsonb_build_object('success', false, 'error', 'Insufficient balance', 'current_balance', v_account_balance, 'required_amount', p_amount);
    END IF;
  END IF;

  v_payment_mode := CASE LOWER(p_payment_method)
    WHEN 'cash' THEN 'cash' WHEN 'cheque' THEN 'cheque' WHEN 'check' THEN 'cheque' WHEN 'card' THEN 'card'
    WHEN 'upi' THEN 'upi' WHEN 'bank transfer' THEN 'bank_transfer' WHEN 'bank_transfer' THEN 'bank_transfer'
    WHEN 'neft' THEN 'bank_transfer' WHEN 'rtgs' THEN 'bank_transfer' WHEN 'imps' THEN 'bank_transfer'
    WHEN 'online' THEN 'online' ELSE 'bank_transfer'
  END;

  IF v_cash_bank_enabled THEN
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
  END IF;

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
      VALUES (p_source_id, p_payment_date::DATE, p_amount, p_payment_method, p_reference_number, p_notes, p_created_by, CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END) RETURNING id INTO v_exp_payment_id;
      UPDATE public.expenses SET status = v_exp_status, total_paid_amount = v_exp_new_paid, remaining_amount = GREATEST(0, v_exp_total - v_exp_new_paid), updated_at = NOW() WHERE id = p_source_id;
      v_module_result := jsonb_build_object('expense_status', v_exp_status, 'total_paid', v_exp_new_paid, 'remaining_amount', GREATEST(0, v_exp_total - v_exp_new_paid), 'expense_payment_id', v_exp_payment_id);

    WHEN 'SERVICE_ORDER' THEN
      INSERT INTO public.payment_transactions_service_orders (
        service_order_id, transaction_type, amount, payment_method, bank_account_id, 
        transaction_reference, notes, created_by, status, payment_date,
        registry_id, income_expense_name, expense_name
      ) VALUES (
        p_source_id,
        CASE WHEN v_direction = 'RECEIVED' THEN 'Income' ELSE 'Expense' END,
        p_amount,
        p_payment_method,
        CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END,
        p_reference_number,
        p_notes,
        p_created_by,
        'completed',
        p_payment_date::DATE,
        v_registry_id,
        CASE WHEN v_direction = 'RECEIVED' THEN p_metadata->>'item_type' ELSE NULL END,
        CASE WHEN v_direction = 'GIVEN' THEN p_metadata->>'item_type' ELSE NULL END
      );

      UPDATE public.service_orders SET paid_amount = COALESCE(paid_amount, 0) + (CASE WHEN v_direction = 'RECEIVED' THEN p_amount ELSE -p_amount END), updated_at = NOW() WHERE id = p_source_id;
      SELECT so.paid_amount INTO v_so_paid_amount FROM public.service_orders so WHERE so.id = p_source_id;
      v_module_result := jsonb_build_object('direction', v_direction, 'paid_amount', v_so_paid_amount);

    WHEN 'AGENT_PAYOUT' THEN
      INSERT INTO public.agent_payouts (agent_id, service_order_id, amount, payment_method, payment_date, transaction_reference, status, bank_account_id, created_by)
      VALUES (v_party_id, p_source_id, p_amount, p_payment_method, p_payment_date::DATE, p_reference_number, 'paid', CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END, p_created_by) RETURNING id INTO v_agent_payout_id;
      SELECT so.agent_commission_amount INTO v_so_commission FROM public.service_orders so WHERE so.id = p_source_id;
      SELECT COALESCE(SUM(ap.amount), 0) INTO v_so_total_paid_commission FROM public.agent_payouts ap WHERE ap.service_order_id = p_source_id AND ap.status = 'paid';
      UPDATE public.service_orders SET agent_payout_status = CASE WHEN v_so_total_paid_commission >= COALESCE(v_so_commission, 0) THEN 'paid' WHEN v_so_total_paid_commission > 0 THEN 'partially_paid' ELSE 'due' END, updated_at = NOW() WHERE id = p_source_id;
      v_module_result := jsonb_build_object('agent_payout_id', v_agent_payout_id, 'total_paid_commission', v_so_total_paid_commission);

    WHEN 'ADVANCE_DISBURSEMENT' THEN
      INSERT INTO public.employee_advance_transactions (advance_id, transaction_type, amount, transaction_date, description, bank_account_id, created_by)
      VALUES (p_source_id, 'disbursement', p_amount, p_payment_date::DATE, v_remarks, CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END, p_created_by) RETURNING id INTO v_adv_txn_id;
      UPDATE public.employee_advances SET bank_account_id = CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END WHERE id = p_source_id;
      v_module_result := jsonb_build_object('advance_transaction_id', v_adv_txn_id);

    WHEN 'LOAN_DISBURSEMENT' THEN
      NULL;

    WHEN 'LOAN_REPAYMENT' THEN
      NULL;

    WHEN 'SECURITY_DEPOSIT' THEN
      NULL;

    WHEN 'SECURITY_DEPOSIT_REFUND' THEN
      UPDATE public.security_deposits SET status = 'refunded', refund_date = p_payment_date::DATE, refund_amount = p_amount, interest_amount = COALESCE((p_metadata->>'interest_amount')::DECIMAL, 0), bank_account_id = CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END, updated_at = NOW() WHERE id = p_source_id;
      INSERT INTO public.security_deposit_transactions (security_deposit_id, transaction_type, amount, transaction_date, description, bank_account_id)
      VALUES (p_source_id, 'refund', p_amount, p_payment_date::DATE, COALESCE(p_metadata->>'refund_description', 'Security deposit refund'), CASE WHEN v_cash_bank_enabled THEN p_bank_account_id ELSE NULL END);
      v_module_result := jsonb_build_object('note', 'Security deposit refund processed');

    WHEN 'INCOME' THEN
      v_module_result := jsonb_build_object('note', 'Income recorded in registry');

    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'Unknown source_type: ' || p_source_type);
  END CASE;

  RETURN jsonb_build_object('success', true, 'registry_id', v_registry_id, 'direction', v_direction, 'transaction_type', v_transaction_type, 'amount', p_amount, 'cash_bank_enabled', v_cash_bank_enabled) || v_module_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

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
  v_cash_bank_enabled BOOLEAN := FALSE;
BEGIN
  SELECT status, total_amount, COALESCE(advance_paid_amount, 0)
  INTO v_po_status, v_po_total, v_advance_paid
  FROM public.purchase_orders
  WHERE id = p_po_id;

  IF v_po_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Purchase order not found');
  END IF;

  SELECT COALESCE(cs.cash_bank_enabled, FALSE)
  INTO v_cash_bank_enabled
  FROM public.company_settings cs
  ORDER BY cs.updated_at DESC NULLS LAST, cs.created_at DESC NULLS LAST
  LIMIT 1;

  v_new_paid_amount := v_advance_paid + p_amount;

  IF v_new_paid_amount >= v_po_total THEN
    v_payment_status := 'paid';
  ELSIF v_new_paid_amount > 0 THEN
    v_payment_status := 'partial';
  ELSE
    v_payment_status := 'unpaid';
  END IF;

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

  IF v_cash_bank_enabled AND p_bank_account_id IS NOT NULL THEN
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
    ) RETURNING id INTO v_registry_id;

    INSERT INTO public.payment_transaction_details (
      payment_id,
      bank_account_id,
      payment_mode,
      amount,
      transaction_reference,
      remarks
    ) VALUES (
      v_registry_id,
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

  UPDATE public.purchase_orders
  SET total_paid_amount = v_new_paid_amount,
      remaining_balance = GREATEST(0, v_po_total - v_new_paid_amount),
      payment_status = v_payment_status,
      updated_at = NOW()
  WHERE id = p_po_id;

  RETURN jsonb_build_object(
    'success', true,
    'payment_id', v_payment_id,
    'registry_id', v_registry_id,
    'payment_status', v_payment_status,
    'total_paid', v_new_paid_amount,
    'remaining_balance', GREATEST(0, v_po_total - v_new_paid_amount),
    'cash_bank_enabled', v_cash_bank_enabled
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
