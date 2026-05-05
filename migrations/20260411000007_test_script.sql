-- -- Cash & Bank Module - Test Script (CORRECTED)
-- -- Migration: 20260411000007
-- -- Purpose: Verify all migrations are working correctly
-- -- Fixed: Replaced ON CONFLICT with WHERE NOT EXISTS to avoid deferrable constraint errors

-- -- ============================================
-- -- TEST 1: Verify Tables Created
-- -- ============================================
-- SELECT 'TEST 1: Verifying tables exist...' AS test;

-- SELECT table_name 
-- FROM information_schema.tables 
-- WHERE table_schema = 'public' 
--   AND table_name IN (
--     'bank_accounts', 
--     'payment_transactions_registry', 
--     'payment_transaction_details', 
--     'account_transfers'
--   )
-- ORDER BY table_name;

-- -- Expected: All 4 tables should be listed

-- -- ============================================
-- -- TEST 2: Verify Permissions Inserted
-- -- ============================================
-- SELECT 'TEST 2: Verifying permissions...' AS test;

-- SELECT name, module, can_view, can_add, can_edit, can_delete 
-- FROM public.permissions 
-- WHERE module IN ('cash_bank', 'bank_accounts', 'payments', 'transfers', 'balance_adjustments', 'reports_cash_bank')
-- ORDER BY module;

-- -- Expected: 6 permission records

-- -- ============================================
-- -- TEST 3: Verify RLS Enabled
-- -- ============================================
-- SELECT 'TEST 3: Verifying RLS enabled...' AS test;

-- SELECT tablename, rowsecurity 
-- FROM pg_tables 
-- WHERE schemaname = 'public' 
--   AND tablename IN (
--     'bank_accounts', 
--     'payment_transactions_registry', 
--     'payment_transaction_details', 
--     'account_transfers'
--   )
-- ORDER BY tablename;

-- -- Expected: All tables should have rowsecurity = true

-- -- ============================================
-- -- TEST 4: Create Test Bank Account
-- -- ============================================
-- SELECT 'TEST 4: Creating test bank account...' AS test;

-- INSERT INTO public.bank_accounts (
--   account_name,
--   account_type,
--   bank_name,
--   branch_name,
--   account_number,
--   ifsc_code,
--   opening_balance,
--   opening_date,
--   is_default,
--   is_active
-- )
-- SELECT 
--   'HDFC Current Account',
--   'current',
--   'HDFC Bank',
--   'Andheri West',
--   '50200012345678',
--   'HDFC0001234',
--   50000.00,
--   CURRENT_DATE,
--   true,
--   true
-- WHERE NOT EXISTS (
--   SELECT 1 FROM public.bank_accounts WHERE account_number = '50200012345678'
-- );

-- -- ============================================
-- -- TEST 5: Create Test Cash Account
-- -- ============================================
-- SELECT 'TEST 5: Creating test cash account...' AS test;

-- INSERT INTO public.bank_accounts (
--   account_name,
--   account_type,
--   opening_balance,
--   opening_date,
--   is_default,
--   is_active
-- )
-- SELECT 
--   'Cash In Hand',
--   'cash',
--   5000.00,
--   CURRENT_DATE,
--   false,
--   true
-- WHERE NOT EXISTS (
--   SELECT 1 FROM public.bank_accounts WHERE account_name = 'Cash In Hand' AND account_type = 'cash'
-- );

-- -- ============================================
-- -- TEST 6: Verify Accounts Created
-- -- ============================================
-- SELECT 'TEST 6: Verifying accounts...' AS test;

-- SELECT id, account_name, account_type, opening_balance, is_default, is_active
-- FROM public.bank_accounts
-- WHERE deleted_at IS NULL
-- ORDER BY is_default DESC, account_type;

-- -- Expected: 2 accounts (1 bank, 1 cash)

-- -- ============================================
-- -- TEST 7: Test Balance Calculation Function
-- -- ============================================
-- SELECT 'TEST 7: Testing balance calculation...' AS test;

-- SELECT 
--   account_name,
--   account_type,
--   opening_balance,
--   public.calculate_account_balance(id) AS current_balance
-- FROM public.bank_accounts
-- WHERE deleted_at IS NULL
-- ORDER BY account_name;

-- -- Expected: 
-- -- HDFC Current: 50000.00
-- -- Cash In Hand: 5000.00

-- -- ============================================
-- -- TEST 8: Create Test Payment
-- -- ============================================
-- SELECT 'TEST 8: Creating test payment...' AS test;

-- DO $$
-- DECLARE
--   v_hdfc_id UUID;
--   v_payment_id UUID;
-- BEGIN
--   SELECT id INTO v_hdfc_id 
--   FROM public.bank_accounts 
--   WHERE account_name = 'HDFC Current Account' AND deleted_at IS NULL LIMIT 1;

--   IF v_hdfc_id IS NULL THEN
--     RAISE NOTICE 'HDFC account not found, skipping payment test';
--     RETURN;
--   END IF;

--   -- Create payment record
--   INSERT INTO public.payment_transactions_registry (
--     transaction_date,
--     transaction_type,
--     direction,
--     total_amount,
--     source_type,
--     source_id,
--     reference_number,
--     remarks,
--     status
--   ) VALUES (
--     CURRENT_DATE,
--     'SERVICE_ORDER',
--     'RECEIVED',
--     15000.00,
--     'service_order',
--     NULL,
--     'SO-001',
--     'Client payment for legal services',
--     'completed'
--   ) RETURNING id INTO v_payment_id;

--   -- Create payment detail
--   INSERT INTO public.payment_transaction_details (
--     payment_id,
--     bank_account_id,
--     payment_mode,
--     amount,
--     transaction_reference
--   ) VALUES (
--     v_payment_id,
--     v_hdfc_id,
--     'upi',
--     15000.00,
--     'UPI-123456789'
--   );

--   RAISE NOTICE 'Payment created with ID: %', v_payment_id;
-- END $$;

-- -- ============================================
-- -- TEST 9: Verify Payment Balance Impact
-- -- ============================================
-- SELECT 'TEST 9: Verifying balance after payment...' AS test;

-- SELECT 
--   account_name,
--   account_type,
--   opening_balance,
--   public.calculate_account_balance(id) AS current_balance
-- FROM public.bank_accounts
-- WHERE deleted_at IS NULL
-- ORDER BY account_name;

-- -- Expected: 
-- -- HDFC Current: 65000.00 (50000 + 15000)
-- -- Cash In Hand: 5000.00

-- -- ============================================
-- -- TEST 10: Test Account Ledger Function
-- -- ============================================
-- SELECT 'TEST 10: Testing account ledger...' AS test;

-- DO $$
-- DECLARE
--   v_hdfc_id UUID;
--   v_rec RECORD;
-- BEGIN
--   SELECT id INTO v_hdfc_id 
--   FROM public.bank_accounts 
--   WHERE account_name = 'HDFC Current Account' AND deleted_at IS NULL LIMIT 1;

--   IF v_hdfc_id IS NULL THEN
--     RAISE NOTICE 'HDFC account not found, skipping ledger test';
--     RETURN;
--   END IF;

--   -- Get ledger for current month
--   FOR v_rec IN 
--     SELECT * FROM public.get_account_ledger(
--       v_hdfc_id,
--       DATE_TRUNC('month', CURRENT_DATE),
--       DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month - 1 day'
--     )
--   LOOP
--     RAISE NOTICE 'Date: %, Description: %, Received: %, Given: %, Balance: %',
--       v_rec.transaction_date,
--       v_rec.description,
--       v_rec.received_amount,
--       v_rec.given_amount,
--       v_rec.running_balance;
--   END LOOP;
-- END $$;

-- -- Expected: Should show the payment transaction with running balance

-- -- ============================================
-- -- TEST 11: Test Transfer Validation
-- -- ============================================
-- SELECT 'TEST 11: Testing transfer validation...' AS test;

-- DO $$
-- DECLARE
--   v_hdfc_id UUID;
--   v_cash_id UUID;
--   v_validation_result JSONB;
-- BEGIN
--   SELECT id INTO v_hdfc_id 
--   FROM public.bank_accounts 
--   WHERE account_name = 'HDFC Current Account' AND deleted_at IS NULL LIMIT 1;

--   SELECT id INTO v_cash_id 
--   FROM public.bank_accounts 
--   WHERE account_name = 'Cash In Hand' AND deleted_at IS NULL LIMIT 1;

--   IF v_hdfc_id IS NULL OR v_cash_id IS NULL THEN
--     RAISE NOTICE 'Accounts not found, skipping transfer test';
--     RETURN;
--   END IF;

--   -- Test valid transfer
--   SELECT public.validate_transfer(v_hdfc_id, v_cash_id, 10000.00) INTO v_validation_result;
--   RAISE NOTICE 'Valid transfer test: %', v_validation_result;

--   -- Test invalid transfer (insufficient balance)
--   SELECT public.validate_transfer(v_cash_id, v_hdfc_id, 100000.00) INTO v_validation_result;
--   RAISE NOTICE 'Invalid transfer test (insufficient balance): %', v_validation_result;

--   -- Test same account transfer
--   SELECT public.validate_transfer(v_hdfc_id, v_hdfc_id, 1000.00) INTO v_validation_result;
--   RAISE NOTICE 'Invalid transfer test (same account): %', v_validation_result;
-- END $$;

-- -- Expected:
-- -- Valid transfer: {"valid": true, "current_balance": 65000, "balance_after_transfer": 55000}
-- -- Insufficient balance: {"valid": false, "error": "Insufficient balance", ...}
-- -- Same account: {"valid": false, "error": "Source and destination accounts cannot be the same"}

-- -- ============================================
-- -- TEST 12: Test All Account Balances Function
-- -- ============================================
-- SELECT 'TEST 12: Testing get_all_account_balances...' AS test;

-- SELECT * FROM public.get_all_account_balances();

-- -- Expected: Both accounts with their current balances

-- -- ============================================
-- -- TEST 13: Verify Indexes Created
-- -- ============================================
-- SELECT 'TEST 13: Verifying indexes...' AS test;

-- SELECT 
--   tablename,
--   indexname
-- FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND tablename IN (
--     'bank_accounts',
--     'payment_transactions_registry',
--     'payment_transaction_details',
--     'account_transfers'
--   )
-- ORDER BY tablename, indexname;

-- -- Expected: Multiple indexes for each table

-- -- ============================================
-- -- TEST 14: Verify Triggers Created
-- -- ============================================
-- SELECT 'TEST 14: Verifying triggers...' AS test;

-- SELECT 
--   trigger_name,
--   event_manipulation,
--   event_object_table,
--   action_statement
-- FROM information_schema.triggers
-- WHERE trigger_schema = 'public'
--   AND event_object_table IN (
--     'bank_accounts',
--     'payment_transactions_registry'
--   )
-- ORDER BY event_object_table, trigger_name;

-- -- Expected: 2 triggers (updated_at for bank_accounts and payment_transactions_registry)

-- -- ============================================
-- -- CLEANUP (Optional - uncomment to clean test data)
-- -- ============================================
-- -- SELECT 'CLEANUP: Removing test data...' AS test;
-- -- 
-- -- DELETE FROM public.payment_transaction_details WHERE payment_id IN (
-- --   SELECT id FROM public.payment_transactions_registry WHERE reference_number = 'SO-001'
-- -- );
-- -- DELETE FROM public.payment_transactions_registry WHERE reference_number = 'SO-001';
-- -- DELETE FROM public.bank_accounts WHERE account_name IN ('HDFC Current Account', 'Cash In Hand');
-- -- 
-- -- SELECT 'CLEANUP: Test data removed.' AS test;

-- -- ============================================
-- -- FINAL SUMMARY
-- -- ============================================
-- SELECT '========================================' AS summary;
-- SELECT 'ALL TESTS COMPLETED SUCCESSFULLY!' AS summary;
-- SELECT '========================================' AS summary;
-- SELECT '' AS summary;
-- SELECT 'Next Steps:' AS summary;
-- SELECT '1. Verify all test results above' AS summary;
-- SELECT '2. Check for any errors or NULL values' AS summary;
-- SELECT '3. Run cleanup if needed' AS summary;
-- SELECT '4. Proceed to frontend development' AS summary;
