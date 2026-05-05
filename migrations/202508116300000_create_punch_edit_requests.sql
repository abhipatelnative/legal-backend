-- Create punch edit requests table for employee punch corrections
CREATE TABLE IF NOT EXISTS public.punch_edit_requests (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    punch_record_id UUID NOT NULL REFERENCES public.punch_records(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    original_time VARCHAR(10) NOT NULL,
    requested_time VARCHAR(10) NOT NULL,
    reason TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    reviewed_by UUID REFERENCES public.user_profiles(id),
    reviewed_at TIMESTAMP WITH TIME ZONE,
    review_comments TEXT,
    is_active BOOLEAN DEFAULT true,
    is_deleted BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES public.user_profiles(id),
    updated_by UUID REFERENCES public.user_profiles(id)
);

-- Add the new column to existing table if it doesn't exist
ALTER TABLE public.punch_edit_requests 
ADD COLUMN IF NOT EXISTS punch_record_id UUID REFERENCES public.punch_records(id) ON DELETE CASCADE;

ALTER TABLE public.punch_edit_requests 
ADD COLUMN IF NOT EXISTS original_time VARCHAR(10);

ALTER TABLE public.punch_edit_requests 
ADD COLUMN IF NOT EXISTS requested_time VARCHAR(10);

-- Add indexes for better performance
CREATE INDEX IF NOT EXISTS idx_punch_edit_requests_employee_id ON public.punch_edit_requests(employee_id);
CREATE INDEX IF NOT EXISTS idx_punch_edit_requests_punch_record_id ON public.punch_edit_requests(punch_record_id);
CREATE INDEX IF NOT EXISTS idx_punch_edit_requests_date ON public.punch_edit_requests(date);
CREATE INDEX IF NOT EXISTS idx_punch_edit_requests_status ON public.punch_edit_requests(status);
CREATE INDEX IF NOT EXISTS idx_punch_edit_requests_active ON public.punch_edit_requests(is_active, is_deleted);

-- Add RLS policies
ALTER TABLE public.punch_edit_requests ENABLE ROW LEVEL SECURITY;

-- Employees can view and create their own requests
CREATE POLICY "Employees can view own punch edit requests" ON public.punch_edit_requests
    FOR SELECT USING (
        employee_id IN (
            SELECT id FROM public.employees 
            WHERE user_id = auth.uid()
        )
    );

CREATE POLICY "Employees can create own punch edit requests" ON public.punch_edit_requests
    FOR INSERT WITH CHECK (
        employee_id IN (
            SELECT id FROM public.employees 
            WHERE user_id = auth.uid()
        )
    );

-- HR and Admin can view and update all requests
CREATE POLICY "HR can manage all punch edit requests" ON public.punch_edit_requests
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.user_profiles up
            JOIN public.user_roles ur ON up.id = ur.user_id
            JOIN public.roles r ON ur.role_id = r.id
            WHERE up.id = auth.uid()
            AND r.name IN ('HR Manager', 'Admin')
            AND ur.is_active = true
            AND ur.is_deleted = false
        )
    );

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION update_punch_edit_requests_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_punch_edit_requests_updated_at
    BEFORE UPDATE ON public.punch_edit_requests
    FOR EACH ROW
    EXECUTE FUNCTION update_punch_edit_requests_updated_at();

-- Add comments
COMMENT ON TABLE public.punch_edit_requests IS 'Stores employee requests to edit their punch records';
COMMENT ON COLUMN public.punch_edit_requests.original_time IS 'Original punch time (HH:MM format)';
COMMENT ON COLUMN public.punch_edit_requests.requested_time IS 'Requested new punch time (HH:MM format)';