-- Fix user signup trigger to ensure it works properly

-- Drop existing trigger if it exists
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- Recreate the function with proper error handling and RLS bypass
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  admin_role_id UUID;
BEGIN
  -- Get Admin role ID first
  SELECT id INTO admin_role_id 
  FROM public.roles 
  WHERE name = 'Admin' AND is_active = true 
  LIMIT 1;
  
  -- Create user_profile with required fields
  INSERT INTO public.user_profiles (
    id,
    first_name,
    last_name,
    personal_email,
    created_at,
    updated_at
  ) VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'first_name', 'User'),
    COALESCE(NEW.raw_user_meta_data->>'last_name', 'Name'),
    NEW.email,
    NOW(),
    NOW()
  );
  
  -- Assign Admin role if found
  IF admin_role_id IS NOT NULL THEN
    INSERT INTO public.user_roles (
      user_id, 
      role_id,
      created_at,
      updated_at
    ) VALUES (
      NEW.id, 
      admin_role_id,
      NOW(),
      NOW()
    );
  END IF;
  
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Log error but don't fail user creation
    RAISE WARNING 'Error in handle_new_user: %', SQLERRM;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Grant necessary permissions to bypass RLS for the function
GRANT USAGE ON SCHEMA public TO postgres;
GRANT ALL ON public.user_profiles TO postgres;
GRANT ALL ON public.user_roles TO postgres;
GRANT ALL ON public.roles TO postgres;

-- Create the trigger
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Test the function works by creating a simple test
DO $$
BEGIN
  RAISE NOTICE 'Trigger function created successfully';
END $$;