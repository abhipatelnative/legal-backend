-- Fix infinite recursion in user_roles RLS policies by using security definer functions

-- Create security definer function to get user role safely
CREATE OR REPLACE FUNCTION public.get_user_role_safe(user_uuid uuid)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
  SELECT r.name FROM public.roles r
  INNER JOIN public.user_roles ur ON r.id = ur.role_id
  WHERE ur.user_id = user_uuid AND ur.is_active = true
  ORDER BY r.created_at DESC
  LIMIT 1;
$$;

-- Create security definer function to check if user is HR manager safely  
CREATE OR REPLACE FUNCTION public.is_hr_manager_safe(user_uuid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
  SELECT public.get_user_role_safe(user_uuid) IN ('Admin', 'HR Manager');
$$;

-- Create security definer function to check if user is admin safely
CREATE OR REPLACE FUNCTION public.is_admin_safe(user_uuid uuid)  
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
  SELECT public.get_user_role_safe(user_uuid) = 'Admin';
$$;

-- Drop existing problematic policies on user_roles
DROP POLICY IF EXISTS "HR can manage user roles" ON public.user_roles;
DROP POLICY IF EXISTS "HR can view all user roles" ON public.user_roles;
DROP POLICY IF EXISTS "Users can view their own roles" ON public.user_roles;

-- Create new safe policies for user_roles
CREATE POLICY "HR can manage user roles safe" 
ON public.user_roles 
FOR ALL 
USING (public.is_hr_manager_safe(auth.uid()));

CREATE POLICY "Users can view their own roles safe" 
ON public.user_roles 
FOR SELECT 
USING (user_id = auth.uid());

-- Update other problematic policies to use safe functions
DROP POLICY IF EXISTS "HR can view all employee records" ON public.employees;
CREATE POLICY "HR can view all employee records safe" 
ON public.employees 
FOR SELECT 
USING (public.is_hr_manager_safe(auth.uid()));

DROP POLICY IF EXISTS "HR can manage employee records" ON public.employees;
CREATE POLICY "HR can manage employee records safe" 
ON public.employees 
FOR ALL 
USING (public.is_hr_manager_safe(auth.uid()));

-- Update user_profiles policies  
DROP POLICY IF EXISTS "HR can view all profiles" ON public.user_profiles;
CREATE POLICY "HR can view all profiles safe" 
ON public.user_profiles 
FOR SELECT 
USING (public.is_hr_manager_safe(auth.uid()));

DROP POLICY IF EXISTS "HR can manage profiles" ON public.user_profiles;
CREATE POLICY "HR can manage profiles safe" 
ON public.user_profiles 
FOR ALL 
USING (public.is_hr_manager_safe(auth.uid()));

-- Update handle_new_user function to not create duplicate profiles
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  admin_role_id UUID;
BEGIN
  -- Get Admin role ID first
  SELECT id INTO admin_role_id 
  FROM public.roles 
  WHERE name = 'Admin' AND is_active = true 
  LIMIT 1;
  
  -- Only create user_profile if it doesn't exist
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = NEW.id) THEN
    INSERT INTO public.user_profiles (
      id,
      first_name,
      last_name,
      personal_email,
      created_at,
      updated_at
    ) VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'first_name', 'User'),
      COALESCE(NEW.raw_user_meta_data->>'last_name', 'Name'),
      NEW.email,
      NOW(),
      NOW()
    );
  END IF;
  
  -- Only assign Admin role if no roles exist for this user and admin role exists
  IF admin_role_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = NEW.id) THEN
    INSERT INTO public.user_roles (
      user_id, 
      role_id,
      created_at,
      updated_at
    ) VALUES (
      NEW.id, 
      admin_role_id,
      NOW(),
      NOW()
    );
  END IF;
  
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Log error but don't fail user creation
    RAISE WARNING 'Error in handle_new_user: %', SQLERRM;
    RETURN NEW;
END;
$function$;