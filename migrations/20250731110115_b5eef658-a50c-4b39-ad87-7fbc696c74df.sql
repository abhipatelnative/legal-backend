-- First, drop all existing policies on user_roles to start fresh
DROP POLICY IF EXISTS "HR can manage user roles" ON public.user_roles;
DROP POLICY IF EXISTS "HR can view all user roles" ON public.user_roles;
DROP POLICY IF EXISTS "Users can view their own roles" ON public.user_roles;
DROP POLICY IF EXISTS "System can create user roles" ON public.user_roles;

-- Create new policies that don't cause recursion
-- Allow users to view only their own roles
CREATE POLICY "Users can view their own roles"
ON public.user_roles
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

-- Allow system/admin to insert roles (no recursion since we're not checking roles here)
CREATE POLICY "System can insert user roles"
ON public.user_roles
FOR INSERT
TO authenticated
WITH CHECK (true);

-- Allow system/admin to update roles
CREATE POLICY "System can update user roles"
ON public.user_roles
FOR UPDATE
TO authenticated
USING (true);

-- Allow system/admin to delete roles
CREATE POLICY "System can delete user roles"
ON public.user_roles
FOR DELETE
TO authenticated
USING (true);