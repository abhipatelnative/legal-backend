-- Create storage bucket for employee documents
INSERT INTO storage.buckets (id, name, public) VALUES ('employee-documents', 'employee-documents', false);

-- Create policies for employee documents storage
CREATE POLICY "Employees can view their own documents" 
ON storage.objects 
FOR SELECT 
USING (
  bucket_id = 'employee-documents' AND 
  (storage.foldername(name))[1] IN (
    SELECT e.id::text 
    FROM public.employees e 
    WHERE e.user_id = auth.uid()
  )
);

CREATE POLICY "Employees can upload their own documents" 
ON storage.objects 
FOR INSERT 
WITH CHECK (
  bucket_id = 'employee-documents' AND 
  (storage.foldername(name))[1] IN (
    SELECT e.id::text 
    FROM public.employees e 
    WHERE e.user_id = auth.uid()
  )
);

CREATE POLICY "HR can view all employee documents" 
ON storage.objects 
FOR SELECT 
USING (
  bucket_id = 'employee-documents' AND 
  EXISTS (
    SELECT 1 FROM public.user_roles ur 
    JOIN public.roles r ON ur.role_id = r.id 
    WHERE ur.user_id = auth.uid() 
    AND r.name IN ('HR Manager', 'Admin') 
    AND ur.is_active = true
  )
);

CREATE POLICY "HR can manage all employee documents" 
ON storage.objects 
FOR ALL 
USING (
  bucket_id = 'employee-documents' AND 
  EXISTS (
    SELECT 1 FROM public.user_roles ur 
    JOIN public.roles r ON ur.role_id = r.id 
    WHERE ur.user_id = auth.uid() 
    AND r.name IN ('HR Manager', 'Admin') 
    AND ur.is_active = true
  )
);
