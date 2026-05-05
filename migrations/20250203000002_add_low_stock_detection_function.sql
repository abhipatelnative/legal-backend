-- ============================================================================
-- Migration: Add function to detect and log low stock events
-- ============================================================================
-- This function can be called from triggers or backend to check low stock
-- ============================================================================

-- Create a function to check if an item is at low stock
CREATE OR REPLACE FUNCTION public.check_low_stock_after_issue()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_quantity INTEGER;
  min_threshold INTEGER;
  item_name TEXT;
  item_branch_id UUID;
BEGIN
  -- Get current inventory item details
  SELECT 
    inv.quantity,
    inv.min_threshold,
    inv.name,
    inv.branch_id
  INTO 
    current_quantity,
    min_threshold,
    item_name,
    item_branch_id
  FROM public.inventory_items inv
  WHERE inv.id = NEW.inventory_item_id;

  -- Check if quantity is at or below threshold
  IF current_quantity <= min_threshold THEN
    -- Log the low stock event (this can be used by backend to send notifications)
    -- The actual notification sending will be handled by the backend API
    -- This function just ensures the data is available
    RAISE NOTICE 'Low stock detected for item %: quantity % <= threshold %', 
      item_name, current_quantity, min_threshold;
  END IF;

  RETURN NEW;
END;
$$;

-- Add comment
COMMENT ON FUNCTION public.check_low_stock_after_issue() IS 
'Trigger function that checks for low stock after an inventory item is issued. This function logs low stock events but does not create notifications directly - notifications are handled by the backend API.';

-- Note: The actual trigger will be created separately if needed
-- For now, the frontend calls the backend API directly after creating an issue

