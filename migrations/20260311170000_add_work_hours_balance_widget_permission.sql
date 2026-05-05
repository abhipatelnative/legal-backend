-- Migration: Add permission for Employee Hour Balance dashboard widget
-- Visibility: Admin and Sales Partner only

-- 1) Ensure widget permission exists with view-only capabilities
INSERT INTO public.permissions (
  name,
  module,
  can_view,
  can_add,
  can_edit,
  can_delete,
  description,
  is_active,
  is_deleted,
  created_at,
  updated_at
)
SELECT
  'widget_work_hours_balance',
  'Dashboard Widgets',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Dashboard widget visibility: employee month-to-date work-hours balance',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'widget_work_hours_balance'
);

-- Keep canonical attributes in case permission row already existed
UPDATE public.permissions
SET
  module = 'Dashboard Widgets',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Dashboard widget visibility: employee month-to-date work-hours balance',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'widget_work_hours_balance';

-- 2) Assign role permission to Admin + Sales Partner (and Sale Partner alias)
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'widget_work_hours_balance'
  LIMIT 1
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE LOWER(TRIM(name)) IN ('admin', 'sales partner', 'sale partner')
    AND COALESCE(is_deleted, FALSE) = FALSE
)
INSERT INTO public.role_permissions (
  role_id,
  permission_id,
  is_active,
  is_deleted,
  created_at,
  updated_at
)
SELECT
  r.id,
  p.id,
  TRUE,
  FALSE,
  NOW(),
  NOW()
FROM allowed_roles r
CROSS JOIN target_permission p
ON CONFLICT (role_id, permission_id) DO UPDATE
SET
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW();

-- 3) Enforce widget visibility for only allowed roles
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'widget_work_hours_balance'
  LIMIT 1
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE LOWER(TRIM(name)) IN ('admin', 'sales partner', 'sale partner')
)
DELETE FROM public.role_permissions rp
USING target_permission tp
WHERE rp.permission_id = tp.id
  AND rp.role_id NOT IN (SELECT id FROM allowed_roles);
