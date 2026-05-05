-- Cash & Bank Module - Sidebar Navigation Setup
-- Migration: 20260411000008_v2
-- Purpose: Add Cash & Bank pages to app_module_groups, app_modules, and app_pages tables
--          with proper permission linkage for sidebar menu display
-- Fixed: Uses SELECT max(display_order) + X to ensure globally unique display orders

-- ============================================
-- STEP 1: Add App Module Group
-- ============================================
INSERT INTO public.app_module_groups (name, slug, display_order, is_active, created_at, updated_at)
SELECT 'Cash & Bank', 'cash-and-bank', COALESCE((SELECT max(display_order) FROM public.app_module_groups), 0) + 10, true, NOW(), NOW()
WHERE NOT EXISTS (SELECT 1 FROM public.app_module_groups WHERE slug = 'cash-and-bank');

-- ============================================
-- STEP 2: Add App Modules
-- ============================================
DO $$
DECLARE
  v_group_id UUID;
  v_cash_bank_permission_id UUID;
  v_bank_accounts_permission_id UUID;
  v_payments_permission_id UUID;
  v_reports_permission_id UUID;
  v_base_order INT;
BEGIN
  -- Get module group ID
  SELECT id INTO v_group_id FROM public.app_module_groups WHERE slug = 'cash-and-bank';

  -- Get permission IDs
  SELECT id INTO v_cash_bank_permission_id FROM public.permissions WHERE name = 'Cash & Bank Dashboard';
  SELECT id INTO v_bank_accounts_permission_id FROM public.permissions WHERE name = 'Bank Accounts Management';
  SELECT id INTO v_payments_permission_id FROM public.permissions WHERE name = 'Payments Management';
  SELECT id INTO v_reports_permission_id FROM public.permissions WHERE name = 'Cash & Bank Reports';

  -- Get next available display order for modules
  SELECT COALESCE(max(display_order), 0) INTO v_base_order FROM public.app_modules;

  -- Add Dashboard module
  INSERT INTO public.app_modules (name, slug, icon_name, icon_color, module_group_id, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Dashboard', 'cash-bank-dashboard', 'layout-dashboard', 'text-blue-500', v_group_id, v_cash_bank_permission_id, v_base_order + 1, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_modules WHERE slug = 'cash-bank-dashboard');

  -- Add Accounts module
  INSERT INTO public.app_modules (name, slug, icon_name, icon_color, module_group_id, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Accounts', 'cash-bank-accounts', 'building-2', 'text-indigo-500', v_group_id, v_bank_accounts_permission_id, v_base_order + 2, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_modules WHERE slug = 'cash-bank-accounts');

  -- Add Payments module
  INSERT INTO public.app_modules (name, slug, icon_name, icon_color, module_group_id, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Payments', 'cash-bank-payments', 'receipt', 'text-green-500', v_group_id, v_payments_permission_id, v_base_order + 3, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_modules WHERE slug = 'cash-bank-payments');

  -- Add Reports module
  INSERT INTO public.app_modules (name, slug, icon_name, icon_color, module_group_id, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Reports', 'cash-bank-reports', 'bar-chart-3', 'text-purple-500', v_group_id, v_reports_permission_id, v_base_order + 4, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_modules WHERE slug = 'cash-bank-reports');
END $$;

-- ============================================
-- STEP 3: Add App Pages
-- ============================================
DO $$
DECLARE
  v_dashboard_module_id UUID;
  v_accounts_module_id UUID;
  v_payments_module_id UUID;
  v_reports_module_id UUID;
  v_group_id UUID;

  v_cash_bank_permission_id UUID;
  v_bank_accounts_permission_id UUID;
  v_payments_permission_id UUID;
  v_reports_permission_id UUID;
  v_base_order INT;
BEGIN
  -- Get module IDs
  SELECT id INTO v_dashboard_module_id FROM public.app_modules WHERE slug = 'cash-bank-dashboard';
  SELECT id INTO v_accounts_module_id FROM public.app_modules WHERE slug = 'cash-bank-accounts';
  SELECT id INTO v_payments_module_id FROM public.app_modules WHERE slug = 'cash-bank-payments';
  SELECT id INTO v_reports_module_id FROM public.app_modules WHERE slug = 'cash-bank-reports';
  SELECT id INTO v_group_id FROM public.app_module_groups WHERE slug = 'cash-and-bank';

  -- Get permission IDs
  SELECT id INTO v_cash_bank_permission_id FROM public.permissions WHERE name = 'Cash & Bank Dashboard';
  SELECT id INTO v_bank_accounts_permission_id FROM public.permissions WHERE name = 'Bank Accounts Management';
  SELECT id INTO v_payments_permission_id FROM public.permissions WHERE name = 'Payments Management';
  SELECT id INTO v_reports_permission_id FROM public.permissions WHERE name = 'Cash & Bank Reports';

  -- Get next available display order for pages
  SELECT COALESCE(max(display_order), 0) INTO v_base_order FROM public.app_pages;

  -- ============================================
  -- Dashboard Module Pages
  -- ============================================
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Dashboard', '/cash-and-bank/dashboard', v_dashboard_module_id, v_group_id, 'cash_bank', 'layout-dashboard', 'text-blue-500', v_cash_bank_permission_id, v_base_order + 1, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/dashboard');

  -- ============================================
  -- Accounts Module Pages
  -- ============================================
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Accounts List', '/cash-and-bank/accounts', v_accounts_module_id, v_group_id, 'bank_accounts', 'building-2', 'text-indigo-500', v_bank_accounts_permission_id, v_base_order + 2, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/accounts');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Add Account', '/cash-and-bank/accounts/add', v_accounts_module_id, v_group_id, 'bank_accounts', 'plus-circle', 'text-indigo-500', v_bank_accounts_permission_id, v_base_order + 3, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/accounts/add');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Edit Account', '/cash-and-bank/accounts/edit/:id', v_accounts_module_id, v_group_id, 'bank_accounts', 'edit-3', 'text-indigo-500', v_bank_accounts_permission_id, v_base_order + 4, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/accounts/edit/:id');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'View Account', '/cash-and-bank/accounts/:id', v_accounts_module_id, v_group_id, 'bank_accounts', 'eye', 'text-indigo-500', v_bank_accounts_permission_id, v_base_order + 5, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/accounts/:id');

  -- ============================================
  -- Payments Module Pages
  -- ============================================
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Payments List', '/cash-and-bank/payments', v_payments_module_id, v_group_id, 'payments', 'receipt', 'text-green-500', v_payments_permission_id, v_base_order + 6, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/payments');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'View Payment', '/cash-and-bank/payments/:id', v_payments_module_id, v_group_id, 'payments', 'eye', 'text-green-500', v_payments_permission_id, v_base_order + 7, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/payments/:id');

  -- ============================================
  -- Reports Module Pages
  -- ============================================
  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Bank Book', '/cash-and-bank/reports/bank-book', v_reports_module_id, v_group_id, 'reports_cash_bank', 'book-open', 'text-purple-500', v_reports_permission_id, v_base_order + 8, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/bank-book');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Cash Book', '/cash-and-bank/reports/cash-book', v_reports_module_id, v_group_id, 'reports_cash_bank', 'book-open', 'text-purple-500', v_reports_permission_id, v_base_order + 9, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/cash-book');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Account Summary', '/cash-and-bank/reports/account-summary', v_reports_module_id, v_group_id, 'reports_cash_bank', 'pie-chart', 'text-purple-500', v_reports_permission_id, v_base_order + 10, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/account-summary');

  INSERT INTO public.app_pages (title, url, module_id, module_group_id, resource_key, icon_name, icon_color, permission_id, display_order, is_active, created_at, updated_at)
  SELECT 'Payment Register', '/cash-and-bank/reports/payment-register', v_reports_module_id, v_group_id, 'reports_cash_bank', 'file-text', 'text-purple-500', v_reports_permission_id, v_base_order + 11, true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM public.app_pages WHERE url = '/cash-and-bank/reports/payment-register');
END $$;

-- ============================================
-- STEP 4: Assign Permissions to Admin & HR Roles
-- ============================================
DO $$
DECLARE
  v_admin_role_id UUID;
  v_hr_role_id UUID;
  v_cash_bank_permission_id UUID;
  v_bank_accounts_permission_id UUID;
  v_payments_permission_id UUID;
  v_transfers_permission_id UUID;
  v_balance_adj_permission_id UUID;
  v_reports_permission_id UUID;
BEGIN
  -- Get role IDs
  SELECT id INTO v_admin_role_id FROM public.roles WHERE name = 'Admin';
  SELECT id INTO v_hr_role_id FROM public.roles WHERE name = 'HR Manager';

  -- Get permission IDs
  SELECT id INTO v_cash_bank_permission_id FROM public.permissions WHERE name = 'Cash & Bank Dashboard';
  SELECT id INTO v_bank_accounts_permission_id FROM public.permissions WHERE name = 'Bank Accounts Management';
  SELECT id INTO v_payments_permission_id FROM public.permissions WHERE name = 'Payments Management';
  SELECT id INTO v_transfers_permission_id FROM public.permissions WHERE name = 'Transfers Management';
  SELECT id INTO v_balance_adj_permission_id FROM public.permissions WHERE name = 'Balance Adjustments';
  SELECT id INTO v_reports_permission_id FROM public.permissions WHERE name = 'Cash & Bank Reports';

  -- Assign ALL permissions to Admin role
  INSERT INTO public.role_permissions (role_id, permission_id, created_at, updated_at)
  SELECT v_admin_role_id, perm.id, NOW(), NOW()
  FROM public.permissions perm
  WHERE perm.name IN (
    'Cash & Bank Dashboard',
    'Bank Accounts Management',
    'Payments Management',
    'Transfers Management',
    'Balance Adjustments',
    'Cash & Bank Reports'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.role_permissions rp 
    WHERE rp.role_id = v_admin_role_id AND rp.permission_id = perm.id
  );

  -- Assign view-only permissions to HR Manager
  INSERT INTO public.role_permissions (role_id, permission_id, created_at, updated_at)
  SELECT v_hr_role_id, perm.id, NOW(), NOW()
  FROM public.permissions perm
  WHERE perm.name IN (
    'Cash & Bank Dashboard',
    'Cash & Bank Reports'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.role_permissions rp 
    WHERE rp.role_id = v_hr_role_id AND rp.permission_id = perm.id
  );
END $$;

-- ============================================
-- Verification Queries (Optional - for testing)
-- ============================================
-- SELECT 'Module Group:' as label, name, slug, display_order FROM public.app_module_groups WHERE slug = 'cash-and-bank';
-- SELECT 'Modules:' as label, name, slug, display_order FROM public.app_modules WHERE module_group_id IN (SELECT id FROM public.app_module_groups WHERE slug = 'cash-and-bank') ORDER BY display_order;
-- SELECT 'Pages:' as label, title, url, resource_key, icon_name, display_order FROM public.app_pages WHERE module_group_id IN (SELECT id FROM public.app_module_groups WHERE slug = 'cash-and-bank') ORDER BY display_order;
