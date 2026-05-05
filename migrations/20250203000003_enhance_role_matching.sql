-- ============================================================================
-- Migration: Enhance role matching for notifications
-- ============================================================================
-- This migration updates the function to be more flexible with role name matching
-- to ensure HR and Manager roles are properly included
-- ============================================================================

-- Update the function to include more flexible role matching
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
        -- Admin roles (case-insensitive, partial match)
        r.name = 'Admin' 
        OR r.name ILIKE 'admin'
        OR r.name ILIKE '%admin%'
        -- HR roles (case-insensitive, partial match)
        OR r.name = 'HR Manager'
        OR r.name ILIKE 'hr manager'
        OR r.name = 'HR'
        OR r.name ILIKE 'hr'
        OR r.name ILIKE 'human resources'
        OR r.name ILIKE '%hr%'
        -- Manager roles (case-insensitive, partial match)
        OR r.name = 'Manager'
        OR r.name ILIKE 'manager'
        OR r.name ILIKE '%manager%'
    )
      AND ur.is_active = true
      AND ur.is_deleted = false
      AND (r.is_active IS NULL OR r.is_active = true)
      AND (r.is_deleted IS NULL OR r.is_deleted = false);
END;
$$;

-- Update comment
COMMENT ON FUNCTION public.get_admin_user_ids_for_notifications() IS 
'Returns all user IDs that have Admin, HR Manager, Manager, or HR roles. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to query users for low stock notifications. Includes flexible case-insensitive and partial matching for role names to ensure HR and Manager roles are properly included.';

