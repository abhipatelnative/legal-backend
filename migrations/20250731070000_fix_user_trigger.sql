-- Drop the problematic policies
DROP POLICY IF EXISTS "Admin can upload company logos" ON storage.objects;
DROP POLICY IF EXISTS "Admin can update company logos" ON storage.objects;

-- Create new policies using security definer functions to avoid recursion
CREATE POLICY "Admin can upload company logos" 
ON storage.objects 
FOR INSERT 
WITH CHECK (bucket_id = 'company-logos' AND is_admin());

CREATE POLICY "Admin can update company logos" 
ON storage.objects 
FOR UPDATE 
USING (bucket_id = 'company-logos' AND is_admin());