-- Update calculate_referral_bonus to use snapshot values instead of current settings

CREATE OR REPLACE FUNCTION public.calculate_referral_bonus(
  p_referred_employee_id uuid,
  p_current_month date
)
RETURNS TABLE(
  referral_id uuid,
  referring_employee_id uuid,
  bonus_amount numeric,
  should_process boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    er.id,
    er.referred_by_employee_id,
    er.bonus_amount_at_creation,  -- Use snapshot value
    CASE
      -- Should process if:
      -- 1. Referral is active
      -- 2. Haven't paid all months yet
      -- 3. Next payment is due on or before current month
      WHEN er.status = 'active'
        AND er.months_paid < er.payment_duration_months_at_creation  -- Use snapshot value
        AND er.next_payment_due <= p_current_month
      THEN true
      ELSE false
    END as should_process
  FROM public.employee_referrals er
  WHERE er.referred_employee_id = p_referred_employee_id
    AND er.status = 'active'
    AND er.months_paid < er.payment_duration_months_at_creation;  -- Use snapshot value
END;
$$;

COMMENT ON FUNCTION public.calculate_referral_bonus IS 'Calculates referral bonus using snapshot values from when referral was created, unaffected by settings changes';
