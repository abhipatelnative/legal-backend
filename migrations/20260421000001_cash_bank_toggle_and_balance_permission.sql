ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS cash_bank_enabled BOOLEAN NOT NULL DEFAULT false;

INSERT INTO public.permissions (
  name,
  module,
  can_view,
  can_add,
  can_edit,
  can_delete,
  description,
  is_active,
  created_at,
  updated_at
)
SELECT
  'Bank Balance View',
  'bank_balance_view',
  true,
  false,
  false,
  false,
  'Allows viewing bank and cash balances, projected balances, and balance-based warnings.',
  true,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE module = 'bank_balance_view'
);

INSERT INTO public.role_permissions (role_id, permission_id, is_active, created_at, updated_at)
SELECT
  r.id,
  p.id,
  true,
  NOW(),
  NOW()
FROM public.roles r
CROSS JOIN public.permissions p
WHERE p.module = 'bank_balance_view'
  AND lower(trim(r.name)) IN ('admin', 'hr manager')
  AND NOT EXISTS (
    SELECT 1
    FROM public.role_permissions rp
    WHERE rp.role_id = r.id
      AND rp.permission_id = p.id
  );
