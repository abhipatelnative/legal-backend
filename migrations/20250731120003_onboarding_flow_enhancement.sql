-- Enhanced onboarding flow using existing tables

-- Add fields to user_contract_acceptance table
ALTER TABLE public.user_contract_acceptance 
ADD COLUMN IF NOT EXISTS employee_id UUID REFERENCES public.employees(id) ON DELETE CASCADE,
ADD COLUMN IF NOT EXISTS contract_template_content TEXT,
ADD COLUMN IF NOT EXISTS rejection_reason TEXT,
ADD COLUMN IF NOT EXISTS hr_approved_by UUID REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS hr_approved_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS hr_rejection_reason TEXT;

-- Add fields to employee_documents for verification
ALTER TABLE public.employee_documents
ADD COLUMN IF NOT EXISTS is_mandatory BOOLEAN DEFAULT true,
ADD COLUMN IF NOT EXISTS is_skipped BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS skip_reason TEXT;

-- Function to check employee onboarding status and redirect
CREATE OR REPLACE FUNCTION public.get_employee_onboarding_status(p_user_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_employee_record RECORD;
  v_contract_record RECORD;
  v_contract_acceptance RECORD;
  v_required_docs JSONB;
BEGIN
  -- Get employee details
  SELECT e.id, e.onboarding_status, e.user_id INTO v_employee_record
  FROM public.employees e
  WHERE e.user_id = p_user_id AND e.is_active = true AND e.is_deleted = false;
  
  -- If no employee record, allow login (admin/hr)
  IF v_employee_record IS NULL THEN
    RETURN json_build_object(
      'can_login', true,
      'onboarding_status', 'approved',
      'employee_id', NULL,
      'contract_id', NULL,
      'contract_template', NULL,
      'required_documents', '[]'::JSONB
    );
  END IF;
  
  -- Get contract details - prioritize active contracts, then by status and creation date
  SELECT c.id, ct.content INTO v_contract_record
  FROM public.contracts c
  LEFT JOIN public.contract_templates ct ON c.contract_template_id = ct.id
  WHERE c.employee_id = v_employee_record.id
  AND c.is_active = true
  AND c.is_deleted = false
  ORDER BY
    CASE c.status
      WHEN 'active' THEN 1
      WHEN 'draft' THEN 2
      WHEN 'terminated' THEN 3
      WHEN 'expired' THEN 4
      ELSE 5
    END,
    c.created_at DESC
  LIMIT 1;
  
  -- If no contract found, allow login (old employee without contract)
  IF v_contract_record.id IS NULL THEN
    RETURN json_build_object(
      'can_login', true,
      'onboarding_status', 'approved',
      'employee_id', v_employee_record.id,
      'contract_id', NULL,
      'contract_template', NULL,
      'required_documents', '[]'::JSONB
    );
  END IF;
  
  -- Check contract acceptance status
  SELECT uca.is_accepted, uca.accepted_at INTO v_contract_acceptance
  FROM public.user_contract_acceptance uca
  WHERE uca.user_id = p_user_id 
  AND uca.contract_id = v_contract_record.id;
  
  -- If contract not accepted yet, show contract acceptance page
  IF v_contract_acceptance.is_accepted IS NULL OR v_contract_acceptance.is_accepted = false THEN
    RETURN json_build_object(
      'can_login', false,
      'onboarding_status', 'pending',
      'employee_id', v_employee_record.id,
      'contract_id', v_contract_record.id,
      'contract_template', v_contract_record.content,
      'required_documents', '[]'::JSONB
    );
  END IF;
  
  -- Contract is accepted, check onboarding status
  CASE v_employee_record.onboarding_status
    WHEN 'pending' THEN
      -- Contract accepted but status not updated, update to contract_accepted
      UPDATE public.employees SET onboarding_status = 'contract_accepted'::onboarding_status WHERE id = v_employee_record.id;
      
      -- Get required documents
      SELECT json_agg(
        json_build_object(
          'document_type', crd.document_type,
          'is_mandatory', crd.is_mandatory,
          'remarks', crd.remarks
        )
      ) INTO v_required_docs
      FROM public.contracts c
      JOIN public.contract_type_required_documents crd ON c.contract_type_id = crd.contract_type_id
      WHERE c.id = v_contract_record.id 
      AND crd.is_active = true 
      AND crd.is_deleted = false;
      
      RETURN json_build_object(
        'can_login', false,
        'onboarding_status', 'contract_accepted',
        'employee_id', v_employee_record.id,
        'contract_id', v_contract_record.id,
        'contract_template', NULL,
        'required_documents', COALESCE(v_required_docs, '[]'::JSONB)
      );
      
    WHEN 'contract_accepted' THEN
      -- Show document upload page
      SELECT json_agg(
        json_build_object(
          'document_type', crd.document_type,
          'is_mandatory', crd.is_mandatory,
          'remarks', crd.remarks
        )
      ) INTO v_required_docs
      FROM public.contracts c
      JOIN public.contract_type_required_documents crd ON c.contract_type_id = crd.contract_type_id
      WHERE c.id = v_contract_record.id 
      AND crd.is_active = true 
      AND crd.is_deleted = false;
      
      RETURN json_build_object(
        'can_login', false,
        'onboarding_status', 'contract_accepted',
        'employee_id', v_employee_record.id,
        'contract_id', v_contract_record.id,
        'contract_template', NULL,
        'required_documents', COALESCE(v_required_docs, '[]'::JSONB)
      );
      
    WHEN 'docs_uploaded' THEN
      -- Show waiting for approval page
      RETURN json_build_object(
        'can_login', false,
        'onboarding_status', 'docs_uploaded',
        'employee_id', v_employee_record.id,
        'contract_id', v_contract_record.id,
        'contract_template', NULL,
        'required_documents', '[]'::JSONB
      );
      
    WHEN 'approved' THEN
      -- Allow login
      RETURN json_build_object(
        'can_login', true,
        'onboarding_status', 'approved',
        'employee_id', v_employee_record.id,
        'contract_id', v_contract_record.id,
        'contract_template', NULL,
        'required_documents', '[]'::JSONB
      );
      
    ELSE
      -- Default case - block login
      RETURN json_build_object(
        'can_login', false,
        'onboarding_status', v_employee_record.onboarding_status,
        'employee_id', v_employee_record.id,
        'contract_id', v_contract_record.id,
        'contract_template', v_contract_record.content,
        'required_documents', '[]'::JSONB
      );
  END CASE;
END;
$$;

-- Function to accept contract
CREATE OR REPLACE FUNCTION public.accept_employee_contract(
  p_employee_id UUID,
  p_contract_id UUID,
  p_ip_address INET DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  SELECT user_id INTO v_user_id FROM public.employees WHERE id = p_employee_id;
  
  -- Check if record exists
  IF EXISTS (SELECT 1 FROM public.user_contract_acceptance WHERE user_id = v_user_id AND contract_id = p_contract_id) THEN
    -- Update existing record
    UPDATE public.user_contract_acceptance 
    SET 
      is_accepted = true,
      accepted_at = CURRENT_TIMESTAMP,
      ip_address = p_ip_address,
      user_agent = p_user_agent
    WHERE user_id = v_user_id AND contract_id = p_contract_id;
  ELSE
    -- Insert new record
    INSERT INTO public.user_contract_acceptance (
      user_id, employee_id, contract_id, is_accepted, accepted_at, ip_address, user_agent
    ) VALUES (
      v_user_id, p_employee_id, p_contract_id, true, CURRENT_TIMESTAMP, p_ip_address, p_user_agent
    );
  END IF;
  
  -- Update employee onboarding status
  UPDATE public.employees 
  SET onboarding_status = 'contract_accepted'::onboarding_status, updated_at = CURRENT_TIMESTAMP
  WHERE id = p_employee_id;
  
  RETURN true;
END;
$$;

-- Function to upload or skip document
CREATE OR REPLACE FUNCTION public.handle_employee_document(
  p_employee_id UUID,
  p_contract_id UUID,
  p_document_type VARCHAR(50),
  p_file_url TEXT DEFAULT NULL,
  p_is_skipped BOOLEAN DEFAULT false,
  p_skip_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_is_skipped THEN
    -- Skip document
    INSERT INTO public.employee_documents (
      employee_id, contract_id, document_type, file_url, is_skipped, skip_reason
    ) VALUES (
      p_employee_id, p_contract_id, p_document_type, '', true, p_skip_reason
    );
  ELSE
    -- Upload document
    INSERT INTO public.employee_documents (
      employee_id, contract_id, document_type, file_url, uploaded_at
    ) VALUES (
      p_employee_id, p_contract_id, p_document_type, p_file_url, CURRENT_TIMESTAMP
    );
  END IF;
  
  RETURN true;
END;
$$;

-- Function to complete document phase
CREATE OR REPLACE FUNCTION public.complete_document_phase(p_employee_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.employees 
  SET onboarding_status = 'docs_uploaded'::onboarding_status, updated_at = CURRENT_TIMESTAMP
  WHERE id = p_employee_id;
  
  RETURN true;
END;
$$;

-- Function for HR to approve/reject onboarding
CREATE OR REPLACE FUNCTION public.hr_approve_onboarding(
  p_employee_id UUID,
  p_approved BOOLEAN,
  p_hr_user_id UUID,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Update contract acceptance record
  UPDATE public.user_contract_acceptance 
  SET 
    hr_approved_by = p_hr_user_id,
    hr_approved_at = CURRENT_TIMESTAMP,
    hr_rejection_reason = p_rejection_reason
  WHERE employee_id = p_employee_id;
  
  -- Update employee status
  UPDATE public.employees 
  SET 
    onboarding_status = CASE WHEN p_approved THEN 'approved'::onboarding_status ELSE 'pending'::onboarding_status END,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_employee_id;
  
  RETURN true;
END;
$$;

-- Function to initialize contract acceptance for new employee
CREATE OR REPLACE FUNCTION public.initialize_contract_acceptance(
  p_employee_id UUID,
  p_contract_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_acceptance_id UUID;
  v_contract_template TEXT;
BEGIN
  SELECT user_id INTO v_user_id FROM public.employees WHERE id = p_employee_id;
  
  SELECT ct.content INTO v_contract_template
  FROM public.contracts c
  LEFT JOIN public.contract_templates ct ON c.contract_template_id = ct.id
  WHERE c.id = p_contract_id;
  
  INSERT INTO public.user_contract_acceptance (
    user_id, employee_id, contract_id, contract_template_content, is_accepted
  ) VALUES (
    v_user_id, p_employee_id, p_contract_id, v_contract_template, false
  ) RETURNING id INTO v_acceptance_id;
  
  RETURN v_acceptance_id;
END;
$$;
