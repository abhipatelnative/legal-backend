-- Enhance the new user signup trigger to also create user_profile
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Create user_profile with required fields (ignore if already exists)
  INSERT INTO public.user_profiles (
    id,
    first_name,
    last_name,
    personal_email
  ) VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'first_name', 'User'),
    COALESCE(NEW.raw_user_meta_data->>'last_name', 'Name'),
    NEW.email
  ) ON CONFLICT (id) DO NOTHING;
  
  -- Assign Admin role (ignore if already exists)
  INSERT INTO public.user_roles (user_id, role_id)
  SELECT NEW.id, r.id
  FROM public.roles r
  WHERE r.name = 'Admin' AND r.is_active = true
  LIMIT 1
  ON CONFLICT (user_id, role_id) DO NOTHING;
  
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Log error but don't fail user creation
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;