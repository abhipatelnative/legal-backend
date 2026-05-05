-- Create storage bucket for profile pictures
INSERT INTO storage.buckets (id, name, public) VALUES ('profile-pictures', 'profile-pictures', true);

-- Create policies for profile pictures storage
CREATE POLICY "Anyone can view profile pictures" 
ON storage.objects 
FOR SELECT 
USING (bucket_id = 'profile-pictures');

CREATE POLICY "Employees can upload their own profile picture" 
ON storage.objects 
FOR INSERT 
WITH CHECK (
  bucket_id = 'profile-pictures' AND 
  (storage.foldername(name))[1] IN (
    SELECT e.id::text 
    FROM public.employees e 
    WHERE e.user_id = auth.uid()
  )
);

CREATE POLICY "Employees can update their own profile picture" 
ON storage.objects 
FOR UPDATE 
USING (
  bucket_id = 'profile-pictures' AND 
  (storage.foldername(name))[1] IN (
    SELECT e.id::text 
    FROM public.employees e 
    WHERE e.user_id = auth.uid()
  )
);

CREATE POLICY "HR can manage all profile pictures" 
ON storage.objects 
FOR ALL 
USING (
  bucket_id = 'profile-pictures' AND 
  EXISTS (
    SELECT 1 FROM public.user_roles ur 
    JOIN public.roles r ON ur.role_id = r.id 
    WHERE ur.user_id = auth.uid() 
    AND r.name IN ('HR Manager', 'Admin') 
    AND ur.is_active = true
  )
);