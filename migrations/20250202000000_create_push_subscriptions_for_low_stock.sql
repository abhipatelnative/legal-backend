-- Create push_subscriptions table for Web Push notifications (Low Stock Alerts)
-- This table stores browser push notification subscriptions for users

-- Create push_subscriptions table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  device_info JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create index on user_id for faster lookups
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user_id ON public.push_subscriptions(user_id);

-- Create index on endpoint for faster lookups
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_endpoint ON public.push_subscriptions(endpoint);

-- Enable RLS
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist to avoid conflicts
DROP POLICY IF EXISTS "Users can view their own push subscriptions" ON public.push_subscriptions;
DROP POLICY IF EXISTS "Users can insert their own push subscriptions" ON public.push_subscriptions;
DROP POLICY IF EXISTS "Users can update their own push subscriptions" ON public.push_subscriptions;
DROP POLICY IF EXISTS "Users can delete their own push subscriptions" ON public.push_subscriptions;
DROP POLICY IF EXISTS "Admins can view all push subscriptions" ON public.push_subscriptions;
DROP POLICY IF EXISTS "Service role can manage push subscriptions" ON public.push_subscriptions;

-- Users can view their own subscriptions
CREATE POLICY "Users can view their own push subscriptions" 
ON public.push_subscriptions
FOR SELECT 
USING (auth.uid() = user_id);

-- Users can insert their own subscriptions
-- Also allow backend API (using anon key) to insert when user_id is provided
CREATE POLICY "Users can insert their own push subscriptions" 
ON public.push_subscriptions
FOR INSERT 
WITH CHECK (
  -- User inserting their own subscription
  auth.uid() = user_id
  OR
  -- Backend API inserting on behalf of user (anon key with user_id provided)
  (auth.role() = 'anon' AND user_id IS NOT NULL)
  OR
  -- Service role can insert any
  auth.role() = 'service_role'
);

-- Users can update their own subscriptions
-- Also allow backend API (using anon key) to update when user_id matches
CREATE POLICY "Users can update their own push subscriptions" 
ON public.push_subscriptions
FOR UPDATE 
USING (
  -- User updating their own subscription
  auth.uid() = user_id
  OR
  -- Backend API updating on behalf of user (anon key with user_id provided)
  (auth.role() = 'anon' AND user_id IS NOT NULL)
  OR
  -- Service role can update any
  auth.role() = 'service_role'
)
WITH CHECK (
  -- Same conditions for the new row
  auth.uid() = user_id
  OR
  (auth.role() = 'anon' AND user_id IS NOT NULL)
  OR
  auth.role() = 'service_role'
);

-- Users can delete their own subscriptions
CREATE POLICY "Users can delete their own push subscriptions" 
ON public.push_subscriptions
FOR DELETE 
USING (auth.uid() = user_id);

-- Admins can view all push subscriptions (for debugging)
CREATE POLICY "Admins can view all push subscriptions" 
ON public.push_subscriptions
FOR SELECT 
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    INNER JOIN public.roles r ON r.id = ur.role_id
    WHERE ur.user_id = auth.uid() 
    AND ur.is_active = true
    AND r.name = 'Admin'
  )
);

-- Service role can manage all subscriptions (for backend operations)
CREATE POLICY "Service role can manage push subscriptions" 
ON public.push_subscriptions
FOR ALL 
USING (auth.role() = 'service_role');

-- Create a function to insert/update push subscriptions that bypasses RLS
-- This allows the backend API to manage subscriptions on behalf of users
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

-- Create function to get inventory item for notification (bypasses RLS)
CREATE OR REPLACE FUNCTION public.get_inventory_item_for_notification(p_item_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  quantity INTEGER,
  min_threshold INTEGER,
  status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    inv.id,
    inv.name,
    inv.quantity,
    inv.min_threshold,
    inv.status
  FROM public.inventory_items inv
  WHERE inv.id = p_item_id
  AND inv.is_deleted = false;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.get_inventory_item_for_notification TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_item_for_notification TO anon;

-- Add comment to table
COMMENT ON TABLE public.push_subscriptions IS 'Stores browser push notification subscriptions for low stock alerts and other notifications';

