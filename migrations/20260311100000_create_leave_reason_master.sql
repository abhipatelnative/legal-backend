-- Create leave reason master table
CREATE TABLE IF NOT EXISTS public.leave_reason_master (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  reason_name varchar(255) NOT NULL,
  description text NULL,
  is_active boolean NOT NULL DEFAULT true,
  is_deleted boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by uuid NULL REFERENCES auth.users(id),
  updated_by uuid NULL REFERENCES auth.users(id),
  CONSTRAINT leave_reason_master_pkey PRIMARY KEY (id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_leave_reason_master_active_deleted
  ON public.leave_reason_master (is_active, is_deleted);

CREATE UNIQUE INDEX IF NOT EXISTS idx_leave_reason_master_reason_name_unique_active
  ON public.leave_reason_master (LOWER(reason_name))
  WHERE is_deleted = false;

-- Permissions for Leave Reason Master
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description, created_at, updated_at)
VALUES
  ('Leave Reasons (View)', 'masters_leave_reasons', true, false, false, false, 'View access for HR Masters > Leave Reasons page', NOW(), NOW()),
  ('Leave Reasons (Add)', 'masters_leave_reasons', false, true, false, false, 'Add access for HR Masters > Leave Reasons page', NOW(), NOW()),
  ('Leave Reasons (Edit)', 'masters_leave_reasons', false, false, true, false, 'Edit access for HR Masters > Leave Reasons page', NOW(), NOW()),
  ('Leave Reasons (Delete)', 'masters_leave_reasons', false, false, false, true, 'Delete access for HR Masters > Leave Reasons page', NOW(), NOW())
ON CONFLICT (name) DO NOTHING;

-- Map full access permissions to Admin, HR Manager, and Manager roles
INSERT INTO public.role_permissions (role_id, permission_id, created_at, updated_at)
SELECT r.id, p.id, NOW(), NOW()
FROM public.roles r
JOIN public.permissions p ON p.module = 'masters_leave_reasons'
WHERE r.name IN ('Admin', 'HR Manager', 'Manager')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Map view-only permission to Sales Partner role
INSERT INTO public.role_permissions (role_id, permission_id, created_at, updated_at)
SELECT r.id, p.id, NOW(), NOW()
FROM public.roles r
JOIN public.permissions p
  ON p.module = 'masters_leave_reasons'
 AND p.name = 'Leave Reasons (View)'
WHERE r.name IN ('Sales Partner', 'Sale Partner')
ON CONFLICT (role_id, permission_id) DO NOTHING;
