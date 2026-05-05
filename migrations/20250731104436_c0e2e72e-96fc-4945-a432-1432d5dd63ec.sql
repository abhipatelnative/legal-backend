-- Fix foreign key constraint in user_profiles table
-- The constraint should reference auth.users, not a non-existent users table

-- Drop the existing foreign key constraint
ALTER TABLE public.user_profiles 
DROP CONSTRAINT IF EXISTS user_profiles_id_fkey;

-- Add the correct foreign key constraint referencing auth.users
ALTER TABLE public.user_profiles 
ADD CONSTRAINT user_profiles_id_fkey 
FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;