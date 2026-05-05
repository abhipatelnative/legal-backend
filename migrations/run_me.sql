-- Cash & Bank Module - Move Reports to Main Reports Section
-- Migration: 20260411000011
-- Purpose: Update permissions for Cash & Bank reports to match new Reports section placement

-- STEP 1: Update app_pages permissions
-- Ensure reports use the 'Cash & Bank Reports' permission
UPDATE public.app_pages
SET 
  permission_id = (SELECT id FROM public.permissions WHERE name = 'Cash & Bank Reports' LIMIT 1),
  updated_at = NOW()
WHERE url IN (
  '/cash-and-bank/reports/bank-book',
  '/cash-and-bank/reports/cash-book',
  '/cash-and-bank/reports/account-summary',
  '/cash-and-bank/reports/payment-register'
);

-- STEP 2: Deactivate cash-bank-reports module
UPDATE public.app_modules
SET 
  is_active = false,
  updated_at = NOW()
WHERE slug = 'cash-bank-reports';

-- VERIFICATION: Show updated permissions
SELECT 
  title,
  url,
  permission_id,
  (SELECT name FROM public.permissions WHERE id = app_pages.permission_id) as permission_name
FROM public.app_pages
WHERE url IN (
  '/cash-and-bank/reports/bank-book',
  '/cash-and-bank/reports/cash-book',
  '/cash-and-bank/reports/account-summary',
  '/cash-and-bank/reports/payment-register'
);

-- VERIFICATION: Show deactivated module
SELECT 
  title,
  slug,
  is_active
FROM public.app_modules
WHERE slug = 'cash-bank-reports';
