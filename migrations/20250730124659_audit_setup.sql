
-- Phase 1: Enable Row Level Security on missing tables and add proper policies

-- Enable RLS on tables that don't have it
ALTER TABLE public.approval_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.designations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_accrual_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.smtp_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_weeks ENABLE ROW LEVEL SECURITY;

-- Create security definer functions to prevent RLS recursion
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles ur 
    JOIN public.roles r ON ur.role_id = r.id 
    WHERE ur.user_id = auth.uid() 
    AND r.name = 'Admin' 
    AND ur.is_active = true
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_hr_manager()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles ur 
    JOIN public.roles r ON ur.role_id = r.id 
    WHERE ur.user_id = auth.uid() 
    AND r.name IN ('HR Manager', 'Admin') 
    AND ur.is_active = true
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.has_permission(module_name TEXT, action TEXT)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 
    FROM public.user_roles ur
    JOIN public.role_permissions rp ON ur.role_id = rp.role_id
    JOIN public.permissions p ON rp.permission_id = p.id
    WHERE ur.user_id = auth.uid()
    AND p.module = module_name
    AND ur.is_active = true
    AND rp.is_active = true
    AND p.is_active = true
    AND (
      (action = 'view' AND p.can_view = true) OR
      (action = 'add' AND p.can_add = true) OR
      (action = 'edit' AND p.can_edit = true) OR
      (action = 'delete' AND p.can_delete = true)
    )
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- RLS Policies for approval_settings (Admin/HR only)
CREATE POLICY "Admin and HR can manage approval settings" ON public.approval_settings
  FOR ALL USING (public.is_hr_manager());

-- RLS Policies for company_settings (Admin only)
CREATE POLICY "Admin can manage company settings" ON public.company_settings
  FOR ALL USING (public.is_admin());

-- RLS Policies for departments
CREATE POLICY "HR can manage departments" ON public.departments
  FOR ALL USING (public.has_permission('departments', 'view'));

CREATE POLICY "All authenticated users can view departments" ON public.departments
  FOR SELECT USING (auth.role() = 'authenticated');

-- RLS Policies for designations
CREATE POLICY "HR can manage designations" ON public.designations
  FOR ALL USING (public.has_permission('designations', 'view'));

CREATE POLICY "All authenticated users can view designations" ON public.designations
  FOR SELECT USING (auth.role() = 'authenticated');

-- RLS Policies for email_templates (Admin/HR only)
CREATE POLICY "HR can manage email templates" ON public.email_templates
  FOR ALL USING (public.is_hr_manager());

-- RLS Policies for holidays
CREATE POLICY "HR can manage holidays" ON public.holidays
  FOR ALL USING (public.has_permission('holidays', 'view'));

CREATE POLICY "All authenticated users can view holidays" ON public.holidays
  FOR SELECT USING (auth.role() = 'authenticated');

-- RLS Policies for leave_accrual_rules (HR only)
CREATE POLICY "HR can manage leave accrual rules" ON public.leave_accrual_rules
  FOR ALL USING (public.is_hr_manager());

-- RLS Policies for leave_types
CREATE POLICY "HR can manage leave types" ON public.leave_types
  FOR ALL USING (public.has_permission('leave', 'view'));

CREATE POLICY "All authenticated users can view leave types" ON public.leave_types
  FOR SELECT USING (auth.role() = 'authenticated');

-- RLS Policies for permissions (Admin only)
CREATE POLICY "Admin can manage permissions" ON public.permissions
  FOR ALL USING (public.is_admin());

-- RLS Policies for policies (HR can manage, all can view)
CREATE POLICY "HR can manage policies" ON public.policies
  FOR ALL USING (public.has_permission('policies', 'view'));

CREATE POLICY "All authenticated users can view policies" ON public.policies
  FOR SELECT USING (auth.role() = 'authenticated');

-- RLS Policies for role_permissions (Admin only)
CREATE POLICY "Admin can manage role permissions" ON public.role_permissions
  FOR ALL USING (public.is_admin());

-- RLS Policies for roles (Admin only)
CREATE POLICY "Admin can manage roles" ON public.roles
  FOR ALL USING (public.is_admin());

-- RLS Policies for shifts
CREATE POLICY "HR can manage shifts" ON public.shifts
  FOR ALL USING (public.has_permission('attendance', 'view'));

CREATE POLICY "All authenticated users can view shifts" ON public.shifts
  FOR SELECT USING (auth.role() = 'authenticated');

-- RLS Policies for smtp_settings (Admin only - highly sensitive)
CREATE POLICY "Admin can manage SMTP settings" ON public.smtp_settings
  FOR ALL USING (public.is_admin());

-- RLS Policies for work_weeks
CREATE POLICY "HR can manage work weeks" ON public.work_weeks
  FOR ALL USING (public.has_permission('attendance', 'view'));

CREATE POLICY "All authenticated users can view work weeks" ON public.work_weeks
  FOR SELECT USING (auth.role() = 'authenticated');

-- Encrypt sensitive SMTP password field (for existing records)
UPDATE public.smtp_settings 
SET password = encode(digest(password, 'sha256'), 'hex')
WHERE password IS NOT NULL AND length(password) < 64;

-- Create initial admin user role and permissions if they don't exist
INSERT INTO public.roles (name, description, created_by) 
SELECT 'Admin', 'System Administrator with full access', auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.roles WHERE name = 'Admin');

INSERT INTO public.roles (name, description, created_by) 
SELECT 'HR Manager', 'HR Manager with employee management access', auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.roles WHERE name = 'HR Manager');

INSERT INTO public.roles (name, description, created_by) 
SELECT 'Employee', 'Regular employee with limited access', auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.roles WHERE name = 'Employee');

-- Create basic permissions for core modules
INSERT INTO public.permissions (module, name, description, can_view, can_add, can_edit, can_delete, created_by) 
SELECT 'employees', 'Employee Management', 'Manage employee records', true, true, true, true, auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE module = 'employees');

INSERT INTO public.permissions (module, name, description, can_view, can_add, can_edit, can_delete, created_by) 
SELECT 'departments', 'Department Management', 'Manage departments', true, true, true, true, auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE module = 'departments');

INSERT INTO public.permissions (module, name, description, can_view, can_add, can_edit, can_delete, created_by) 
SELECT 'attendance', 'Attendance Management', 'Manage attendance and shifts', true, true, true, true, auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE module = 'attendance');

INSERT INTO public.permissions (module, name, description, can_view, can_add, can_edit, can_delete, created_by) 
SELECT 'leave', 'Leave Management', 'Manage leave requests and types', true, true, true, true, auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE module = 'leave');

INSERT INTO public.permissions (module, name, description, can_view, can_add, can_edit, can_delete, created_by) 
SELECT 'payroll', 'Payroll Management', 'Manage payroll and salary', true, true, true, true, auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE module = 'payroll');

INSERT INTO public.permissions (module, name, description, can_view, can_add, can_edit, can_delete, created_by) 
SELECT 'policies', 'Policy Management', 'Manage company policies', true, true, true, true, auth.uid()
WHERE NOT EXISTS (SELECT 1 FROM public.permissions WHERE module = 'policies');

-- Assign all permissions to Admin role
INSERT INTO public.role_permissions (role_id, permission_id, created_by)
SELECT r.id, p.id, auth.uid()
FROM public.roles r
CROSS JOIN public.permissions p
WHERE r.name = 'Admin'
AND NOT EXISTS (
  SELECT 1 FROM public.role_permissions rp 
  WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- Assign employee-related permissions to HR Manager role
INSERT INTO public.role_permissions (role_id, permission_id, created_by)
SELECT r.id, p.id, auth.uid()
FROM public.roles r
CROSS JOIN public.permissions p
WHERE r.name = 'HR Manager'
AND p.module IN ('employees', 'departments', 'attendance', 'leave', 'policies')
AND NOT EXISTS (
  SELECT 1 FROM public.role_permissions rp 
  WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- Grant basic view permissions to Employee role
INSERT INTO public.role_permissions (role_id, permission_id, created_by)
SELECT r.id, p.id, auth.uid()
FROM public.roles r
CROSS JOIN public.permissions p
WHERE r.name = 'Employee'
AND p.module IN ('departments', 'policies')
AND NOT EXISTS (
  SELECT 1 FROM public.role_permissions rp 
  WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- Add constraint to ensure user_id in user_roles table is not nullable (security fix)
ALTER TABLE public.user_roles ALTER COLUMN user_id SET NOT NULL;

-- Add indexes for security function performance
CREATE INDEX IF NOT EXISTS idx_user_roles_security ON public.user_roles(user_id, role_id, is_active);
CREATE INDEX IF NOT EXISTS idx_roles_security ON public.roles(name, is_active);
CREATE INDEX IF NOT EXISTS idx_permissions_security ON public.permissions(module, can_view, can_add, can_edit, can_delete, is_active);
