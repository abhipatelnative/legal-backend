-- -- Cash & Bank Module - Seed Test Transactions
-- -- Migration: 20260411000013
-- -- Purpose: Add sample transactions for 3-4 months across multiple accounts

-- DO $$
-- DECLARE
--   -- Account IDs
--   v_kotak_id UUID;
--   v_sbi_id UUID;
--   v_hdfc_id UUID;
--   v_cash_id UUID;
--   v_petty_cash_id UUID;
--   v_test_user UUID;
  
--   -- Transaction IDs
--   v_txn_id UUID;
-- BEGIN
--   -- Get test user
--   SELECT id INTO v_test_user FROM auth.users LIMIT 1;
--   IF v_test_user IS NULL THEN
--     v_test_user := '00000000-0000-0000-0000-000000000000';
--   END IF;

--   -- Get or create bank accounts
--   SELECT id INTO v_kotak_id FROM bank_accounts WHERE account_name = 'Kotak Mahindra Bank' LIMIT 1;
--   IF v_kotak_id IS NULL THEN
--     INSERT INTO bank_accounts (account_name, account_type, opening_balance, is_active, is_default)
--     VALUES ('Kotak Mahindra Bank', 'current', 150000.00, true, true)
--     RETURNING id INTO v_kotak_id;
--   END IF;

--   SELECT id INTO v_sbi_id FROM bank_accounts WHERE account_name = 'State Bank of India' LIMIT 1;
--   IF v_sbi_id IS NULL THEN
--     INSERT INTO bank_accounts (account_name, account_type, opening_balance, is_active)
--     VALUES ('State Bank of India', 'savings', 200000.00, true)
--     RETURNING id INTO v_sbi_id;
--   END IF;

--   SELECT id INTO v_hdfc_id FROM bank_accounts WHERE account_name = 'HDFC Bank' LIMIT 1;
--   IF v_hdfc_id IS NULL THEN
--     INSERT INTO bank_accounts (account_name, account_type, opening_balance, is_active)
--     VALUES ('HDFC Bank', 'current', 300000.00, true)
--     RETURNING id INTO v_hdfc_id;
--   END IF;

--   SELECT id INTO v_cash_id FROM bank_accounts WHERE account_name = 'Main Cash' AND account_type = 'cash' LIMIT 1;
--   IF v_cash_id IS NULL THEN
--     INSERT INTO bank_accounts (account_name, account_type, opening_balance, is_active)
--     VALUES ('Main Cash', 'cash', 50000.00, true)
--     RETURNING id INTO v_cash_id;
--   END IF;

--   SELECT id INTO v_petty_cash_id FROM bank_accounts WHERE account_name = 'Petty Cash' LIMIT 1;
--   IF v_petty_cash_id IS NULL THEN
--     INSERT INTO bank_accounts (account_name, account_type, opening_balance, is_active)
--     VALUES ('Petty Cash', 'petty_cash', 10000.00, true)
--     RETURNING id INTO v_petty_cash_id;
--   END IF;

--   -- ============================================
--   -- JANUARY 2026 TRANSACTIONS
--   -- ============================================

--   -- Jan 5: Client payment received (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-01-05', 'SERVICE_ORDER', 'RECEIVED', 75000.00, 'INV-2026-001', 'Client payment - Legal consultation', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 75000.00, 'TXN20260105001');

--   -- Jan 8: Office rent paid (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-01-08', 'EXPENSE', 'GIVEN', 35000.00, 'RENT-JAN-2026', 'Office rent - January 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 35000.00, 'RENT20260108001');

--   -- Jan 12: Salary payment (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-01-12', 'PAYROLL', 'GIVEN', 120000.00, 'PAYROLL-JAN-2026', 'Employee salaries - January 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 120000.00, 'SAL20260112001');

--   -- Jan 15: Cash received from daily sales (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-01-15', 'SERVICE_ORDER', 'RECEIVED', 25000.00, 'SALES-JAN-2026', 'Daily sales deposit', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_cash_id, 'cash', 15000.00, NULL);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'upi', 10000.00, 'UPI20260115001');

--   -- Jan 20: Stationery purchase (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-01-20', 'PURCHASE_ORDER', 'GIVEN', 5000.00, 'PO-2026-001', 'Office stationery and supplies', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_petty_cash_id, 'cash', 5000.00, NULL);

--   -- Jan 25: Client advance payment (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-01-25', 'SERVICE_ORDER', 'RECEIVED', 150000.00, 'ADV-2026-001', 'Advance payment for litigation case', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_sbi_id, 'cheque', 150000.00, 'CHQ20260125001');

--   -- ============================================
--   -- FEBRUARY 2026 TRANSACTIONS
--   -- ============================================

--   -- Feb 2: Professional fee received (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-02-02', 'SERVICE_ORDER', 'RECEIVED', 95000.00, 'INV-2026-002', 'Professional fee - Contract drafting', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 60000.00, 'TXN20260202001');
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'upi', 35000.00, 'UPI20260202001');

--   -- Feb 5: Internet and utilities (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-02-05', 'EXPENSE', 'GIVEN', 8500.00, 'UTIL-FEB-2026', 'Internet and electricity bill', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_hdfc_id, 'card', 8500.00, 'CARD20260205001');

--   -- Feb 10: Office rent paid (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-02-10', 'EXPENSE', 'GIVEN', 35000.00, 'RENT-FEB-2026', 'Office rent - February 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 35000.00, 'RENT20260210001');

--   -- Feb 12: Salary payment (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-02-12', 'PAYROLL', 'GIVEN', 125000.00, 'PAYROLL-FEB-2026', 'Employee salaries - February 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 125000.00, 'SAL20260212001');

--   -- Feb 18: Consultation fee received (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-02-18', 'SERVICE_ORDER', 'RECEIVED', 45000.00, 'INV-2026-003', 'Legal consultation fee', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_hdfc_id, 'upi', 45000.00, 'UPI20260218001');

--   -- Feb 22: Travel expense (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-02-22', 'EXPENSE', 'GIVEN', 12000.00, 'TRAVEL-FEB-2026', 'Court visit travel expense', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_cash_id, 'cash', 12000.00, NULL);

--   -- ============================================
--   -- MARCH 2026 TRANSACTIONS
--   -- ============================================

--   -- Mar 1: Client payment received (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-01', 'SERVICE_ORDER', 'RECEIVED', 180000.00, 'INV-2026-004', 'Large corporate client payment', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_sbi_id, 'bank_transfer', 180000.00, 'TXN20260301001');

--   -- Mar 5: Office rent paid (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-05', 'EXPENSE', 'GIVEN', 35000.00, 'RENT-MAR-2026', 'Office rent - March 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 35000.00, 'RENT20260305001');

--   -- Mar 8: Legal books purchase (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-08', 'PURCHASE_ORDER', 'GIVEN', 15000.00, 'PO-2026-002', 'Legal reference books', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_hdfc_id, 'card', 15000.00, 'CARD20260308001');

--   -- Mar 12: Salary payment (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-12', 'PAYROLL', 'GIVEN', 128000.00, 'PAYROLL-MAR-2026', 'Employee salaries - March 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 128000.00, 'SAL20260312001');

--   -- Mar 15: Cash deposit to bank (RECEIVED in bank from cash)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-15', 'TRANSFER', 'RECEIVED', 30000.00, 'DEP-2026-001', 'Cash deposit to Kotak account', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'cash', 30000.00, NULL);

--   -- Mar 20: Court fee paid (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-20', 'EXPENSE', 'GIVEN', 25000.00, 'COURT-FEE-2026', 'Court filing fees', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'upi', 25000.00, 'UPI20260320001');

--   -- Mar 25: Client consultation (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-03-25', 'SERVICE_ORDER', 'RECEIVED', 65000.00, 'INV-2026-005', 'Corporate advisory fee', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_hdfc_id, 'bank_transfer', 65000.00, 'TXN20260325001');

--   -- ============================================
--   -- APRIL 2026 TRANSACTIONS (Partial - current month)
--   -- ============================================

--   -- Apr 2: Client payment received (RECEIVED)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-04-02', 'SERVICE_ORDER', 'RECEIVED', 55000.00, 'INV-2026-006', 'Trademark registration fee', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'upi', 55000.00, 'UPI20260402001');

--   -- Apr 5: Office rent paid (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-04-05', 'EXPENSE', 'GIVEN', 35000.00, 'RENT-APR-2026', 'Office rent - April 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 35000.00, 'RENT20260405001');

--   -- Apr 8: Printer maintenance (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-04-08', 'EXPENSE', 'GIVEN', 7500.00, 'MAINT-APR-2026', 'Printer maintenance and toner', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_petty_cash_id, 'cash', 7500.00, NULL);

--   -- Apr 12: Salary payment (GIVEN)
--   v_txn_id := gen_random_uuid();
--   INSERT INTO payment_transactions_registry (id, transaction_date, transaction_type, direction, total_amount, reference_number, remarks, status, created_by)
--   VALUES (v_txn_id, '2026-04-12', 'PAYROLL', 'GIVEN', 130000.00, 'PAYROLL-APR-2026', 'Employee salaries - April 2026', 'completed', v_test_user);
--   INSERT INTO payment_transaction_details (payment_id, bank_account_id, payment_mode, amount, transaction_reference)
--   VALUES (v_txn_id, v_kotak_id, 'bank_transfer', 130000.00, 'SAL20260412001');

--   -- ============================================
--   -- DISPLAY SUMMARY
--   -- ============================================
--   RAISE NOTICE '✅ Seed transactions created successfully!';
--   RAISE NOTICE 'Accounts created/found:';
--   RAISE NOTICE '  - Kotak Mahindra Bank: %', v_kotak_id;
--   RAISE NOTICE '  - State Bank of India: %', v_sbi_id;
--   RAISE NOTICE '  - HDFC Bank: %', v_hdfc_id;
--   RAISE NOTICE '  - Main Cash: %', v_cash_id;
--   RAISE NOTICE '  - Petty Cash: %', v_petty_cash_id;
--   RAISE NOTICE '';
--   RAISE NOTICE 'Transactions summary by account:';
--   RAISE NOTICE '  Kotak Bank:';
--   RAISE NOTICE '    Received: ₹%', (SELECT COALESCE(SUM(amount), 0) FROM payment_transaction_details WHERE bank_account_id = v_kotak_id AND payment_id IN (SELECT id FROM payment_transactions_registry WHERE direction = 'RECEIVED'))::TEXT;
--   RAISE NOTICE '    Given: ₹%', (SELECT COALESCE(SUM(amount), 0) FROM payment_transaction_details WHERE bank_account_id = v_kotak_id AND payment_id IN (SELECT id FROM payment_transactions_registry WHERE direction = 'GIVEN'))::TEXT;
--   RAISE NOTICE '  SBI:';
--   RAISE NOTICE '    Received: ₹%', (SELECT COALESCE(SUM(amount), 0) FROM payment_transaction_details WHERE bank_account_id = v_sbi_id AND payment_id IN (SELECT id FROM payment_transactions_registry WHERE direction = 'RECEIVED'))::TEXT;
--   RAISE NOTICE '    Given: ₹%', (SELECT COALESCE(SUM(amount), 0) FROM payment_transaction_details WHERE bank_account_id = v_sbi_id AND payment_id IN (SELECT id FROM payment_transactions_registry WHERE direction = 'GIVEN'))::TEXT;

-- END $$;
