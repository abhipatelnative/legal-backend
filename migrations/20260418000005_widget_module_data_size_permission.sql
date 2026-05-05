-- Migration: Add permission for "Module-wise Data Size" dashboard widget
-- Admin-only by default

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
  'widget_module_data_size',
  'Dashboard Widgets',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Dashboard widget visibility: module-wise database storage breakdown',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'widget_module_data_size'
);

-- Keep canonical attributes in case permission row already existed
UPDATE public.permissions
SET
  module = 'Dashboard Widgets',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Dashboard widget visibility: module-wise database storage breakdown',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'widget_module_data_size';

-- 2) Assign role permission to Admin only
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'widget_module_data_size'
  LIMIT 1
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE LOWER(TRIM(name)) IN ('admin')
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

-- 3) Remove from non-admin roles (admin only widget)
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'widget_module_data_size'
  LIMIT 1
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE LOWER(TRIM(name)) IN ('admin')
)
DELETE FROM public.role_permissions rp
USING target_permission tp
WHERE rp.permission_id = tp.id
  AND rp.role_id NOT IN (SELECT id FROM allowed_roles);
