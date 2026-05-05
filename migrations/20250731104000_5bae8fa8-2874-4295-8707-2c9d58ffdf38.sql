-- -- Fix RLS policies to prevent infinite recursion and add missing policies

-- -- First, fix user_roles policies to prevent infinite recursion
-- DROP POLICY IF EXISTS "HR can view all user roles" ON user_roles;
-- DROP POLICY IF EXISTS "Users can view their own roles" ON user_roles;
-- DROP POLICY IF EXISTS "HR can manage user roles" ON user_roles;

-- -- Create new user_roles policies using security definer functions
-- CREATE POLICY "HR can view all user roles" ON user_roles
-- FOR SELECT USING (is_hr_manager());

-- CREATE POLICY "Users can view their own roles" ON user_roles
-- FOR SELECT USING (user_id = auth.uid());

-- CREATE POLICY "HR can manage user roles" ON user_roles
-- FOR ALL USING (is_hr_manager());

-- -- Fix user_profiles policies 
-- DROP POLICY IF EXISTS "HR can view all user profiles" ON user_profiles;
-- DROP POLICY IF EXISTS "Users can view their own profile" ON user_profiles;
-- DROP POLICY IF EXISTS "HR can manage user profiles" ON user_profiles;

-- -- Create proper user_profiles policies
-- CREATE POLICY "Users can view their own profile" ON user_profiles
-- FOR SELECT USING (id = auth.uid());

-- CREATE POLICY "HR can view all user profiles" ON user_profiles
-- FOR SELECT USING (is_hr_manager());

-- CREATE POLICY "HR can insert user profiles" ON user_profiles
-- FOR INSERT WITH CHECK (is_hr_manager());

-- CREATE POLICY "HR can update user profiles" ON user_profiles
-- FOR UPDATE USING (is_hr_manager());

-- CREATE POLICY "Users can update their own profile" ON user_profiles
-- FOR UPDATE USING (id = auth.uid());

-- -- Add missing RLS policies for employee_shifts table
-- CREATE POLICY "HR can view all employee shifts" ON employee_shifts
-- FOR SELECT USING (is_hr_manager());

-- CREATE POLICY "Users can view their own shifts" ON employee_shifts
-- FOR SELECT USING (EXISTS (
--   SELECT 1 FROM employees e 
--   WHERE e.id = employee_shifts.employee_id 
--   AND e.user_id = auth.uid()
-- ));

-- CREATE POLICY "HR can manage employee shifts" ON employee_shifts
-- FOR ALL USING (is_hr_manager());

-- -- Add missing RLS policies for leave_approval_workflow table
-- CREATE POLICY "HR can view all leave approvals" ON leave_approval_workflow
-- FOR SELECT USING (is_hr_manager());

-- CREATE POLICY "Users can view their own leave approvals" ON leave_approval_workflow
-- FOR SELECT USING (EXISTS (
--   SELECT 1 FROM leave_requests lr
--   JOIN employees e ON lr.employee_id = e.id
--   WHERE lr.id = leave_approval_workflow.leave_request_id
--   AND e.user_id = auth.uid()
-- ));

-- CREATE POLICY "Approvers can view assigned approvals" ON leave_approval_workflow
-- FOR SELECT USING (approver_id = auth.uid());

-- CREATE POLICY "HR can manage leave approvals" ON leave_approval_workflow
-- FOR ALL USING (is_hr_manager());

-- CREATE POLICY "Approvers can update their assigned approvals" ON leave_approval_workflow
-- FOR UPDATE USING (approver_id = auth.uid());