-- Add attendance permission
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description) VALUES 
  ('Attendance Management', 'attendance', true, true, true, true, 'Full access to attendance management')
ON CONFLICT (name) DO NOTHING;

-- Assign attendance permission to Admin and HR Manager roles
DO $$
DECLARE
  admin_role_id UUID;
  hr_role_id UUID;
  attendance_perm_id UUID;
BEGIN
  -- Get role IDs
  SELECT id INTO admin_role_id FROM public.roles WHERE name = 'Admin';
  SELECT id INTO hr_role_id FROM public.roles WHERE name = 'HR Manager';
  SELECT id INTO attendance_perm_id FROM public.permissions WHERE name = 'Attendance Management';
  
  -- Assign to Admin role
  INSERT INTO public.role_permissions (role_id, permission_id)
  VALUES (admin_role_id, attendance_perm_id)
  ON CONFLICT (role_id, permission_id) DO NOTHING;
  
  -- Assign to HR Manager role
  INSERT INTO public.role_permissions (role_id, permission_id)
  VALUES (hr_role_id, attendance_perm_id)
  ON CONFLICT (role_id, permission_id) DO NOTHING;
END $$;