-- Cash & Bank Module - Sidebar Navigation Fix
-- Migration: 20260411000009
-- Purpose: Restructure Cash & Bank sidebar:
--   - Remove Dashboard/Accounts/Payments/Reports modules (collapse into standalone pages)
--   - Rename Dashboard → Overview
--   - Accounts & Payments become standalone pages (no module wrapper)
--   - Move report pages into the existing Reports module (under OPERATIONS & REPORTS)

-- ============================================
-- STEP 1: Delete old pages created by previous migration
-- ============================================
DELETE FROM public.app_pages WHERE url IN (
  '/cash-and-bank/dashboard',
  '/cash-and-bank/accounts',
  '/cash-and-bank/accounts/add',
  '/cash-and-bank/accounts/edit/:id',
  '/cash-and-bank/accounts/:id',
  '/cash-and-bank/payments',
  '/cash-and-bank/payments/:id',
  '/cash-and-bank/reports/bank-book',
  '/cash-and-bank/reports/cash-book',
  '/cash-and-bank/reports/account-summary',
  '/cash-and-bank/reports/payment-register'
);

-- ============================================
-- STEP 2: Delete old modules created by previous migration
-- ============================================
DELETE FROM public.app_modules WHERE slug IN (
  'cash-bank-dashboard',
  'cash-bank-accounts',
  'cash-bank-payments',
  'cash-bank-reports'
);

-- ============================================
-- STEP 3: Insert new standalone pages + report pages
-- ============================================
DO $$
DECLARE
  v_group_id UUID;
  v_reports_module_id UUID;
  v_cash_bank_permission_id UUID;
  v_bank_accounts_permission_id UUID;
  v_payments_permission_id UUID;
  v_reports_permission_id UUID;
  v_base_order INT;
BEGIN
  -- Get Cash & Bank module group ID
  SELECT id INTO v_group_id FROM public.app_module_groups WHERE slug = 'cash-and-bank';

  -- Get the existing Reports module ID (under OPERATIONS & REPORTS section)
  SELECT id INTO v_reports_module_id FROM public.app_modules WHERE slug = 'reports';

  -- Get permission IDs
  SELECT id INTO v_cash_bank_permission_id FROM public.permissions WHERE name = 'Cash & Bank Dashboard';
  SELECT id INTO v_bank_accounts_permission_id FROM public.permissions WHERE name = 'Bank Accounts Management';
  SELECT id INTO v_payments_permission_id FROM public.permissions WHERE name = 'Payments Management';
  SELECT id INTO v_reports_permission_id FROM public.permissions WHERE name = 'Cash & Bank Reports';

  -- Get next available display order for pages
  SELECT COALESCE(max(display_order), 0) INTO v_base_order FROM public.app_pages;

  -- ============================================
  -- Cash & Bank — Standalone Pages (no module wrapper)
  -- ============================================

  -- Overview page (replaces Dashboard)
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Overview', '/cash-and-bank/overview', NULL, v_group_id, 'cash_bank', 'layout-dashboard', 'text-blue-500', v_cash_bank_permission_id, v_base_order + 1, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/overview');

  -- Accounts page (standalone — CRUD happens on this single page)
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Accounts', '/cash-and-bank/accounts', NULL, v_group_id, 'bank_accounts', 'building-2', 'text-indigo-500', v_bank_accounts_permission_id, v_base_order + 2, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/accounts');

  -- Payments page (standalone — CRUD happens on this single page)
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Payments', '/cash-and-bank/payments', NULL, v_group_id, 'payments', 'receipt', 'text-green-500', v_payments_permission_id, v_base_order + 3, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/payments');

  -- ============================================
  -- Report Pages — Added to existing Reports module
  -- ============================================
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Bank Book', '/cash-and-bank/reports/bank-book', v_reports_module_id, NULL, 'reports_cash_bank', 'book-open', 'text-purple-500', v_reports_permission_id, v_base_order + 4, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/bank-book');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Cash Book', '/cash-and-bank/reports/cash-book', v_reports_module_id, NULL, 'reports_cash_bank', 'book-open', 'text-purple-500', v_reports_permission_id, v_base_order + 5, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/cash-book');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Account Summary', '/cash-and-bank/reports/account-summary', v_reports_module_id, NULL, 'reports_cash_bank', 'pie-chart', 'text-purple-500', v_reports_permission_id, v_base_order + 6, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/account-summary');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Payment Register', '/cash-and-bank/reports/payment-register', v_reports_module_id, NULL, 'reports_cash_bank', 'file-text', 'text-purple-500', v_reports_permission_id, v_base_order + 7, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/payment-register');
END $$;
