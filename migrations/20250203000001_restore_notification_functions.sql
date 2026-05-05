-- ============================================================================
-- Migration: Restore notification-related database functions
-- ============================================================================
-- This migration restores the functions needed for low stock notifications
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
        -- Admin roles
        r.name = 'Admin' 
        OR r.name ILIKE 'admin'
        OR r.name ILIKE '%admin%'
        -- HR roles
        OR r.name = 'HR Manager'
        OR r.name ILIKE 'hr manager'
        OR r.name = 'HR'
        OR r.name ILIKE 'hr'
        OR r.name ILIKE 'human resources'
        OR r.name ILIKE '%hr%'
        -- Manager roles
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

-- Grant execute permission to anon and authenticated roles
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO anon;
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_user_ids_for_notifications() TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION public.get_admin_user_ids_for_notifications() IS 
'Returns all user IDs that have Admin, HR Manager, Manager, or HR roles. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to query users for low stock notifications.';

-- Create the function to insert notifications
CREATE OR REPLACE FUNCTION public.insert_notifications_for_users(
    p_notifications JSONB
)
RETURNS TABLE(id UUID, user_id UUID, title VARCHAR, created_at TIMESTAMPTZ) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    notification_record RECORD;
    inserted_id UUID;
    inserted_user_id UUID;
    inserted_title VARCHAR(255);
    inserted_created_at TIMESTAMPTZ;
BEGIN
    -- Insert each notification from the JSONB array
    FOR notification_record IN 
        SELECT * FROM jsonb_to_recordset(p_notifications) AS x(
            user_id UUID,
            title VARCHAR(255),
            message TEXT,
            type VARCHAR(50),
            action_url VARCHAR(500),
            data JSONB,
            reference_type VARCHAR(50),
            branch_id UUID
        )
    LOOP
        INSERT INTO public.notifications (
            user_id,
            title,
            message,
            type,
            action_url,
            data,
            reference_type,
            branch_id,
            is_active,
            is_deleted,
            is_read
        )
        VALUES (
            notification_record.user_id,
            notification_record.title,
            notification_record.message,
            COALESCE(notification_record.type, 'info'),
            notification_record.action_url,
            notification_record.data,
            COALESCE(notification_record.reference_type, 'low_stock'),
            notification_record.branch_id,
            true,
            false,
            false  -- All new notifications are unread by default
        )
        RETURNING 
            notifications.id,
            notifications.user_id,
            notifications.title,
            notifications.created_at
        INTO 
            inserted_id,
            inserted_user_id,
            inserted_title,
            inserted_created_at;
        
        -- Return the inserted notification
        id := inserted_id;
        user_id := inserted_user_id;
        title := inserted_title;
        created_at := inserted_created_at;
        RETURN NEXT;
    END LOOP;
    
    RETURN;
END;
$$;

-- Grant execute permission to anon and authenticated roles
GRANT EXECUTE ON FUNCTION public.insert_notifications_for_users(JSONB) TO anon;
GRANT EXECUTE ON FUNCTION public.insert_notifications_for_users(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.insert_notifications_for_users(JSONB) TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION public.insert_notifications_for_users(JSONB) IS 
'Inserts multiple notifications for different users. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to create notifications for any user. Accepts a JSONB array of notification objects.';

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
GRANT EXECUTE ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) TO anon;
GRANT EXECUTE ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION public.get_push_subscriptions_for_admin_users(UUID[]) IS 
'Returns push subscriptions for the provided admin user IDs. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to query push subscriptions for any user.';

-- Create or replace the function to upsert push subscriptions
CREATE OR REPLACE FUNCTION public.upsert_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT,
  p_user_id UUID,
  p_device_info JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  -- Check if subscription exists
  SELECT id INTO v_id
  FROM public.push_subscriptions
  WHERE endpoint = p_endpoint;
  
  IF v_id IS NOT NULL THEN
    -- Update existing subscription
    UPDATE public.push_subscriptions
    SET 
      p256dh = p_p256dh,
      auth = p_auth,
      user_id = COALESCE(p_user_id, user_id),
      device_info = COALESCE(p_device_info, device_info),
      updated_at = NOW()
    WHERE endpoint = p_endpoint
    RETURNING id INTO v_id;
  ELSE
    -- Insert new subscription
    INSERT INTO public.push_subscriptions (
      endpoint,
      p256dh,
      auth,
      user_id,
      device_info
    ) VALUES (
      p_endpoint,
      p_p256dh,
      p_auth,
      p_user_id,
      p_device_info
    )
    RETURNING id INTO v_id;
  END IF;
  
  RETURN v_id;
END;
$$;

-- Grant execute permission to authenticated users and anon role
GRANT EXECUTE ON FUNCTION public.upsert_push_subscription TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_push_subscription TO anon;
GRANT EXECUTE ON FUNCTION public.upsert_push_subscription TO service_role;

