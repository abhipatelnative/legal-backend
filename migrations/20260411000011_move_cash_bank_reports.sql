-- Cash & Bank Module - Move Reports to Main Reports Section
-- Migration: 20260411000011
-- Purpose: Move Cash & Bank reports from Cash & Bank sidebar section to main Reports section

-- ============================================
-- STEP 1: Update app_pages to remove module_id (cash_bank)
-- This will move reports from Cash & Bank section to Reports section
-- ============================================

-- Update Bank Book to Reports section
UPDATE public.app_pages
SET 
  module_id = NULL,
  resource_key = 'reports_cash_bank',
  permission_id = (SELECT id FROM public.permissions WHERE name = 'Cash & Bank Reports' LIMIT 1),
  display_order =100,
  updated_at = NOW()
WHERE url = '/cash-and-bank/reports/bank-book';

-- Update Cash Book to Reports section
UPDATE public.app_pages
SET 
  module_id = NULL,
  resource_key = 'reports_cash_bank',
  permission_id = (SELECT id FROM public.permissions WHERE name = 'Cash & Bank Reports' LIMIT 1),
  display_order =101,
  updated_at = NOW()
WHERE url = '/cash-and-bank/reports/cash-book';

-- Update Account Summary to Reports section
UPDATE public.app_pages
SET 
  module_id = NULL,
  resource_key = 'reports_cash_bank',
  permission_id = (SELECT id FROM public.permissions WHERE name = 'Cash & Bank Reports' LIMIT 1),
  display_order =102,
  updated_at = NOW()
WHERE url = '/cash-and-bank/reports/account-summary';

-- Update Payment Register to Reports section
UPDATE public.app_pages
SET 
  module_id = NULL,
  resource_key = 'reports_cash_bank',
  permission_id = (SELECT id FROM public.permissions WHERE name = 'Cash & Bank Reports' LIMIT 1),
  display_order =103,
  updated_at = NOW()
WHERE url = '/cash-and-bank/reports/payment-register';

-- ============================================
-- STEP 2: Deactivate cash-bank-reports module
-- ============================================

UPDATE public.app_modules
SET 
  is_active = false,
  updated_at = NOW()
WHERE slug = 'cash-bank-reports';

-- ============================================
-- VERIFICATION
-- ============================================

-- Show updated Cash & Bank report pages
SELECT
  title,
  url,
  module_id,
  resource_key,
  display_order
FROM public.app_pages
WHERE url IN (
  '/cash-and-bank/reports/bank-book',
  '/cash-and-bank/reports/cash-book',
  '/cash-and-bank/reports/account-summary',
  '/cash-and-bank/reports/payment-register'
)
ORDER BY display_order;

-- Show deactivated cash-bank-reports module
SELECT
  name,
  slug,
  is_active
FROM public.app_modules
WHERE slug = 'cash-bank-reports';
