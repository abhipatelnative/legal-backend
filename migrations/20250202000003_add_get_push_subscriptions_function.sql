-- ============================================================================
-- Migration: Add SECURITY DEFINER function to get push subscriptions for admin users
-- ============================================================================
-- This function bypasses RLS and can be called by the backend service
-- using the anon key to get push subscriptions for admin users
-- ============================================================================

-- Drop the function if it exists (in case return type changed)
DROP FUNCTION IF EXISTS public.get_push_subscriptions_for_admin_users(UUID[]);

-- Create the function to get push subscriptions for admin users
CREATE OR REPLACE FUNCTION public.get_push_subscriptions_for_admin_users(
    p_admin_user_ids UUID[]
)
RETURNS TABLE(
    id UUID,
    user_id UUID,
    endpoint TEXT,
    p256dh TEXT,
    auth TEXT,
    created_at TIMESTAMPTZ
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ps.id,
        ps.user_id,
        ps.endpoint,
        ps.p256dh,
        ps.auth,
        ps.created_at
    FROM public.push_subscriptions ps
    WHERE ps.user_id = ANY(p_admin_user_ids);
END;
$$;

-- Grant execute permission to anon and authenticated roles
-- This allows the backend service (using anon key) to call this function
GRANT EXECUTE ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) TO anon;
GRANT EXECUTE ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) IS 
'Returns push subscriptions for the provided admin user IDs. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to query push subscriptions for any user. Handles both column structures: separate p256dh/auth columns or keys JSONB.';

