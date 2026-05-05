
-- Phase 4: Attendance & Payroll Management

-- 32. attendance table
-- CREATE TABLE public.attendance (
--   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
--   date DATE NOT NULL,
--   status attendance_status DEFAULT 'present',
--   punch_in_time TIMESTAMP WITH TIME ZONE,
--   punch_out_time TIMESTAMP WITH TIME ZONE,
--   total_hours DECIMAL(5,2),
--   break_hours DECIMAL(5,2) DEFAULT 0,
--   overtime_hours DECIMAL(5,2) DEFAULT 0,
--   half_day_type half_day_type,
--   remarks TEXT,
--   verified_by UUID REFERENCES auth.users(id),
--   verified_at TIMESTAMP WITH TIME ZONE,
--   is_verified BOOLEAN DEFAULT false,
--   is_active BOOLEAN DEFAULT true,
--   is_deleted BOOLEAN DEFAULT false,
--   created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
--   updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
--   created_by UUID REFERENCES auth.users(id),
--   updated_by UUID REFERENCES auth.users(id),
  
--   -- Constraints
--   CONSTRAINT valid_punch_times CHECK (punch_out_time IS NULL OR punch_out_time > punch_in_time),
--   CONSTRAINT positive_hours CHECK (
--     (total_hours IS NULL OR total_hours >= 0) AND
--     (break_hours >= 0) AND
--     (overtime_hours >= 0)
--   ),
--   -- Ensure unique employee-date combinations
--   UNIQUE(employee_id, date)
-- );


create table public.punch_records (
  id uuid not null default gen_random_uuid (),
  enroll_number integer not null,
  verify_mode character varying null,
  in_out_mode integer null,
  punch_time timestamp with time zone not null,
  is_manual boolean null default false,
  is_active boolean null default true,
  is_deleted boolean null default false,
  created_at timestamp with time zone null default CURRENT_TIMESTAMP,
  updated_at timestamp with time zone null default CURRENT_TIMESTAMP,
  created_by uuid null,
  updated_by uuid null,
  constraint punch_records_pkey primary key (id),
  constraint punch_records_created_by_fkey foreign KEY (created_by) references auth.users (id),
  constraint punch_records_updated_by_fkey foreign KEY (updated_by) references auth.users (id)
) TABLESPACE pg_default;

create index IF not exists idx_punch_records_enroll_punch_time on public.punch_records using btree (enroll_number, punch_time) TABLESPACE pg_default;

create trigger update_punch_records_updated_at BEFORE
update on punch_records for EACH row
execute FUNCTION update_updated_at_column ();

create table public.attendance_records (
  id uuid not null default gen_random_uuid (),
  employee_id uuid not null,
  attendance_date date not null,
  check_in timestamp with time zone null,
  check_out timestamp with time zone null,
  break_start timestamp with time zone null,
  break_end timestamp with time zone null,
  total_break_duration_minutes numeric null default 0,
  total_hours numeric null,
  overtime_hours numeric null,
  status character varying(50) null,
  is_manual_entry boolean null default false,
  remarks text null,
  is_active boolean null default true,
  is_deleted boolean null default false,
  created_at timestamp with time zone null default CURRENT_TIMESTAMP,
  updated_at timestamp with time zone null default CURRENT_TIMESTAMP,
  created_by uuid null,
  updated_by uuid null,
  constraint attendance_records_pkey primary key (id),
  constraint unique_employee_attendance_date unique (employee_id, attendance_date),
  constraint attendance_records_created_by_fkey foreign KEY (created_by) references auth.users (id),
  constraint attendance_records_employee_id_fkey foreign KEY (employee_id) references employees (id),
  constraint attendance_records_updated_by_fkey foreign KEY (updated_by) references auth.users (id),
  constraint attendance_records_status_check check (
    (
      (status)::text = any (
        (
          array[
            'present'::character varying,
            'absent'::character varying,
            'half_day'::character varying,
            'holiday'::character varying,
            'leave'::character varying
          ]
        )::text[]
      )
    )
  )
) TABLESPACE pg_default;

create index IF not exists idx_attendance_records_employee_date on public.attendance_records using btree (employee_id, attendance_date) TABLESPACE pg_default;

create trigger update_attendance_records_updated_at BEFORE
update on attendance_records for EACH row
execute FUNCTION update_updated_at_column ();


-- 33. punch_records table
-- CREATE TABLE public.punch_records (
--   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
--   attendance_id UUID REFERENCES public.attendance(id) ON DELETE SET NULL,
--   punch_time TIMESTAMP WITH TIME ZONE NOT NULL,
--   punch_type punch_type NOT NULL,
--   location_lat DECIMAL(10,8),
--   location_lng DECIMAL(11,8),
--   device_info JSONB,
--   photo_url VARCHAR(500),
--   remarks TEXT,
--   is_active BOOLEAN DEFAULT true,
--   is_deleted BOOLEAN DEFAULT false,
--   created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
--   updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
--   created_by UUID REFERENCES auth.users(id),
--   updated_by UUID REFERENCES auth.users(id)
-- );

-- 34. leave_requests table
CREATE TABLE public.leave_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  leave_type_id UUID NOT NULL REFERENCES public.leave_types(id) ON DELETE RESTRICT,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  total_days DECIMAL(5,2) NOT NULL,
  half_day_type half_day_type,
  reason TEXT NOT NULL,
  status leave_status DEFAULT 'pending',
  applied_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  approved_by UUID REFERENCES auth.users(id),
  approved_at TIMESTAMP WITH TIME ZONE,
  rejection_reason TEXT,
  emergency_contact VARCHAR(255),
  attachment_url VARCHAR(500),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_leave_dates CHECK (end_date >= start_date),
  CONSTRAINT positive_total_days CHECK (total_days > 0)
);

-- 35. leave_approval_workflow table
CREATE TABLE public.leave_approval_workflow (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  leave_request_id UUID NOT NULL REFERENCES public.leave_requests(id) ON DELETE CASCADE,
  level INTEGER NOT NULL,
  approver_id UUID NOT NULL REFERENCES auth.users(id),
  status approval_status DEFAULT 'pending',
  action_date TIMESTAMP WITH TIME ZONE,
  comments TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_level CHECK (level > 0),
  -- Ensure unique level per leave request
  UNIQUE(leave_request_id, level)
);

-- 36. leave_balances table
CREATE TABLE public.leave_balances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  leave_type_id UUID NOT NULL REFERENCES public.leave_types(id) ON DELETE CASCADE,
  year INTEGER NOT NULL,
  allocated_days DECIMAL(10,2) NOT NULL,
  used_days DECIMAL(10,2) DEFAULT 0,
  carried_forward DECIMAL(10,2) DEFAULT 0,
  encashed_days DECIMAL(10,2) DEFAULT 0,
  remaining_days DECIMAL(10,2) GENERATED ALWAYS AS (allocated_days + carried_forward - used_days - encashed_days) STORED,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_leave_values CHECK (
    allocated_days >= 0 AND
    used_days >= 0 AND
    carried_forward >= 0 AND
    encashed_days >= 0
  ),
  CONSTRAINT valid_leave_year CHECK (year > 1900 AND year < 3000),
  -- Ensure unique employee-leave_type-year combinations
  UNIQUE(employee_id, leave_type_id, year)
);

-- 37. salary_components table
CREATE TABLE public.salary_components (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL UNIQUE,
  code VARCHAR(50) UNIQUE NOT NULL,
  component_type salary_component_type NOT NULL,
  calculation_type calculation_type NOT NULL,
  default_value DECIMAL(15,2),
  percentage_of VARCHAR(50), -- Reference to another component for percentage calculations
  formula TEXT, -- For complex formula-based calculations
  is_mandatory BOOLEAN DEFAULT false,
  is_taxable BOOLEAN DEFAULT true,
  is_provident_fund_applicable BOOLEAN DEFAULT true,
  is_esi_applicable BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_default_value CHECK (default_value IS NULL OR default_value >= 0)
);

-- 38. employee_salary_components table
CREATE TABLE public.employee_salary_components (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  salary_component_id UUID NOT NULL REFERENCES public.salary_components(id) ON DELETE CASCADE,
  value DECIMAL(15,2) NOT NULL,
  effective_from DATE NOT NULL,
  effective_to DATE,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_effective_dates CHECK (effective_to IS NULL OR effective_to >= effective_from),
  CONSTRAINT positive_salary_value CHECK (value >= 0),
  -- Ensure unique active component per employee (overlapping periods handled by application logic)
  CONSTRAINT unique_employee_salary_component UNIQUE(employee_id, salary_component_id, effective_from)
);

-- 39. payroll_periods table
CREATE TABLE public.payroll_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  year INTEGER NOT NULL,
  month INTEGER NOT NULL,
  status payroll_status DEFAULT 'draft',
  processed_at TIMESTAMP WITH TIME ZONE,
  processed_by UUID REFERENCES auth.users(id),
  confirmed_at TIMESTAMP WITH TIME ZONE,
  confirmed_by UUID REFERENCES auth.users(id),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT valid_payroll_dates CHECK (end_date >= start_date),
  CONSTRAINT valid_payroll_year CHECK (year > 1900 AND year < 3000),
  CONSTRAINT valid_payroll_month CHECK (month >= 1 AND month <= 12),
  -- Ensure unique year-month combinations
  UNIQUE(year, month)
);

-- 40. payroll table
CREATE TABLE public.payroll (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payroll_period_id UUID NOT NULL REFERENCES public.payroll_periods(id) ON DELETE CASCADE,
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  basic_salary DECIMAL(15,2) NOT NULL,
  gross_salary DECIMAL(15,2) NOT NULL,
  total_deductions DECIMAL(15,2) NOT NULL DEFAULT 0,
  net_salary DECIMAL(15,2) NOT NULL,
  working_days INTEGER NOT NULL,
  present_days INTEGER NOT NULL,
  leave_days INTEGER DEFAULT 0,
  overtime_hours DECIMAL(5,2) DEFAULT 0,
  overtime_amount DECIMAL(15,2) DEFAULT 0,
  status payroll_status DEFAULT 'draft',
  generated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  paid_at TIMESTAMP WITH TIME ZONE,
  payment_method VARCHAR(50),
  transaction_id VARCHAR(255),
  remarks TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_salary_amounts CHECK (
    basic_salary > 0 AND
    gross_salary > 0 AND
    total_deductions >= 0 AND
    net_salary >= 0
  ),
  CONSTRAINT positive_days CHECK (
    working_days > 0 AND
    present_days >= 0 AND
    leave_days >= 0 AND
    present_days <= working_days
  ),
  CONSTRAINT positive_overtime CHECK (
    overtime_hours >= 0 AND
    overtime_amount >= 0
  ),
  -- Ensure unique employee per payroll period
  UNIQUE(payroll_period_id, employee_id)
);

-- 41. payroll_components table
CREATE TABLE public.payroll_components (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payroll_id UUID NOT NULL REFERENCES public.payroll(id) ON DELETE CASCADE,
  salary_component_id UUID NOT NULL REFERENCES public.salary_components(id) ON DELETE CASCADE,
  amount DECIMAL(15,2) NOT NULL,
  calculated_value DECIMAL(15,2),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_payroll_amount CHECK (amount >= 0),
  -- Ensure unique component per payroll
  UNIQUE(payroll_id, salary_component_id)
);

-- Create indexes for better performance
-- CREATE INDEX idx_attendance_employee ON public.attendance(employee_id);
-- CREATE INDEX idx_attendance_date ON public.attendance(date);
-- CREATE INDEX idx_attendance_status ON public.attendance(status, is_active, is_deleted);
-- CREATE INDEX idx_punch_records_employee ON public.punch_records(employee_id);
-- CREATE INDEX idx_punch_records_time ON public.punch_records(punch_time);
-- CREATE INDEX idx_punch_records_attendance ON public.punch_records(attendance_id);
CREATE INDEX idx_leave_requests_employee ON public.leave_requests(employee_id);
CREATE INDEX idx_leave_requests_dates ON public.leave_requests(start_date, end_date);
CREATE INDEX idx_leave_requests_status ON public.leave_requests(status, is_active, is_deleted);
CREATE INDEX idx_leave_requests_leave_type ON public.leave_requests(leave_type_id);
CREATE INDEX idx_leave_approval_workflow_request ON public.leave_approval_workflow(leave_request_id);
CREATE INDEX idx_leave_approval_workflow_approver ON public.leave_approval_workflow(approver_id);
CREATE INDEX idx_leave_balances_employee ON public.leave_balances(employee_id);
CREATE INDEX idx_leave_balances_year ON public.leave_balances(year);
CREATE INDEX idx_leave_balances_leave_type ON public.leave_balances(leave_type_id);
CREATE INDEX idx_salary_components_code ON public.salary_components(code);
CREATE INDEX idx_salary_components_type ON public.salary_components(component_type, calculation_type);
CREATE INDEX idx_employee_salary_components_employee ON public.employee_salary_components(employee_id);
CREATE INDEX idx_employee_salary_components_component ON public.employee_salary_components(salary_component_id);
CREATE INDEX idx_employee_salary_components_dates ON public.employee_salary_components(effective_from, effective_to);
CREATE INDEX idx_payroll_periods_year_month ON public.payroll_periods(year, month);
CREATE INDEX idx_payroll_periods_dates ON public.payroll_periods(start_date, end_date);
CREATE INDEX idx_payroll_period ON public.payroll(payroll_period_id);
CREATE INDEX idx_payroll_employee ON public.payroll(employee_id);
CREATE INDEX idx_payroll_status ON public.payroll(status, is_active, is_deleted);
CREATE INDEX idx_payroll_components_payroll ON public.payroll_components(payroll_id);
CREATE INDEX idx_payroll_components_component ON public.payroll_components(salary_component_id);

-- Create triggers for updated_at columns
-- CREATE TRIGGER update_attendance_updated_at BEFORE UPDATE ON public.attendance FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
-- CREATE TRIGGER update_punch_records_updated_at BEFORE UPDATE ON public.punch_records FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_leave_requests_updated_at BEFORE UPDATE ON public.leave_requests FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_leave_approval_workflow_updated_at BEFORE UPDATE ON public.leave_approval_workflow FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_leave_balances_updated_at BEFORE UPDATE ON public.leave_balances FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_salary_components_updated_at BEFORE UPDATE ON public.salary_components FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_employee_salary_components_updated_at BEFORE UPDATE ON public.employee_salary_components FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_payroll_periods_updated_at BEFORE UPDATE ON public.payroll_periods FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_payroll_updated_at BEFORE UPDATE ON public.payroll FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_payroll_components_updated_at BEFORE UPDATE ON public.payroll_components FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Enable Row Level Security on all tables
-- ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.punch_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_approval_workflow ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.salary_components ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_salary_components ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_components ENABLE ROW LEVEL SECURITY;

-- RLS Policies for attendance
-- CREATE POLICY "Users can view their own attendance" ON public.attendance
--   FOR SELECT USING (
--     EXISTS (
--       SELECT 1 FROM public.employees e 
--       WHERE e.id = employee_id AND e.user_id = auth.uid()
--     )
--   );

-- CREATE POLICY "HR can view all attendance" ON public.attendance
--   FOR SELECT USING (
--     EXISTS (
--       SELECT 1 FROM public.user_roles ur 
--       JOIN public.roles r ON ur.role_id = r.id 
--       WHERE ur.user_id = auth.uid() 
--       AND r.name IN ('HR Manager', 'Admin') 
--       AND ur.is_active = true
--     )
--   );

-- CREATE POLICY "HR can manage attendance" ON public.attendance
--   FOR ALL USING (
--     EXISTS (
--       SELECT 1 FROM public.user_roles ur 
--       JOIN public.roles r ON ur.role_id = r.id 
--       WHERE ur.user_id = auth.uid() 
--       AND r.name IN ('HR Manager', 'Admin') 
--       AND ur.is_active = true
--     )
--   );

-- RLS Policies for punch_records
-- CREATE POLICY "Users can create their own punch records" ON public.punch_records
--   FOR INSERT WITH CHECK (
--     EXISTS (
--       SELECT 1 FROM public.employees e 
--       WHERE e.id = employee_id AND e.user_id = auth.uid()
--     )
--   );

-- CREATE POLICY "Users can view their own punch records" ON public.punch_records
--   FOR SELECT USING (
--     EXISTS (
--       SELECT 1 FROM public.employees e 
--       WHERE e.id = employee_id AND e.user_id = auth.uid()
--     )
--   );

-- CREATE POLICY "HR can view all punch records" ON public.punch_records
--   FOR SELECT USING (
--     EXISTS (
--       SELECT 1 FROM public.user_roles ur 
--       JOIN public.roles r ON ur.role_id = r.id 
--       WHERE ur.user_id = auth.uid() 
--       AND r.name IN ('HR Manager', 'Admin') 
--       AND ur.is_active = true
--     )
--   );

-- RLS Policies for leave_requests
CREATE POLICY "Users can manage their own leave requests" ON public.leave_requests
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can view all leave requests" ON public.leave_requests
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Manager') 
      AND ur.is_active = true
    )
  );

CREATE POLICY "Managers can approve leave requests" ON public.leave_requests
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for leave_balances
CREATE POLICY "Users can view their own leave balances" ON public.leave_balances
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage leave balances" ON public.leave_balances
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for salary_components (HR only)
CREATE POLICY "HR can manage salary components" ON public.salary_components
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for employee_salary_components
CREATE POLICY "Users can view their own salary components" ON public.employee_salary_components
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage employee salary components" ON public.employee_salary_components
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for payroll_periods (HR/Finance only)
CREATE POLICY "HR can manage payroll periods" ON public.payroll_periods
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for payroll
CREATE POLICY "Users can view their own payroll" ON public.payroll
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.employees e 
      WHERE e.id = employee_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage payroll" ON public.payroll
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for payroll_components
CREATE POLICY "Users can view their own payroll components" ON public.payroll_components
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.payroll p 
      JOIN public.employees e ON p.employee_id = e.id
      WHERE p.id = payroll_id AND e.user_id = auth.uid()
    )
  );

CREATE POLICY "HR can manage payroll components" ON public.payroll_components
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );
