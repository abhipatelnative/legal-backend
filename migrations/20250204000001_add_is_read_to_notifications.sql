-- ============================================================================
-- Migration: Add is_read column to notifications table
-- ============================================================================
-- This migration adds the missing is_read boolean column that the frontend
-- and backend expect for tracking read/unread notification status
-- ============================================================================

-- Add is_read column if it doesn't exist
DO $$ 
BEGIN
    -- Check if column exists, if not, add it
    IF NOT EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = 'notifications' 
        AND column_name = 'is_read'
    ) THEN
        -- Add the column with default value of false
        ALTER TABLE public.notifications 
        ADD COLUMN is_read BOOLEAN DEFAULT false NOT NULL;
        
        -- Update existing notifications: if read_at is NULL, is_read should be false
        -- If read_at is set, is_read should be true
        UPDATE public.notifications 
        SET is_read = CASE 
            WHEN read_at IS NULL THEN false 
            ELSE true 
        END;
        
        RAISE NOTICE 'Column is_read added to notifications table';
    ELSE
        RAISE NOTICE 'Column is_read already exists in notifications table';
    END IF;
END $$;

-- Create index on is_read for better query performance
CREATE INDEX IF NOT EXISTS idx_notifications_is_read 
ON public.notifications(user_id, is_read) 
WHERE is_deleted = false;

-- Add comment
COMMENT ON COLUMN public.notifications.is_read IS 
'Boolean flag indicating if the notification has been read by the user. Defaults to false for new notifications.';

