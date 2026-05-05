-- Migration: Add Employee Filter permissions for Advance Salary and Notice Penalties
-- Controls whether a user can see all employees' data or only their own
-- Only Admin and HR Manager should have these permissions

----------------------------------------------------------------------
-- 1) Advance Salary Employee Filter (View)
----------------------------------------------------------------------

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
  'Advance Salary Employee Filter (View)',
  'financial_management',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Allows selecting any employee in Advance Salary filters',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'Advance Salary Employee Filter (View)'
);

UPDATE public.permissions
SET
  module = 'financial_management',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Allows selecting any employee in Advance Salary filters',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'Advance Salary Employee Filter (View)';

----------------------------------------------------------------------
-- 2) Work Penalties Employee Filter (View)
----------------------------------------------------------------------

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
  'Work Penalties Employee Filter (View)',
  'notice_penalties',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Allows selecting any employee in Work Penalties filters',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'Work Penalties Employee Filter (View)'
);

UPDATE public.permissions
SET
  module = 'notice_penalties',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Allows selecting any employee in Work Penalties filters',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'Work Penalties Employee Filter (View)';

----------------------------------------------------------------------
-- 3) Grant both permissions only to Admin and HR Manager
----------------------------------------------------------------------

WITH target_permissions AS (
  SELECT id
  FROM public.permissions
  WHERE name IN (
    'Advance Salary Employee Filter (View)',
    'Work Penalties Employee Filter (View)'
  )
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE COALESCE(is_deleted, FALSE) = FALSE
    AND LOWER(TRIM(name)) IN ('admin', 'hr manager')
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
CROSS JOIN target_permissions p
ON CONFLICT (role_id, permission_id) DO UPDATE
SET
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW();

----------------------------------------------------------------------
-- 4) Remove both permissions from all other roles
----------------------------------------------------------------------

WITH target_permissions AS (
  SELECT id
  FROM public.permissions
  WHERE name IN (
    'Advance Salary Employee Filter (View)',
    'Work Penalties Employee Filter (View)'
  )
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE COALESCE(is_deleted, FALSE) = FALSE
    AND LOWER(TRIM(name)) IN ('admin', 'hr manager')
)
DELETE FROM public.role_permissions rp
USING target_permissions tp
WHERE rp.permission_id = tp.id
  AND rp.role_id NOT IN (SELECT id FROM allowed_roles);
