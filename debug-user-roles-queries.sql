-- ============================================================================
-- DEBUG QUERIES: Find User Roles and Admin Users
-- ============================================================================
-- Run these queries in your Supabase SQL Editor to debug the notification issue
-- ============================================================================

-- ============================================================================
-- 1. CHECK IF ROLES TABLE EXISTS AND HAS DATA
-- ============================================================================
-- This query checks if roles exist in the database
SELECT 
    COUNT(*) as total_roles,
    COUNT(CASE WHEN name = 'Admin' THEN 1 END) as admin_roles,
    COUNT(CASE WHEN name ILIKE '%admin%' THEN 1 END) as admin_like_roles
FROM public.roles;

-- List all roles in the database
SELECT 
    id,
    name,
    description,
    is_active,
    created_at
FROM public.roles
ORDER BY name;

-- ============================================================================
-- 2. CHECK RLS POLICIES ON ROLES TABLE
-- ============================================================================
-- Check what RLS policies exist on the roles table
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies
WHERE tablename = 'roles'
ORDER BY policyname;

-- Check if RLS is enabled on roles table
SELECT 
    schemaname,
    tablename,
    rowsecurity as rls_enabled
FROM pg_tables
WHERE tablename = 'roles';

-- ============================================================================
-- 3. FIND ADMIN ROLE ID
-- ============================================================================
-- Find the Admin role (trying multiple approaches)
SELECT 
    id,
    name,
    description,
    is_active
FROM public.roles
WHERE name = 'Admin'
   OR name ILIKE 'admin'
   OR name ILIKE '%admin%'
ORDER BY name;

-- ============================================================================
-- 4. FIND USERS WITH ADMIN ROLE
-- ============================================================================
-- Find all users who have the Admin role
SELECT 
    ur.id as user_role_id,
    ur.user_id,
    ur.role_id,
    ur.is_active as user_role_active,
    r.name as role_name,
    r.id as role_id,
    up.email,
    up.full_name
FROM public.user_roles ur
INNER JOIN public.roles r ON ur.role_id = r.id
LEFT JOIN public.user_profiles up ON ur.user_id = up.id
WHERE r.name = 'Admin'
   OR r.name ILIKE 'admin'
   OR r.name ILIKE '%admin%'
ORDER BY up.email;

-- Alternative: Find admin users using role name directly
SELECT DISTINCT
    ur.user_id,
    r.name as role_name,
    up.email,
    up.full_name,
    ur.is_active as user_role_active
FROM public.user_roles ur
INNER JOIN public.roles r ON ur.role_id = r.id
LEFT JOIN public.user_profiles up ON ur.user_id = up.id
WHERE LOWER(r.name) = 'admin'
  AND ur.is_active = true
  AND (r.is_active IS NULL OR r.is_active = true);

-- ============================================================================
-- 5. COMPREHENSIVE USER-ROLE MAPPING
-- ============================================================================
-- See all user-role relationships
SELECT 
    ur.id as user_role_id,
    ur.user_id,
    ur.role_id,
    ur.is_active as user_role_active,
    ur.created_at as role_assigned_at,
    r.name as role_name,
    r.description as role_description,
    r.is_active as role_active,
    up.email,
    up.full_name,
    up.branch_id
FROM public.user_roles ur
INNER JOIN public.roles r ON ur.role_id = r.id
LEFT JOIN public.user_profiles up ON ur.user_id = up.id
ORDER BY r.name, up.email;

-- ============================================================================
-- 6. CHECK PUSH SUBSCRIPTIONS FOR ADMIN USERS
-- ============================================================================
-- Find push subscriptions for users with Admin role
SELECT 
    ps.id as subscription_id,
    ps.user_id,
    ps.endpoint,
    ps.created_at,
    r.name as user_role,
    up.email,
    up.full_name
FROM public.push_subscriptions ps
INNER JOIN public.user_roles ur ON ps.user_id = ur.user_id
INNER JOIN public.roles r ON ur.role_id = r.id
LEFT JOIN public.user_profiles up ON ps.user_id = up.id
WHERE (r.name = 'Admin' OR r.name ILIKE 'admin')
  AND ur.is_active = true
  AND (r.is_active IS NULL OR r.is_active = true)
ORDER BY up.email;

-- ============================================================================
-- 7. TEST THE EXACT QUERY USED BY THE BACKEND SERVICE
-- ============================================================================
-- This is the exact query pattern used in low-stock-notification-service.ts
-- Run this to see what the backend service would get

-- Step 1: Get all roles (what backend tries first)
SELECT id, name
FROM public.roles
LIMIT 20;

-- Step 2: Find Admin role using ILIKE
SELECT id, name
FROM public.roles
WHERE name ILIKE 'Admin';

-- Step 3: Find Admin role using exact match
SELECT id, name
FROM public.roles
WHERE name = 'Admin';

-- Step 4: Find users with Admin role
SELECT ur.user_id
FROM public.user_roles ur
INNER JOIN public.roles r ON ur.role_id = r.id
WHERE r.name = 'Admin'
  AND ur.is_active = true;

-- ============================================================================
-- 8. CHECK IF SERVICE ROLE KEY IS NEEDED
-- ============================================================================
-- The backend service uses anon key, but RLS requires authenticated users
-- Check if roles table allows anon access
SELECT 
    policyname,
    roles,
    cmd,
    qual
FROM pg_policies
WHERE tablename = 'roles'
  AND 'anon' = ANY(roles);

-- ============================================================================
-- 9. SOLUTION: CREATE A SECURITY DEFINER FUNCTION TO BYPASS RLS
-- ============================================================================
-- This function can be called by the backend service to get admin users
-- It bypasses RLS because it's SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.get_admin_user_ids_for_notifications()
RETURNS TABLE(user_id UUID) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ur.user_id
    FROM public.user_roles ur
    INNER JOIN public.roles r ON ur.role_id = r.id
    WHERE (r.name = 'Admin' OR r.name ILIKE 'admin')
      AND ur.is_active = true
      AND (r.is_active IS NULL OR r.is_active = true);
END;
$$;

-- Grant execute permission to anon role (so backend can call it)
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO anon;
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO authenticated;

-- Test the function
SELECT * FROM public.get_admin_user_ids_for_notifications();

-- ============================================================================
-- 10. ALTERNATIVE: UPDATE RLS POLICY TO ALLOW ANON ACCESS FOR ROLES TABLE
-- ============================================================================
-- If you want the backend service to directly query roles table,
-- you can add a policy that allows anon role to read roles
-- (This is less secure but simpler)

-- First, check current policies
SELECT policyname, roles, cmd FROM pg_policies WHERE tablename = 'roles';

-- Add policy to allow anon to read roles (if needed)
-- Note: This might already exist, check first!
-- CREATE POLICY "Anon can view roles" ON public.roles
--   FOR SELECT TO anon USING (true);

-- ============================================================================
-- 11. QUICK DIAGNOSTIC SUMMARY
-- ============================================================================
-- Run this to get a quick overview of the situation
SELECT 
    'Roles Count' as metric,
    COUNT(*)::text as value
FROM public.roles
UNION ALL
SELECT 
    'Admin Roles Count',
    COUNT(*)::text
FROM public.roles
WHERE name = 'Admin' OR name ILIKE 'admin'
UNION ALL
SELECT 
    'Users with Admin Role',
    COUNT(DISTINCT ur.user_id)::text
FROM public.user_roles ur
INNER JOIN public.roles r ON ur.role_id = r.id
WHERE (r.name = 'Admin' OR r.name ILIKE 'admin')
  AND ur.is_active = true
UNION ALL
SELECT 
    'Admin Users with Push Subscriptions',
    COUNT(DISTINCT ps.user_id)::text
FROM public.push_subscriptions ps
INNER JOIN public.user_roles ur ON ps.user_id = ur.user_id
INNER JOIN public.roles r ON ur.role_id = r.id
WHERE (r.name = 'Admin' OR r.name ILIKE 'admin')
  AND ur.is_active = true;

