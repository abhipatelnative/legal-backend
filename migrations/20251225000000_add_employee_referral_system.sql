-- Migration: Add Employee Referral System
-- Description: Adds referral tracking functionality including company settings and employee referral tracking
-- Date: 2025-12-25

-- ============================================================================
-- 1. Add referral configuration fields to company_settings table
-- ============================================================================

-- Add referral enable toggle
ALTER TABLE public.company_settings
ADD COLUMN IF NOT EXISTS enable_employee_referral BOOLEAN NULL DEFAULT FALSE;

-- Add referral amount field
ALTER TABLE public.company_settings
ADD COLUMN IF NOT EXISTS referral_bonus_amount NUMERIC(15, 2) NULL DEFAULT 0;

-- Add referral duration (validity period in months)
ALTER TABLE public.company_settings
ADD COLUMN IF NOT EXISTS referral_validity_months INTEGER NULL DEFAULT 6;

-- Add comment for documentation
COMMENT ON COLUMN public.company_settings.enable_employee_referral IS 'Enable/disable employee referral program';
COMMENT ON COLUMN public.company_settings.referral_bonus_amount IS 'Default referral bonus amount to be paid to referring employee';
COMMENT ON COLUMN public.company_settings.referral_validity_months IS 'Number of months the referral bonus remains valid';

-- ============================================================================
-- 2. Add referred_by field to employees table
-- ============================================================================

-- Add column to track which employee referred this employee
ALTER TABLE public.employees
ADD COLUMN IF NOT EXISTS referred_by_employee_id UUID NULL;

-- Add foreign key constraint (skip if already exists)
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'employees_referred_by_employee_id_fkey'
      AND table_name = 'employees'
  ) THEN
    ALTER TABLE public.employees
    ADD CONSTRAINT employees_referred_by_employee_id_fkey 
    FOREIGN KEY (referred_by_employee_id) 
    REFERENCES public.employees(id) 
    ON DELETE SET NULL;
  END IF;
END $$;

-- Add index for better query performance
CREATE INDEX IF NOT EXISTS idx_employees_referred_by 
ON public.employees USING btree (referred_by_employee_id) 
TABLESPACE pg_default;

-- Add comment for documentation
COMMENT ON COLUMN public.employees.referred_by_employee_id IS 'ID of the employee who referred this employee';

-- ============================================================================
-- 3. Create employee_referrals table for tracking referral bonuses
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.employee_referrals (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  referring_employee_id UUID NOT NULL,
  referred_employee_id UUID NOT NULL,
  referral_bonus_amount NUMERIC(15, 2) NOT NULL DEFAULT 0,
  referral_date DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_until DATE NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  paid_amount NUMERIC(15, 2) NULL DEFAULT 0,
  transaction_id VARCHAR(255) NULL,
  remarks TEXT NULL,
  is_active BOOLEAN NULL DEFAULT TRUE,
  is_deleted BOOLEAN NULL DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID NULL,
  updated_by UUID NULL,
  
  -- Primary key
  CONSTRAINT employee_referrals_pkey PRIMARY KEY (id),
  
  -- Foreign keys
  CONSTRAINT employee_referrals_referring_employee_id_fkey 
    FOREIGN KEY (referring_employee_id) 
    REFERENCES public.employees(id) 
    ON DELETE CASCADE,
  
  CONSTRAINT employee_referrals_referred_employee_id_fkey 
    FOREIGN KEY (referred_employee_id) 
    REFERENCES public.employees(id) 
    ON DELETE CASCADE,
  
  CONSTRAINT employee_referrals_created_by_fkey 
    FOREIGN KEY (created_by) 
    REFERENCES auth.users(id),
  
  CONSTRAINT employee_referrals_updated_by_fkey 
    FOREIGN KEY (updated_by) 
    REFERENCES auth.users(id),
  
  -- Unique constraint: one referral record per referred employee
  CONSTRAINT employee_referrals_referred_employee_id_key 
    UNIQUE (referred_employee_id),
  
  -- Check constraints
  CONSTRAINT employee_referrals_status_check 
    CHECK (status IN ('pending', 'approved', 'paid', 'cancelled', 'expired')),
  
  CONSTRAINT employee_referrals_positive_amounts 
    CHECK (
      referral_bonus_amount >= 0 
      AND paid_amount >= 0 
      AND paid_amount <= referral_bonus_amount
    ),
  
  CONSTRAINT employee_referrals_no_self_referral 
    CHECK (referring_employee_id != referred_employee_id)
) TABLESPACE pg_default;

-- Add indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_employee_referrals_referring_employee 
ON public.employee_referrals USING btree (referring_employee_id) 
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_employee_referrals_referred_employee 
ON public.employee_referrals USING btree (referred_employee_id) 
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_employee_referrals_status 
ON public.employee_referrals USING btree (status, is_active, is_deleted) 
TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_employee_referrals_dates 
ON public.employee_referrals USING btree (referral_date, valid_until) 
TABLESPACE pg_default;

-- Add comments for documentation
COMMENT ON TABLE public.employee_referrals IS 'Tracks employee referral bonuses and their payment status';
COMMENT ON COLUMN public.employee_referrals.referring_employee_id IS 'Employee who made the referral';
COMMENT ON COLUMN public.employee_referrals.referred_employee_id IS 'Employee who was referred';
COMMENT ON COLUMN public.employee_referrals.referral_bonus_amount IS 'Total bonus amount for this referral';
COMMENT ON COLUMN public.employee_referrals.valid_until IS 'Date until which the referral bonus is valid';
COMMENT ON COLUMN public.employee_referrals.status IS 'Status: pending, approved, paid, cancelled, expired';
COMMENT ON COLUMN public.employee_referrals.paid_amount IS 'Amount already paid (for partial payments)';

-- ============================================================================
-- 4. Create trigger for updated_at column
-- ============================================================================

DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.triggers 
    WHERE trigger_name = 'update_employee_referrals_updated_at'
      AND event_object_table = 'employee_referrals'
  ) THEN
    CREATE TRIGGER update_employee_referrals_updated_at
    BEFORE UPDATE ON public.employee_referrals
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
  END IF;
END $$;

-- ============================================================================
-- 5. Create trigger for audit logging
-- ============================================================================

DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.triggers 
    WHERE trigger_name = 'audit_employee_referrals'
      AND event_object_table = 'employee_referrals'
  ) THEN
    CREATE TRIGGER audit_employee_referrals
    AFTER INSERT OR UPDATE OR DELETE ON public.employee_referrals
    FOR EACH ROW
    EXECUTE FUNCTION create_audit_log();
  END IF;
END $$;

-- ============================================================================
-- 6. Create function to automatically create referral record
-- ============================================================================

CREATE OR REPLACE FUNCTION public.auto_create_referral_record()
RETURNS TRIGGER AS $$
DECLARE
  v_referral_amount NUMERIC(15, 2);
  v_validity_months INTEGER;
  v_valid_until DATE;
  v_referral_enabled BOOLEAN;
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
  
  -- Get referral settings from company_settings
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
    -- Calculate valid_until date
    v_valid_until := CURRENT_DATE + (v_validity_months || ' months')::INTERVAL;
    
    -- Create referral record
    INSERT INTO public.employee_referrals (
      referring_employee_id,
      referred_employee_id,
      referral_bonus_amount,
      referral_date,
      valid_until,
      status,
      created_by
    ) VALUES (
      NEW.referred_by_employee_id,
      NEW.id,
      COALESCE(v_referral_amount, 0),
      CURRENT_DATE,
      v_valid_until,
      'pending',
      COALESCE(NEW.updated_by, NEW.created_by)
    )
    ON CONFLICT (referred_employee_id) DO NOTHING;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add trigger to employees table for both INSERT and UPDATE
DROP TRIGGER IF EXISTS trigger_auto_create_referral_record ON public.employees;
CREATE TRIGGER trigger_auto_create_referral_record
AFTER INSERT OR UPDATE OF referred_by_employee_id ON public.employees
FOR EACH ROW
EXECUTE FUNCTION auto_create_referral_record();

-- ============================================================================
-- 7. Create helper function to check if referring employee can receive bonus
-- ============================================================================

CREATE OR REPLACE FUNCTION public.can_edit_employee_referral(p_employee_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_has_paid_bonus BOOLEAN;
BEGIN
  -- Check if there's any paid referral bonus for this employee as the referring employee
  SELECT EXISTS (
    SELECT 1
    FROM public.employee_referrals
    WHERE referring_employee_id = p_employee_id
      AND status = 'paid'
      AND is_active = TRUE
      AND is_deleted = FALSE
  ) INTO v_has_paid_bonus;
  
  -- Return TRUE if no paid bonus exists (can edit), FALSE otherwise
  RETURN NOT v_has_paid_bonus;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.can_edit_employee_referral(UUID) IS 'Check if employee referral can be edited (returns TRUE if referring employee has not received any bonus yet)';
