
-- Create missing user_roles table
CREATE TABLE IF NOT EXISTS public.user_roles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role_id UUID REFERENCES public.roles(id) NOT NULL,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  UNIQUE(user_id, role_id)
);

-- Create security definer functions to prevent RLS recursion
CREATE OR REPLACE FUNCTION public.get_current_user_role()
RETURNS TEXT AS $$
  SELECT r.name FROM public.roles r
  INNER JOIN public.user_roles ur ON r.id = ur.role_id
  WHERE ur.user_id = auth.uid() AND ur.is_active = true
  ORDER BY r.created_at DESC
  LIMIT 1;
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
  SELECT public.get_current_user_role() = 'Admin';
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_hr_manager()
RETURNS BOOLEAN AS $$
  SELECT public.get_current_user_role() IN ('Admin', 'HR Manager');
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- Insert default roles if they don't exist
INSERT INTO public.roles (id, name, description) VALUES 
  (gen_random_uuid(), 'Admin', 'Full system access'),
  (gen_random_uuid(), 'HR Manager', 'HR management access'),
  (gen_random_uuid(), 'Employee', 'Basic employee access')
ON CONFLICT (name) DO NOTHING;

-- Enable RLS on user_roles table
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- RLS policies for user_roles
CREATE POLICY "Users can view their own roles" ON public.user_roles
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Admins can view all user roles" ON public.user_roles
  FOR SELECT USING (public.is_admin());

CREATE POLICY "Admins can manage user roles" ON public.user_roles
  FOR ALL USING (public.is_admin());

-- Enable RLS on all existing tables
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

-- Critical RLS policies for most sensitive data

-- SMTP Settings - Admin only (most sensitive)
CREATE POLICY "Admin only access to SMTP settings" ON public.smtp_settings
  FOR ALL USING (public.is_admin());

-- Company Settings - Admin only
CREATE POLICY "Admin only access to company settings" ON public.company_settings
  FOR ALL USING (public.is_admin());

-- Roles - Admin only for modifications, all authenticated users can view
CREATE POLICY "All users can view roles" ON public.roles
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Admin can insert roles" ON public.roles
  FOR INSERT WITH CHECK (public.is_admin());

CREATE POLICY "Admin can update roles" ON public.roles
  FOR UPDATE USING (public.is_admin());

CREATE POLICY "Admin can delete roles" ON public.roles
  FOR DELETE USING (public.is_admin());

-- Permissions - Admin only for modifications, all authenticated users can view
CREATE POLICY "All users can view permissions" ON public.permissions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Admin can insert permissions" ON public.permissions
  FOR INSERT WITH CHECK (public.is_admin());

CREATE POLICY "Admin can update permissions" ON public.permissions
  FOR UPDATE USING (public.is_admin());

CREATE POLICY "Admin can delete permissions" ON public.permissions
  FOR DELETE USING (public.is_admin());

-- Role Permissions - Admin only
CREATE POLICY "Admin only access to role permissions" ON public.role_permissions
  FOR ALL USING (public.is_admin());

-- Departments - HR+ can modify, all can view
CREATE POLICY "All users can view departments" ON public.departments
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert departments" ON public.departments
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update departments" ON public.departments
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete departments" ON public.departments
  FOR DELETE USING (public.is_hr_manager());

-- Designations - HR+ can modify, all can view  
CREATE POLICY "All users can view designations" ON public.designations
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert designations" ON public.designations
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update designations" ON public.designations
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete designations" ON public.designations
  FOR DELETE USING (public.is_hr_manager());

-- Leave Types - HR+ can modify, all can view
CREATE POLICY "All users can view leave types" ON public.leave_types
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert leave types" ON public.leave_types
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update leave types" ON public.leave_types
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete leave types" ON public.leave_types
  FOR DELETE USING (public.is_hr_manager());

-- Leave Accrual Rules - HR+ only
CREATE POLICY "HR managers can access leave accrual rules" ON public.leave_accrual_rules
  FOR ALL USING (public.is_hr_manager());

-- Holidays - HR+ can modify, all can view
CREATE POLICY "All users can view holidays" ON public.holidays
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert holidays" ON public.holidays
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update holidays" ON public.holidays
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete holidays" ON public.holidays
  FOR DELETE USING (public.is_hr_manager());

-- Shifts - HR+ can modify, all can view
CREATE POLICY "All users can view shifts" ON public.shifts
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert shifts" ON public.shifts
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update shifts" ON public.shifts
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete shifts" ON public.shifts
  FOR DELETE USING (public.is_hr_manager());

-- Work Weeks - HR+ can modify, all can view
CREATE POLICY "All users can view work weeks" ON public.work_weeks
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert work weeks" ON public.work_weeks
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update work weeks" ON public.work_weeks
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete work weeks" ON public.work_weeks
  FOR DELETE USING (public.is_hr_manager());

-- Email Templates - HR+ can modify, all can view
CREATE POLICY "All users can view email templates" ON public.email_templates
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert email templates" ON public.email_templates
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update email templates" ON public.email_templates
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete email templates" ON public.email_templates
  FOR DELETE USING (public.is_hr_manager());

-- Policies - HR+ can modify, all can view
CREATE POLICY "All users can view policies" ON public.policies
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "HR can insert policies" ON public.policies
  FOR INSERT WITH CHECK (public.is_hr_manager());

CREATE POLICY "HR can update policies" ON public.policies
  FOR UPDATE USING (public.is_hr_manager());

CREATE POLICY "HR can delete policies" ON public.policies
  FOR DELETE USING (public.is_hr_manager());

-- Approval Settings - Admin only
CREATE POLICY "Admin only access to approval settings" ON public.approval_settings
  FOR ALL USING (public.is_admin());

-- Trigger already created in employees_setup migration

-- Create trigger to assign default Employee role on user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT NEW.id, r.id
  FROM public.roles r
  WHERE r.name = 'Employee' AND r.is_active = true
  LIMIT 1;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
