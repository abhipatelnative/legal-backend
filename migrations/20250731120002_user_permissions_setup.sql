-- Insert permissions for all modules
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description) VALUES 
  ('User Management', 'users', true, true, true, true, 'Full access to user management'),
  ('Employee Management', 'employees', true, true, true, true, 'Full access to employee management'),
  ('Department Management', 'departments', true, true, true, true, 'Full access to department management'),
  ('Role Management', 'roles', true, true, true, true, 'Full access to role management'),
  ('Contract Management', 'contracts', true, true, true, true, 'Full access to contract management'),
  ('HR Management', 'hr', true, true, true, true, 'Full access to HR functions'),
  ('Attendance Management', 'attendance', true, true, true, true, 'Full access to attendance management'),
  ('Payroll Management', 'payroll', true, true, true, true, 'Full access to payroll management'),
  ('Performance Management', 'performance', true, true, true, true, 'Full access to performance management'),
  ('Dashboard Access', 'dashboard', true, false, false, false, 'Access to dashboard'),
  ('Employee Dashboard', 'employee', true, false, false, false, 'Access to employee dashboard'),
  ('Masters Management', 'masters', true, true, true, true, 'Full access to master data'),
  ('Shifts Management', 'shifts', true, true, true, true, 'Full access to shifts management'),
  ('Holidays Management', 'holidays', true, true, true, true, 'Full access to holidays management'),
  ('Leave Types Management', 'leave-types', true, true, true, true, 'Full access to leave types management'),
  ('Permissions Management', 'permissions', true, true, true, true, 'Full access to permissions management'),
  ('Work Weeks Management', 'work-weeks', true, true, true, true, 'Full access to work weeks management'),
  ('Contract Types Management', 'contract-types', true, true, true, true, 'Full access to contract types management'),
  ('Salary Components Management', 'salary-components', true, true, true, true, 'Full access to salary components management'),
  ('Settings Management', 'settings', true, true, true, true, 'Full access to system settings'),
  ('Reports Access', 'reports', true, true, false, false, 'Access to reports and analytics')
ON CONFLICT (name) DO NOTHING;

-- Get role IDs
DO $$
DECLARE
  admin_role_id UUID;
  hr_role_id UUID;
  employee_role_id UUID;
  user_perm_id UUID;
  employee_perm_id UUID;
  dept_perm_id UUID;
  role_perm_id UUID;
BEGIN
  -- Get role IDs
  SELECT id INTO admin_role_id FROM public.roles WHERE name = 'Admin';
  SELECT id INTO hr_role_id FROM public.roles WHERE name = 'HR Manager';
  SELECT id INTO employee_role_id FROM public.roles WHERE name = 'Employee';
  
  -- Assign all permissions to Admin role
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT admin_role_id, id FROM public.permissions WHERE is_active = true
  ON CONFLICT (role_id, permission_id) DO NOTHING;
  
  -- HR Manager gets most management permissions
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT hr_role_id, id FROM public.permissions 
  WHERE name IN (
    'User Management', 'Employee Management', 'Department Management', 
    'Contract Management', 'HR Management', 'Attendance Management',
    'Dashboard Access', 'Masters Management', 'Reports Access',
    'Shifts Management', 'Holidays Management', 'Leave Types Management',
    'Work Weeks Management', 'Contract Types Management'
  )
  ON CONFLICT (role_id, permission_id) DO NOTHING;
  
  -- Employee gets basic access only
  INSERT INTO public.role_permissions (role_id, permission_id)
  SELECT employee_role_id, id FROM public.permissions 
  WHERE name IN ('Employee Dashboard')
  ON CONFLICT (role_id, permission_id) DO NOTHING;
END $$;