ALTER TABLE public.contract_type_required_documents
ADD COLUMN IF NOT EXISTS employee_visible BOOLEAN NOT NULL DEFAULT false;

UPDATE public.contract_type_required_documents
SET employee_visible = true
WHERE employee_visible = false;

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

      -- Get required documents visible to employee
      SELECT json_agg(
        json_build_object(
          'document_type', crd.document_type,
          'is_mandatory', crd.is_mandatory,
          'employee_visible', crd.employee_visible,
          'remarks', crd.remarks
        )
      ) INTO v_required_docs
      FROM public.contracts c
      JOIN public.contract_type_required_documents crd ON c.contract_type_id = crd.contract_type_id
      WHERE c.id = v_contract_record.id
      AND crd.is_active = true
      AND crd.is_deleted = false
      AND crd.employee_visible = true;

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
          'employee_visible', crd.employee_visible,
          'remarks', crd.remarks
        )
      ) INTO v_required_docs
      FROM public.contracts c
      JOIN public.contract_type_required_documents crd ON c.contract_type_id = crd.contract_type_id
      WHERE c.id = v_contract_record.id
      AND crd.is_active = true
      AND crd.is_deleted = false
      AND crd.employee_visible = true;

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
