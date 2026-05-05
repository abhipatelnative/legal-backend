-- Update the existing trigger function to snapshot referral settings at creation time
-- This ensures existing referrals keep their original terms even when company_settings change

CREATE OR REPLACE FUNCTION public.auto_create_referral_record()
RETURNS TRIGGER AS $$
DECLARE
  v_referral_amount NUMERIC(15, 2);
  v_validity_months INTEGER;
  v_valid_until DATE;
  v_referral_enabled BOOLEAN;
  v_hire_date DATE;
BEGIN
  -- For UPDATE: Only proceed if referred_by_employee_id was added (changed from NULL to a value)
  IF TG_OP = 'UPDATE' THEN
    -- Skip if referred_by_employee_id didn't change or was removed
    IF OLD.referred_by_employee_id IS NOT DISTINCT FROM NEW.referred_by_employee_id THEN
      RETURN NEW;
    END IF;
    -- Skip if referral was removed (changed to NULL)
    IF NEW.referred_by_employee_id IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;
  
  -- For INSERT: Only proceed if referred_by_employee_id is set
  IF TG_OP = 'INSERT' AND NEW.referred_by_employee_id IS NULL THEN
    RETURN NEW;
  END IF;
  
  -- Get referral settings from company_settings (SNAPSHOT these values)
  SELECT 
    enable_employee_referral,
    referral_bonus_amount,
    referral_validity_months
  INTO 
    v_referral_enabled,
    v_referral_amount,
    v_validity_months
  FROM public.company_settings
  WHERE is_active = TRUE AND is_deleted = FALSE
  LIMIT 1;
  
  -- Only create referral record if referral program is enabled
  IF v_referral_enabled IS TRUE THEN
    -- Use defaults if settings not found
    v_referral_amount := COALESCE(v_referral_amount, 1000.00);
    v_validity_months := COALESCE(v_validity_months, 12);
    
    -- Calculate valid_until date
    v_valid_until := CURRENT_DATE + (v_validity_months || ' months')::INTERVAL;
    
    -- Get hire date for next_payment_due
    v_hire_date := COALESCE(NEW.hire_date, CURRENT_DATE);
    
    -- Create referral record with SNAPSHOT of current settings
    INSERT INTO public.employee_referrals (
      referring_employee_id,
      referred_employee_id,
      referral_bonus_amount,
      bonus_amount_at_creation,          -- SNAPSHOT: Store current bonus amount
      payment_duration_months_at_creation, -- SNAPSHOT: Store current duration
      referral_date,
      valid_until,
      status,
      months_paid,
      last_paid_month,
      next_payment_due,
      created_by
    ) VALUES (
      NEW.referred_by_employee_id,
      NEW.id,
      COALESCE(v_referral_amount, 0),
      v_referral_amount,                 -- SNAPSHOT VALUE
      v_validity_months,                 -- SNAPSHOT VALUE
      CURRENT_DATE,
      v_valid_until,
      'pending',
      0,                                 -- Start with 0 months paid
      NULL,                              -- No payments yet
      v_hire_date,                       -- First payment due on hire date
      COALESCE(NEW.updated_by, NEW.created_by)
    )
    ON CONFLICT (referred_employee_id) DO NOTHING;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.auto_create_referral_record IS 'Automatically creates referral record with snapshot of current company_settings when referred_by_employee_id is set';
