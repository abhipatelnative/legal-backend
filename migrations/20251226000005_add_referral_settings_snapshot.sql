-- Add snapshot columns to employee_referrals to preserve original terms
-- This prevents changes to company_settings from affecting existing referrals

ALTER TABLE public.employee_referrals 
ADD COLUMN IF NOT EXISTS bonus_amount_at_creation numeric(15,2),
ADD COLUMN IF NOT EXISTS payment_duration_months_at_creation integer;

-- Update existing records with current settings values from company_settings
UPDATE public.employee_referrals er
SET 
  bonus_amount_at_creation = cs.referral_bonus_amount,
  payment_duration_months_at_creation = cs.referral_validity_months
FROM public.company_settings cs
WHERE er.bonus_amount_at_creation IS NULL
  AND cs.is_active = TRUE
  AND cs.is_deleted = FALSE;

-- Make these columns NOT NULL after populating
ALTER TABLE public.employee_referrals 
ALTER COLUMN bonus_amount_at_creation SET NOT NULL,
ALTER COLUMN payment_duration_months_at_creation SET NOT NULL;

-- Add comments
COMMENT ON COLUMN public.employee_referrals.bonus_amount_at_creation IS 'Monthly bonus amount that was configured when this referral was created';
COMMENT ON COLUMN public.employee_referrals.payment_duration_months_at_creation IS 'Payment duration (in months) that was configured when this referral was created';
