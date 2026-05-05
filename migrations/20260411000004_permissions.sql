-- Cash & Bank Module - Permissions Setup
-- Migration: 20260411000004
-- Purpose: Insert permissions for cash & bank module

-- Insert permissions for cash & bank module
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description, created_at, updated_at)
VALUES
  ('Cash & Bank Dashboard', 'cash_bank', true, false, false, false, 'Access to cash & bank dashboard', NOW(), NOW()),
  ('Bank Accounts Management', 'bank_accounts', true, true, true, true, 'Full access to bank accounts management', NOW(), NOW()),
  ('Payments Management', 'payments', true, true, true, true, 'Full access to payment recording and management', NOW(), NOW()),
  ('Transfers Management', 'transfers', true, true, true, true, 'Full access to inter-account transfers', NOW(), NOW()),
  ('Balance Adjustments', 'balance_adjustments', true, true, true, true, 'Add or reduce money from accounts', NOW(), NOW()),
  ('Cash & Bank Reports', 'reports_cash_bank', true, true, false, false, 'Access to cash & bank reports', NOW(), NOW())
ON CONFLICT (name) DO NOTHING;
