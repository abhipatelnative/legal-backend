-- Migration: Bulk create view-only permissions for every existing module
-- Purpose: Avoid manual creation of per-module view-only permissions in Security > Permissions

WITH distinct_modules AS (
  SELECT DISTINCT p.module
  FROM public.permissions p
  WHERE p.is_deleted = false
    AND p.module IS NOT NULL
    AND BTRIM(p.module) <> ''
),
view_only_permissions AS (
  SELECT
    dm.module,
    'VIEW_ONLY_' || UPPER(REGEXP_REPLACE(dm.module, '[^a-zA-Z0-9]+', '_', 'g')) AS name,
    'View-only access for module: ' || dm.module AS description
  FROM distinct_modules dm
)
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
  vop.name,
  vop.module,
  true,
  false,
  false,
  false,
  vop.description,
  true,
  false,
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
FROM view_only_permissions vop
ON CONFLICT (name)
DO UPDATE SET
  module = EXCLUDED.module,
  can_view = true,
  can_add = false,
  can_edit = false,
  can_delete = false,
  description = EXCLUDED.description,
  is_active = true,
  is_deleted = false,
  updated_at = CURRENT_TIMESTAMP;
