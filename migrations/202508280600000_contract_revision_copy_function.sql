-- Function to copy contract leaves and holidays when revising
CREATE OR REPLACE FUNCTION public.copy_contract_data_on_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Only proceed if this is a revision (has parent_contract_id)
  IF NEW.parent_contract_id IS NOT NULL THEN
    
    -- Copy contract leaves from parent contract
    INSERT INTO public.contract_leaves (
      contract_id,
      leave_type_id,
      days_allowed,
      carry_forward,
      encashable,
      salary_payable,
      notes,
      created_by
    )
    SELECT 
      NEW.id,
      leave_type_id,
      days_allowed,
      carry_forward,
      encashable,
      salary_payable,
      notes,
      NEW.created_by
    FROM public.contract_leaves
    WHERE contract_id = NEW.parent_contract_id
    AND is_active = true
    AND is_deleted = false;
    
    -- Copy contract holidays from parent contract
    INSERT INTO public.contract_holidays (
      contract_id,
      holiday_id,
      is_applicable,
      remarks,
      created_by
    )
    SELECT 
      NEW.id,
      holiday_id,
      is_applicable,
      remarks,
      NEW.created_by
    FROM public.contract_holidays
    WHERE contract_id = NEW.parent_contract_id
    AND is_active = true
    AND is_deleted = false;
    
  END IF;
  
  RETURN NEW;
END;
$$;

-- Create trigger to automatically copy data on contract revision
DROP TRIGGER IF EXISTS trigger_copy_contract_data_on_revision ON public.contracts;
CREATE TRIGGER trigger_copy_contract_data_on_revision
  AFTER INSERT ON public.contracts
  FOR EACH ROW
  EXECUTE FUNCTION public.copy_contract_data_on_revision();

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.copy_contract_data_on_revision() TO authenticated;