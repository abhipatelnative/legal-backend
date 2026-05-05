-- ============================================================================
-- Migration: Remove notification-related database functions and objects
-- ============================================================================
-- This migration removes all notification-related functions and can optionally
-- drop tables if needed
-- ============================================================================

-- Drop notification-related functions
DROP FUNCTION IF EXISTS public.get_admin_user_ids_for_notifications();
DROP FUNCTION IF EXISTS public.insert_notifications_for_users(JSONB);
DROP FUNCTION IF EXISTS public.get_push_subscriptions_for_admin_users(UUID[]);
DROP FUNCTION IF EXISTS public.upsert_push_subscription(TEXT, TEXT, TEXT, UUID, JSONB);

-- Optional: Drop notification tables (uncomment if you want to remove tables)
-- DROP TABLE IF EXISTS public.push_subscriptions CASCADE;
-- DROP TABLE IF EXISTS public.notifications CASCADE;

-- Note: If you want to keep the tables but just remove the functions,
-- comment out the DROP TABLE statements above.

