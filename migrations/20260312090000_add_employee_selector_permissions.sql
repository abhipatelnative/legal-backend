-- Migration: Add selector permissions and profile cross-view permissions
-- Rules:
-- 1) Calendar and Punch Requests selectors are allowed for all roles except Employee
-- 2) Employee profile cross-view is allowed only for HR/Admin/Sales Partner roles

-- 1) Calendar selector permission
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
  'Calendar Employee Selector (View)',
  'calendar',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Allows selecting any employee in Calendar filters',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'Calendar Employee Selector (View)'
);

UPDATE public.permissions
SET
  module = 'calendar',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Allows selecting any employee in Calendar filters',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'Calendar Employee Selector (View)';

-- 2) Punch Requests selector permission
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
  'Punch Requests Employee Filter (View)',
  'punch_edit_requests',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Allows selecting any employee in Punch Requests filters',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'Punch Requests Employee Filter (View)'
);

UPDATE public.permissions
SET
  module = 'punch_edit_requests',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Allows selecting any employee in Punch Requests filters',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'Punch Requests Employee Filter (View)';

-- 3) Employee profile cross-view permission
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
  'Employee Profile Cross View (View)',
  'employees',
  TRUE,
  FALSE,
  FALSE,
  FALSE,
  'Allows viewing/selecting other employee profiles in My Profile page',
  TRUE,
  FALSE,
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.permissions
  WHERE name = 'Employee Profile Cross View (View)'
);

UPDATE public.permissions
SET
  module = 'employees',
  can_view = TRUE,
  can_add = FALSE,
  can_edit = FALSE,
  can_delete = FALSE,
  description = 'Allows viewing/selecting other employee profiles in My Profile page',
  is_active = TRUE,
  is_deleted = FALSE,
  updated_at = NOW()
WHERE name = 'Employee Profile Cross View (View)';

-- 4) Grant selector permissions to all non-Employee roles
WITH target_permissions AS (
  SELECT id
  FROM public.permissions
  WHERE name IN (
    'Calendar Employee Selector (View)',
    'Punch Requests Employee Filter (View)'
  )
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE COALESCE(is_deleted, FALSE) = FALSE
    AND LOWER(TRIM(name)) <> 'employee'
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

-- 5) Grant profile cross-view permission only to Admin/HR/Sales Partner roles
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'Employee Profile Cross View (View)'
  LIMIT 1
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE COALESCE(is_deleted, FALSE) = FALSE
    AND LOWER(TRIM(name)) IN ('admin', 'hr', 'hr manager', 'sales partner', 'sale partner')
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

-- 6) Enforce profile cross-view permission only for Admin/HR/Sales Partner roles
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'Employee Profile Cross View (View)'
  LIMIT 1
),
allowed_roles AS (
  SELECT id
  FROM public.roles
  WHERE COALESCE(is_deleted, FALSE) = FALSE
    AND LOWER(TRIM(name)) IN ('admin', 'hr', 'hr manager', 'sales partner', 'sale partner')
)
DELETE FROM public.role_permissions rp
USING target_permission tp
WHERE rp.permission_id = tp.id
  AND rp.role_id NOT IN (SELECT id FROM allowed_roles);

-- 7) Remove selector permissions from Employee role if present
WITH target_permissions AS (
  SELECT id
  FROM public.permissions
  WHERE name IN (
    'Calendar Employee Selector (View)',
    'Punch Requests Employee Filter (View)'
  )
),
employee_roles AS (
  SELECT id
  FROM public.roles
  WHERE LOWER(TRIM(name)) = 'employee'
)
DELETE FROM public.role_permissions rp
USING target_permissions tp
WHERE rp.permission_id = tp.id
  AND rp.role_id IN (SELECT id FROM employee_roles);

-- 8) Ensure profile cross-view permission is removed from Employee role
WITH target_permission AS (
  SELECT id
  FROM public.permissions
  WHERE name = 'Employee Profile Cross View (View)'
  LIMIT 1
),
employee_roles AS (
  SELECT id
  FROM public.roles
  WHERE LOWER(TRIM(name)) = 'employee'
)
DELETE FROM public.role_permissions rp
USING target_permission tp
WHERE rp.permission_id = tp.id
  AND rp.role_id IN (SELECT id FROM employee_roles);
