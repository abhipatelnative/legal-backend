
-- Phase 2: User Management & Security

-- 16. user_profiles table (extending auth.users, not replacing it)
CREATE TABLE public.user_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  first_name VARCHAR(100) NOT NULL,
  middle_name VARCHAR(100),
  last_name VARCHAR(100) NOT NULL,
  personal_email VARCHAR(255),
  phone VARCHAR(20),
  date_of_birth DATE,
  gender gender_type,
  city VARCHAR(100),
  state VARCHAR(100),
  address TEXT,
  pincode VARCHAR(20),
  biometric_code VARCHAR(255),
  last_login_ip INET,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_personal_email CHECK (personal_email IS NULL OR personal_email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- 17. employees table
CREATE TABLE public.employees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  employee_code VARCHAR(50) UNIQUE NOT NULL,
  company_email VARCHAR(255) UNIQUE NOT NULL,
  work_phone VARCHAR(20),
  emergency_contact_name VARCHAR(255),
  emergency_contact_phone VARCHAR(20),
  department_id UUID REFERENCES public.departments(id) ON DELETE SET NULL,
  designation_id UUID REFERENCES public.designations(id) ON DELETE SET NULL,
  hire_date DATE NOT NULL,
  employment_status employment_status DEFAULT 'active',
  onboarding_status onboarding_status DEFAULT 'pending',
  profile_picture_url VARCHAR(500),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_company_email CHECK (company_email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  CONSTRAINT valid_hire_date CHECK (hire_date <= CURRENT_DATE)
);

-- 18. employee_shifts table
CREATE TABLE public.employee_shifts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  shift_id UUID NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  work_week_id UUID NOT NULL REFERENCES public.work_weeks(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Ensure unique active shift assignment per employee (handled by index below)
  CONSTRAINT unique_employee_shift UNIQUE(employee_id, shift_id, work_week_id)
);

-- 19. employee_bank_details table
CREATE TABLE public.employee_bank_details (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  bank_name VARCHAR(100) NOT NULL,
  account_holder_name VARCHAR(255) NOT NULL,
  account_number VARCHAR(100) NOT NULL,
  ifsc_code VARCHAR(20) NOT NULL,
  branch_name VARCHAR(100),
  is_primary BOOLEAN DEFAULT true,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_ifsc_code CHECK (ifsc_code ~* '^[A-Z]{4}[0][A-Z0-9]{6}$'),
  -- Ensure only one primary bank account per employee (handled by index below)
  CONSTRAINT unique_employee_bank UNIQUE(employee_id, account_number)
);

-- 20. employee_documents table
CREATE TABLE public.employee_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  contract_id UUID, -- Will be linked after contracts table is created
  document_type VARCHAR(50) NOT NULL,
  file_url TEXT NOT NULL,
  uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  verified_by UUID REFERENCES auth.users(id),
  verified_at TIMESTAMP WITH TIME ZONE,
  is_verified BOOLEAN DEFAULT false,
  remarks TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 21. user_roles table
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  assigned_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  assigned_by UUID REFERENCES auth.users(id),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Ensure unique user-role combinations (handled by index below)
  CONSTRAINT unique_user_role UNIQUE(user_id, role_id)
);

-- 22. user_contract_acceptance table
CREATE TABLE public.user_contract_acceptance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  contract_id UUID, -- Will be linked after contracts table is created
  accepted_at TIMESTAMP WITH TIME ZONE,
  ip_address INET,
  user_agent TEXT,
  is_accepted BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 23. user_permissions table (custom permissions override)
CREATE TABLE public.user_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
  can_view BOOLEAN DEFAULT false,
  can_add BOOLEAN DEFAULT false,
  can_edit BOOLEAN DEFAULT false,
  can_delete BOOLEAN DEFAULT false,
  assigned_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  assigned_by UUID REFERENCES auth.users(id),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Ensure unique user-permission combinations (handled by index below)
  CONSTRAINT unique_user_permission UNIQUE(user_id, permission_id)
);

-- Add foreign key constraint for department head after employees table exists
ALTER TABLE public.departments 
ADD CONSTRAINT fk_departments_head_employee 
FOREIGN KEY (head_employee_id) REFERENCES public.employees(id) ON DELETE SET NULL;

-- Create indexes for better performance
CREATE INDEX idx_user_profiles_user_id ON public.user_profiles(id);
CREATE INDEX idx_employees_user_id ON public.employees(user_id);
CREATE INDEX idx_employees_code ON public.employees(employee_code);
CREATE INDEX idx_employees_company_email ON public.employees(company_email);
CREATE INDEX idx_employees_department ON public.employees(department_id);
CREATE INDEX idx_employees_designation ON public.employees(designation_id);
CREATE INDEX idx_employees_status ON public.employees(employment_status, is_active, is_deleted);
CREATE INDEX idx_employee_shifts_employee ON public.employee_shifts(employee_id);
CREATE INDEX idx_employee_shifts_status ON public.employee_shifts(is_active, is_deleted);
CREATE INDEX idx_employee_bank_details_employee ON public.employee_bank_details(employee_id);
CREATE UNIQUE INDEX idx_employee_bank_details_primary ON public.employee_bank_details(employee_id) WHERE is_primary = true AND is_deleted = false;
CREATE UNIQUE INDEX idx_employee_shifts_unique_active ON public.employee_shifts(employee_id) WHERE is_active = true AND is_deleted = false;
CREATE UNIQUE INDEX idx_user_roles_active ON public.user_roles(user_id, role_id) WHERE is_deleted = false;
CREATE UNIQUE INDEX idx_user_permissions_active ON public.user_permissions(user_id, permission_id) WHERE is_deleted = false;
CREATE INDEX idx_employee_documents_employee ON public.employee_documents(employee_id);
CREATE INDEX idx_employee_documents_type ON public.employee_documents(document_type);
CREATE INDEX idx_employee_documents_verified ON public.employee_documents(is_verified);
CREATE INDEX idx_user_roles_user ON public.user_roles(user_id);
CREATE INDEX idx_user_roles_role ON public.user_roles(role_id);
CREATE INDEX idx_user_permissions_user ON public.user_permissions(user_id);
CREATE INDEX idx_user_permissions_permission ON public.user_permissions(permission_id);

-- Create triggers for updated_at columns
CREATE TRIGGER update_user_profiles_updated_at BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_employees_updated_at BEFORE UPDATE ON public.employees FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_employee_shifts_updated_at BEFORE UPDATE ON public.employee_shifts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_employee_bank_details_updated_at BEFORE UPDATE ON public.employee_bank_details FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_employee_documents_updated_at BEFORE UPDATE ON public.employee_documents FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_user_roles_updated_at BEFORE UPDATE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_user_contract_acceptance_updated_at BEFORE UPDATE ON public.user_contract_acceptance FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_user_permissions_updated_at BEFORE UPDATE ON public.user_permissions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Enable Row Level Security on all tables
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_bank_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_contract_acceptance ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_permissions ENABLE ROW LEVEL SECURITY;

-- RLS Policies for user_profiles
CREATE POLICY "Users can view their own profile" ON public.user_profiles
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update their own profile" ON public.user_profiles
  FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "HR can view all profiles" ON public.user_profiles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for employees
CREATE POLICY "Users can view their own employee record" ON public.employees
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "HR can view all employee records" ON public.employees
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

CREATE POLICY "HR can manage employee records" ON public.employees
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for employee_bank_details
CREATE POLICY "Users can view their own bank details" ON public.employee_bank_details
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can view all bank details" ON public.employee_bank_details
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for employee_documents
CREATE POLICY "Users can view their own documents" ON public.employee_documents
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can view all documents" ON public.employee_documents
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for user_roles (Admin only)
CREATE POLICY "Admin can manage user roles" ON public.user_roles
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name = 'Admin' 
      AND ur.is_active = true
    )
  );

-- RLS Policies for user_permissions (Admin only)
CREATE POLICY "Admin can manage user permissions" ON public.user_permissions
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name = 'Admin' 
      AND ur.is_active = true
    )
  );
