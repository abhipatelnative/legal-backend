-- Add contract revision support to existing tables

-- Add revision fields to contracts table
ALTER TABLE public.contracts 
ADD COLUMN IF NOT EXISTS parent_contract_id UUID REFERENCES public.contracts(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1,
ADD COLUMN IF NOT EXISTS revision_reason TEXT;

-- Add contract_id to employee_salary_components for revision tracking
ALTER TABLE public.employee_salary_components 
ADD COLUMN IF NOT EXISTS contract_id UUID REFERENCES public.contracts(id) ON DELETE SET NULL;

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_contracts_parent ON public.contracts(parent_contract_id);
CREATE INDEX IF NOT EXISTS idx_contracts_version ON public.contracts(employee_id, version);
CREATE INDEX IF NOT EXISTS idx_employee_salary_components_contract ON public.employee_salary_components(contract_id);

-- Function to create contract revision
CREATE OR REPLACE FUNCTION public.create_contract_revision(
  original_contract_id UUID,
  revision_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  new_contract_id UUID;
  original_contract RECORD;
  max_version INTEGER;
BEGIN
  -- Get original contract data
  SELECT * INTO original_contract 
  FROM public.contracts 
  WHERE id = original_contract_id AND is_deleted = false;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Original contract not found';
  END IF;
  
  -- Get next version number
  SELECT COALESCE(MAX(version), 0) + 1 INTO max_version
  FROM public.contracts 
  WHERE employee_id = original_contract.employee_id 
  AND (parent_contract_id = original_contract_id OR id = original_contract_id)
  AND is_deleted = false;
  
  -- Create new contract revision
  INSERT INTO public.contracts (
    employee_id,
    contract_group_id,
    contract_type_id,
    contract_template_id,
    parent_contract_id,
    version,
    start_date,
    end_date,
    basic_salary,
    overtime_allowed,
    overtime_rate,
    probation_period,
    notice_period,
    status,
    revision_reason,
    created_by
  ) VALUES (
    original_contract.employee_id,
    original_contract.contract_group_id,
    original_contract.contract_type_id,
    original_contract.contract_template_id,
    original_contract_id,
    max_version,
    original_contract.start_date,
    original_contract.end_date,
    original_contract.basic_salary,
    original_contract.overtime_allowed,
    original_contract.overtime_rate,
    original_contract.probation_period,
    original_contract.notice_period,
    'draft',
    revision_reason,
    auth.uid()
  ) RETURNING id INTO new_contract_id;
  
  -- Copy contract holidays if they exist
  INSERT INTO public.contract_holidays (contract_id, holiday_id, is_applicable, created_by)
  SELECT new_contract_id, holiday_id, is_applicable, auth.uid()
  FROM public.contract_holidays 
  WHERE contract_id = original_contract_id;
  
  -- Copy contract leaves if they exist
  INSERT INTO public.contract_leaves (contract_id, leave_type_id, days_allowed, carry_forward, encashable, salary_payable, created_by)
  SELECT new_contract_id, leave_type_id, days_allowed, carry_forward, encashable, salary_payable, auth.uid()
  FROM public.contract_leaves 
  WHERE contract_id = original_contract_id;
  
  -- Copy salary components if they exist
  INSERT INTO public.employee_salary_components (
    employee_id, salary_component_id, value, effective_from, effective_to, contract_id, created_by
  )
  SELECT 
    employee_id, salary_component_id, value, effective_from, effective_to, new_contract_id, auth.uid()
  FROM public.employee_salary_components 
  WHERE contract_id = original_contract_id AND is_deleted = false;
  
  RETURN new_contract_id;
END;
$$;

-- Function to activate contract revision and terminate previous versions
CREATE OR REPLACE FUNCTION public.activate_contract_revision(
  contract_id UUID,
  activation_date DATE DEFAULT CURRENT_DATE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  contract_record RECORD;
  root_contract_id UUID;
BEGIN
  -- Get contract details
  SELECT * INTO contract_record 
  FROM public.contracts 
  WHERE id = contract_id AND is_deleted = false;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contract not found';
  END IF;
  
  -- Find root contract ID
  root_contract_id := COALESCE(contract_record.parent_contract_id, contract_record.id);
  
  -- Terminate all previous active versions of this contract
  UPDATE public.contracts 
  SET 
    status = 'terminated',
    end_date = activation_date - INTERVAL '1 day',
    updated_at = CURRENT_TIMESTAMP,
    updated_by = auth.uid()
  WHERE 
    (id = root_contract_id OR parent_contract_id = root_contract_id)
    AND id != contract_id
    AND status = 'active'
    AND is_deleted = false;
  
  -- Activate the new contract
  UPDATE public.contracts 
  SET 
    status = 'active',
    start_date = activation_date,
    updated_at = CURRENT_TIMESTAMP,
    updated_by = auth.uid()
  WHERE id = contract_id;
  
  -- Update salary component effective dates
  UPDATE public.employee_salary_components 
  SET 
    effective_from = activation_date,
    updated_at = CURRENT_TIMESTAMP,
    updated_by = auth.uid()
  WHERE contract_id = contract_id;
  
  -- End previous salary components
  UPDATE public.employee_salary_components 
  SET 
    effective_to = activation_date - INTERVAL '1 day',
    updated_at = CURRENT_TIMESTAMP,
    updated_by = auth.uid()
  WHERE 
    employee_id = contract_record.employee_id
    AND contract_id != contract_id
    AND effective_to IS NULL
    AND is_deleted = false;
  
  RETURN true;
END;
$$;