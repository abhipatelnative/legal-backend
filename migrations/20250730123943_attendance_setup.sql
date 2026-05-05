
-- Phase 3: Contract Management System

-- 24. contract_groups table
CREATE TABLE public.contract_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  start_date DATE NOT NULL,
  end_date DATE,
  status contract_status DEFAULT 'active',
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_contract_group_dates CHECK (end_date IS NULL OR end_date >= start_date)
);

-- 25. contract_types table
CREATE TABLE public.contract_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL UNIQUE,
  code VARCHAR(20) UNIQUE NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 26. contract_type_required_documents table
CREATE TABLE public.contract_type_required_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_type_id UUID NOT NULL REFERENCES public.contract_types(id) ON DELETE CASCADE,
  document_type VARCHAR(50) NOT NULL,
  is_mandatory BOOLEAN DEFAULT true,
  remarks TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Ensure unique document type per contract type (handled by index below)
  CONSTRAINT unique_contract_type_document UNIQUE(contract_type_id, document_type)
);

-- 27. contract_templates table
CREATE TABLE public.contract_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  contract_type_id UUID NOT NULL REFERENCES public.contract_types(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  variables JSONB,
  version INTEGER DEFAULT 1,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_version CHECK (version > 0)
);

-- 28. contracts table
CREATE TABLE public.contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  contract_group_id UUID REFERENCES public.contract_groups(id) ON DELETE SET NULL,
  contract_type_id UUID NOT NULL REFERENCES public.contract_types(id) ON DELETE RESTRICT,
  contract_template_id UUID REFERENCES public.contract_templates(id) ON DELETE SET NULL,
  start_date DATE NOT NULL,
  end_date DATE,
  basic_salary DECIMAL(15,2) NOT NULL,
  work_week_id UUID REFERENCES public.work_weeks(id) ON DELETE SET NULL,
  overtime_allowed BOOLEAN DEFAULT false,
  overtime_rate DECIMAL(5,2),
  probation_period INTEGER, -- in months
  notice_period INTEGER, -- in days
  status contract_status DEFAULT 'draft',
  version INTEGER DEFAULT 1 NOT NULL,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_contract_dates CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT positive_basic_salary CHECK (basic_salary > 0),
  CONSTRAINT positive_overtime_rate CHECK (overtime_rate IS NULL OR overtime_rate > 0),
  CONSTRAINT positive_probation_period CHECK (probation_period IS NULL OR probation_period > 0),
  CONSTRAINT positive_notice_period CHECK (notice_period IS NULL OR notice_period > 0),
  CONSTRAINT positive_version CHECK (version > 0)
);

-- 29. contract_revisions table
CREATE TABLE public.contract_revisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id UUID NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  revision_date DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_date DATE NOT NULL,
  changes JSONB NOT NULL,
  reason TEXT,
  approved_by UUID REFERENCES auth.users(id),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_revision_dates CHECK (effective_date >= revision_date)
);

-- 30. contract_holidays table
CREATE TABLE public.contract_holidays (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id UUID NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  holiday_id UUID NOT NULL REFERENCES public.holidays(id) ON DELETE CASCADE,
  is_applicable BOOLEAN DEFAULT true,
  remarks TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Ensure unique contract-holiday combinations (handled by index below)
  CONSTRAINT unique_contract_holiday UNIQUE(contract_id, holiday_id)
);

-- 31. contract_leaves table
CREATE TABLE public.contract_leaves (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id UUID NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  leave_type_id UUID NOT NULL REFERENCES public.leave_types(id) ON DELETE CASCADE,
  days_allowed DECIMAL(10,2) NOT NULL,
  carry_forward BOOLEAN DEFAULT false,
  encashable BOOLEAN DEFAULT false,
  salary_payable BOOLEAN DEFAULT true,
  notes TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_days_allowed CHECK (days_allowed > 0),
  -- Ensure unique contract-leave_type combinations (handled by index below)
  CONSTRAINT unique_contract_leave_type UNIQUE(contract_id, leave_type_id)
);

-- Add foreign key constraint for contract_id in employee_documents
ALTER TABLE public.employee_documents 
ADD CONSTRAINT fk_employee_documents_contract 
FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE SET NULL;

-- Add foreign key constraint for contract_id in user_contract_acceptance
ALTER TABLE public.user_contract_acceptance 
ADD CONSTRAINT fk_user_contract_acceptance_contract 
FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE SET NULL;

-- Create indexes for better performance
CREATE INDEX idx_contract_groups_employee ON public.contract_groups(employee_id);
CREATE INDEX idx_contract_groups_status ON public.contract_groups(status, is_active, is_deleted);
CREATE INDEX idx_contract_groups_dates ON public.contract_groups(start_date, end_date);
CREATE INDEX idx_contract_types_code ON public.contract_types(code);
CREATE INDEX idx_contract_type_required_documents_contract_type ON public.contract_type_required_documents(contract_type_id);
CREATE INDEX idx_contract_type_required_documents_type ON public.contract_type_required_documents(document_type);
CREATE INDEX idx_contract_templates_contract_type ON public.contract_templates(contract_type_id);
CREATE INDEX idx_contract_templates_version ON public.contract_templates(version, is_active, is_deleted);
CREATE INDEX idx_contracts_employee ON public.contracts(employee_id);
CREATE INDEX idx_contracts_contract_group ON public.contracts(contract_group_id);
CREATE INDEX idx_contracts_contract_type ON public.contracts(contract_type_id);
CREATE INDEX idx_contracts_status ON public.contracts(status, is_active, is_deleted);
CREATE INDEX idx_contracts_dates ON public.contracts(start_date, end_date);
CREATE INDEX idx_contract_revisions_contract ON public.contract_revisions(contract_id);
CREATE INDEX idx_contract_revisions_dates ON public.contract_revisions(revision_date, effective_date);
CREATE INDEX idx_contract_holidays_contract ON public.contract_holidays(contract_id);
CREATE INDEX idx_contract_holidays_holiday ON public.contract_holidays(holiday_id);
CREATE INDEX idx_contract_leaves_contract ON public.contract_leaves(contract_id);
CREATE INDEX idx_contract_leaves_leave_type ON public.contract_leaves(leave_type_id);

-- Create partial unique indexes for soft delete constraints
CREATE UNIQUE INDEX idx_contract_type_documents_unique ON public.contract_type_required_documents(contract_type_id, document_type) WHERE is_deleted = false;
CREATE UNIQUE INDEX idx_contract_holidays_unique ON public.contract_holidays(contract_id, holiday_id) WHERE is_deleted = false;
CREATE UNIQUE INDEX idx_contract_leaves_unique ON public.contract_leaves(contract_id, leave_type_id) WHERE is_deleted = false;

-- Create triggers for updated_at columns
CREATE TRIGGER update_contract_groups_updated_at BEFORE UPDATE ON public.contract_groups FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contract_types_updated_at BEFORE UPDATE ON public.contract_types FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contract_type_required_documents_updated_at BEFORE UPDATE ON public.contract_type_required_documents FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contract_templates_updated_at BEFORE UPDATE ON public.contract_templates FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contracts_updated_at BEFORE UPDATE ON public.contracts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contract_revisions_updated_at BEFORE UPDATE ON public.contract_revisions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contract_holidays_updated_at BEFORE UPDATE ON public.contract_holidays FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_contract_leaves_updated_at BEFORE UPDATE ON public.contract_leaves FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Enable Row Level Security on all tables
ALTER TABLE public.contract_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_type_required_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_leaves ENABLE ROW LEVEL SECURITY;

-- RLS Policies for contract_groups
CREATE POLICY "Users can view their own contract groups" ON public.contract_groups
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can view all contract groups" ON public.contract_groups
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

CREATE POLICY "HR can manage contract groups" ON public.contract_groups
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contract_types (HR only)
CREATE POLICY "HR can manage contract types" ON public.contract_types
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contract_type_required_documents (HR only)
CREATE POLICY "HR can manage contract type required documents" ON public.contract_type_required_documents
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contract_templates (HR only)
CREATE POLICY "HR can manage contract templates" ON public.contract_templates
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contracts
CREATE POLICY "Users can view their own contracts" ON public.contracts
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can view all contracts" ON public.contracts
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

CREATE POLICY "HR can manage contracts" ON public.contracts
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contract_revisions
CREATE POLICY "Users can view their contract revisions" ON public.contract_revisions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.contracts c 
      JOIN public.employees e ON c.employee_id = e.id
      WHERE c.id = contract_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage contract revisions" ON public.contract_revisions
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contract_holidays
CREATE POLICY "Users can view their contract holidays" ON public.contract_holidays
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.contracts c 
      JOIN public.employees e ON c.employee_id = e.id
      WHERE c.id = contract_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage contract holidays" ON public.contract_holidays
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for contract_leaves
CREATE POLICY "Users can view their contract leaves" ON public.contract_leaves
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.contracts c 
      JOIN public.employees e ON c.employee_id = e.id
      WHERE c.id = contract_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage contract leaves" ON public.contract_leaves
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );
