-- Function to create storage bucket if it doesn't exist
CREATE OR REPLACE FUNCTION public.create_storage_bucket_if_not_exists()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Check if bucket exists
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'employee-documents') THEN
    -- Create the bucket
    INSERT INTO storage.buckets (id, name, public) VALUES ('employee-documents', 'employee-documents', false);
    
    -- Create policies
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
    
    RETURN TRUE;
  END IF;
  
  RETURN FALSE;
END;
$$;


CREATE OR REPLACE FUNCTION update_used_leave_days(
    p_employee_id UUID,
    p_leave_type_id UUID,
    p_year INT,
    p_days_to_add NUMERIC
)
RETURNS VOID AS $$
BEGIN
    UPDATE public.leave_balances
    SET used_days = used_days + p_days_to_add
    WHERE
        employee_id = p_employee_id AND
        leave_type_id = p_leave_type_id AND
        year = p_year;
END;
$$ LANGUAGE plpgsql;