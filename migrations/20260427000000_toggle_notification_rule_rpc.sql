-- ============================================================================
-- Migration: Create RPC to toggle notification auto-rule status
-- ============================================================================

CREATE OR REPLACE FUNCTION public.toggle_notification_auto_rule_status(
    p_rule_id UUID,
    p_is_active BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER -- Runs with owner privileges to bypass RLS if necessary
AS $$
BEGIN
    UPDATE public.notification_auto_rules
    SET 
        is_active = p_is_active,
        updated_at = NOW()
    WHERE id = p_rule_id;
END;
$$;

-- Grant access to authenticated users
GRANT EXECUTE ON FUNCTION public.toggle_notification_auto_rule_status(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_notification_auto_rule_status(UUID, BOOLEAN) TO service_role;
