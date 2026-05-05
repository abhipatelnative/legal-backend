-- ============================================================================
-- Migration: Add SECURITY DEFINER function to get admin user IDs
-- ============================================================================
-- This function bypasses RLS and can be called by the backend service
-- using the anon key to get admin user IDs for notifications
-- ============================================================================

-- Create or replace the function to get admin, HR Manager, and Manager user IDs
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
    WHERE (
        r.name = 'Admin' 
        OR r.name ILIKE 'admin'
        OR r.name = 'HR Manager'
        OR r.name ILIKE 'hr manager'
        OR r.name = 'Manager'
        OR r.name ILIKE 'manager'
    )
      AND ur.is_active = true
      AND ur.is_deleted = false
      AND (r.is_active IS NULL OR r.is_active = true)
      AND (r.is_deleted IS NULL OR r.is_deleted = false);
END;
$$;

-- Grant execute permission to anon and authenticated roles
-- This allows the backend service (using anon key) to call this function
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO anon;
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION public.get_admin_user_ids_for_notifications() IS 
'Returns all user IDs that have Admin, HR Manager, or Manager roles. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to query users for low stock notifications.';

