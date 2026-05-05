-- ============================================================================
-- Migration: Add SECURITY DEFINER function to insert notifications
-- ============================================================================
-- This function bypasses RLS and can be called by the backend service
-- using the anon key to insert notifications for users
-- ============================================================================

-- Drop the function if it exists (in case return type changed)
DROP FUNCTION IF EXISTS public.insert_notifications_for_users(JSONB);

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
            data JSONB
        )
    LOOP
        INSERT INTO public.notifications (
            user_id,
            title,
            message,
            type,
            action_url,
            data,
            is_active,
            is_deleted
        )
        VALUES (
            notification_record.user_id,
            notification_record.title,
            notification_record.message,
            COALESCE(notification_record.type, 'info'),
            notification_record.action_url,
            notification_record.data,
            true,
            false
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
-- This allows the backend service (using anon key) to call this function
GRANT EXECUTE ON FUNCTION public.insert_notifications_for_users(JSONB) TO anon;
GRANT EXECUTE ON FUNCTION public.insert_notifications_for_users(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.insert_notifications_for_users(JSONB) TO service_role;

-- Add comment for documentation
COMMENT ON FUNCTION public.insert_notifications_for_users(JSONB) IS 
'Inserts multiple notifications for different users. This function uses SECURITY DEFINER to bypass RLS, allowing backend services to create notifications for any user. Accepts a JSONB array of notification objects.';

