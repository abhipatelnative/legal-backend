-- Employee Financial Management System
-- Security Deposits, Loans, PF, and Advanced Calculations

-- 1. Employee Security Deposits
CREATE TABLE IF NOT EXISTS public.employee_security_deposits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  deposit_amount DECIMAL(15,2) NOT NULL CHECK (deposit_amount > 0),
  monthly_deduction DECIMAL(15,2) NOT NULL CHECK (monthly_deduction > 0),
  start_date DATE NOT NULL,
  collection_months INTEGER NOT NULL DEFAULT 8,
  total_collected DECIMAL(15,2) DEFAULT 0,
  interest_rate DECIMAL(5,2) NOT NULL DEFAULT 8.00,
  status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'completed', 'refunded')),
  completion_date DATE,
  refund_date DATE,
  refund_amount DECIMAL(15,2),
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 2. Security Deposit Transactions
CREATE TABLE IF NOT EXISTS public.security_deposit_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  security_deposit_id UUID NOT NULL REFERENCES public.employee_security_deposits(id) ON DELETE CASCADE,
  payroll_period_id UUID REFERENCES public.payroll_periods(id),
  transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('deduction', 'interest', 'refund')),
  amount DECIMAL(15,2) NOT NULL,
  transaction_date DATE NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id)
);

-- 3. Employee Loans
CREATE TABLE IF NOT EXISTS public.employee_loans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  loan_amount DECIMAL(15,2) NOT NULL CHECK (loan_amount > 0),
  monthly_deduction DECIMAL(15,2) NOT NULL CHECK (monthly_deduction > 0),
  loan_date DATE NOT NULL,
  tenure_months INTEGER NOT NULL,
  interest_rate DECIMAL(5,2) DEFAULT 0,
  guarantor1_employee_id UUID REFERENCES public.employees(id),
  guarantor2_employee_id UUID REFERENCES public.employees(id),
  total_paid DECIMAL(15,2) DEFAULT 0,
  remaining_amount DECIMAL(15,2) GENERATED ALWAYS AS (loan_amount - total_paid) STORED,
  status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'completed', 'defaulted')),
  completion_date DATE,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 4. Loan Transactions
CREATE TABLE IF NOT EXISTS public.loan_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id UUID NOT NULL REFERENCES public.employee_loans(id) ON DELETE CASCADE,
  payroll_period_id UUID REFERENCES public.payroll_periods(id),
  transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('deduction', 'interest', 'penalty')),
  amount DECIMAL(15,2) NOT NULL,
  transaction_date DATE NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id)
);

-- 5. Employee PF Accounts
CREATE TABLE IF NOT EXISTS public.employee_pf_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL UNIQUE REFERENCES public.employees(id) ON DELETE CASCADE,
  pf_number VARCHAR(50) UNIQUE,
  employee_contribution_rate DECIMAL(5,2) DEFAULT 12.00,
  employer_contribution_rate DECIMAL(5,2) DEFAULT 12.00,
  total_employee_contribution DECIMAL(15,2) DEFAULT 0,
  total_employer_contribution DECIMAL(15,2) DEFAULT 0,
  total_balance DECIMAL(15,2) GENERATED ALWAYS AS (total_employee_contribution + total_employer_contribution) STORED,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 6. PF Transactions
CREATE TABLE IF NOT EXISTS public.pf_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pf_account_id UUID NOT NULL REFERENCES public.employee_pf_accounts(id) ON DELETE CASCADE,
  payroll_period_id UUID REFERENCES public.payroll_periods(id),
  employee_contribution DECIMAL(15,2) DEFAULT 0,
  employer_contribution DECIMAL(15,2) DEFAULT 0,
  basic_salary DECIMAL(15,2) NOT NULL,
  transaction_date DATE NOT NULL,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id)
);

-- Security Deposit Interest Calculation
CREATE OR REPLACE FUNCTION calculate_security_deposit_interest(p_security_deposit_id UUID)
RETURNS DECIMAL(15,2)
LANGUAGE plpgsql
AS $$
DECLARE
  deposit_record RECORD;
  months_completed INTEGER;
  interest_months INTEGER;
  interest_amount DECIMAL(15,2);
BEGIN
  SELECT * INTO deposit_record FROM public.employee_security_deposits WHERE id = p_security_deposit_id;
  
  months_completed := EXTRACT(MONTH FROM AGE(CURRENT_DATE, deposit_record.start_date));
  
  IF months_completed > deposit_record.collection_months THEN
    interest_months := months_completed - deposit_record.collection_months;
    interest_amount := (deposit_record.total_collected * deposit_record.interest_rate / 100) * (interest_months / 12.0);
    RETURN interest_amount;
  END IF;
  
  RETURN 0;
END;
$$;

-- Process Monthly Financial Deductions
CREATE OR REPLACE FUNCTION process_monthly_financial_deductions(
  p_payroll_period_id UUID,
  p_employee_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  security_deposit RECORD;
  loan_record RECORD;
  pf_account RECORD;
  basic_salary DECIMAL(15,2);
  total_deductions DECIMAL(15,2) := 0;
BEGIN
  SELECT p.basic_salary INTO basic_salary
  FROM public.payroll p
  WHERE p.payroll_period_id = p_payroll_period_id AND p.employee_id = p_employee_id;
  
  -- Process Security Deposits
  FOR security_deposit IN
    SELECT * FROM public.employee_security_deposits
    WHERE employee_id = p_employee_id AND status = 'active'
      AND total_collected < (monthly_deduction * collection_months)
  LOOP
    INSERT INTO public.security_deposit_transactions (
      security_deposit_id, payroll_period_id, transaction_type, 
      amount, transaction_date, description
    ) VALUES (
      security_deposit.id, p_payroll_period_id, 'deduction',
      security_deposit.monthly_deduction, CURRENT_DATE,
      'Monthly security deposit deduction'
    );
    
    UPDATE public.employee_security_deposits
    SET total_collected = total_collected + security_deposit.monthly_deduction,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = security_deposit.id;
    
    total_deductions := total_deductions + security_deposit.monthly_deduction;
  END LOOP;
  
  -- Process Loans
  FOR loan_record IN
    SELECT * FROM public.employee_loans
    WHERE employee_id = p_employee_id AND status = 'active'
      AND total_paid < loan_amount
  LOOP
    INSERT INTO public.loan_transactions (
      loan_id, payroll_period_id, transaction_type,
      amount, transaction_date, description
    ) VALUES (
      loan_record.id, p_payroll_period_id, 'deduction',
      loan_record.monthly_deduction, CURRENT_DATE,
      'Monthly loan EMI deduction'
    );
    
    UPDATE public.employee_loans
    SET total_paid = total_paid + loan_record.monthly_deduction,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = loan_record.id;
    
    total_deductions := total_deductions + loan_record.monthly_deduction;
  END LOOP;
  
  -- Process PF
  SELECT * INTO pf_account FROM public.employee_pf_accounts WHERE employee_id = p_employee_id AND is_active = true;
  
  IF FOUND THEN
    DECLARE
      employee_pf DECIMAL(15,2);
      employer_pf DECIMAL(15,2);
    BEGIN
      employee_pf := (basic_salary * pf_account.employee_contribution_rate / 100);
      employer_pf := (basic_salary * pf_account.employer_contribution_rate / 100);
      
      INSERT INTO public.pf_transactions (
        pf_account_id, payroll_period_id, employee_contribution,
        employer_contribution, basic_salary, transaction_date
      ) VALUES (
        pf_account.id, p_payroll_period_id, employee_pf,
        employer_pf, basic_salary, CURRENT_DATE
      );
      
      UPDATE public.employee_pf_accounts
      SET total_employee_contribution = total_employee_contribution + employee_pf,
          total_employer_contribution = total_employer_contribution + employer_pf,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = pf_account.id;
      
      total_deductions := total_deductions + employee_pf;
    END;
  END IF;
  
  -- Apply deductions to payroll
  PERFORM public.apply_payroll_adjustment(
    p_payroll_period_id, p_employee_id, total_deductions,
    'deduction'::public.adjustment_type, 'Financial Deductions',
    'Security deposit, loans, and PF deductions'
  );
  
  RETURN TRUE;
END;
$$;

-- Auto-create PF account for new employee
CREATE OR REPLACE FUNCTION create_employee_pf_account(p_employee_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  employee_code VARCHAR(50);
BEGIN
  SELECT e.employee_code INTO employee_code FROM public.employees e WHERE e.id = p_employee_id;
  
  INSERT INTO public.employee_pf_accounts (
    employee_id, pf_number, created_by
  ) VALUES (
    p_employee_id, 
    'PF' || employee_code || EXTRACT(YEAR FROM CURRENT_DATE),
    auth.uid()
  );
  
  RETURN TRUE;
END;
$$;

-- Trigger to auto-create PF account
CREATE OR REPLACE FUNCTION auto_create_pf_account()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM create_employee_pf_account(NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_auto_create_pf_account ON public.employees;
CREATE TRIGGER trigger_auto_create_pf_account
  AFTER INSERT ON public.employees
  FOR EACH ROW EXECUTE FUNCTION auto_create_pf_account();

-- Indexes
CREATE INDEX IF NOT EXISTS idx_security_deposits_employee ON public.employee_security_deposits(employee_id);
CREATE INDEX IF NOT EXISTS idx_loans_employee ON public.employee_loans(employee_id);
CREATE INDEX IF NOT EXISTS idx_pf_accounts_employee ON public.employee_pf_accounts(employee_id);

-- Triggers
CREATE TRIGGER update_security_deposits_updated_at 
  BEFORE UPDATE ON public.employee_security_deposits 
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_loans_updated_at 
  BEFORE UPDATE ON public.employee_loans 
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_pf_accounts_updated_at 
  BEFORE UPDATE ON public.employee_pf_accounts 
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- RLS
ALTER TABLE public.employee_security_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_deposit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_loans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loan_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_pf_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pf_transactions ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Users can view their own financial records" ON public.employee_security_deposits
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.employees e WHERE e.id = employee_id AND e.user_id = auth.uid())
  );

CREATE POLICY "HR can manage financial records" ON public.employee_security_deposits
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() AND r.name IN ('HR Manager', 'Admin') AND ur.is_active = true
    )
  );

-- Similar policies for other tables
CREATE POLICY "Users can view their own loans" ON public.employee_loans
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.employees e WHERE e.id = employee_id AND e.user_id = auth.uid())
  );

CREATE POLICY "HR can manage loans" ON public.employee_loans
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() AND r.name IN ('HR Manager', 'Admin') AND ur.is_active = true
    )
  );

CREATE POLICY "Users can view their own PF" ON public.employee_pf_accounts
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.employees e WHERE e.id = employee_id AND e.user_id = auth.uid())
  );

CREATE POLICY "HR can manage PF" ON public.employee_pf_accounts
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() AND r.name IN ('HR Manager', 'Admin') AND ur.is_active = true
    )
  );