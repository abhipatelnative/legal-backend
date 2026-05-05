
-- 1) Adjustment type enum (safe-create)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'adjustment_type') THEN
    CREATE TYPE public.adjustment_type AS ENUM ('addition', 'deduction');
  END IF;
END
$$;

-- 2) Add manual_adjustment_total to payroll (safe-add)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'payroll' AND column_name = 'manual_adjustment_total'
  ) THEN
    ALTER TABLE public.payroll
      ADD COLUMN manual_adjustment_total NUMERIC(15,2) NOT NULL DEFAULT 0;
  END IF;
END
$$;

-- 3) Create payroll_adjustments table
CREATE TABLE IF NOT EXISTS public.payroll_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payroll_period_id UUID NOT NULL REFERENCES public.payroll_periods(id) ON DELETE CASCADE,
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  label VARCHAR(100) NOT NULL,
  amount NUMERIC(15,2) NOT NULL CHECK (amount >= 0),
  adjustment_type public.adjustment_type NOT NULL, -- 'addition' | 'deduction'
  reason TEXT,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID,
  updated_by UUID
);

CREATE INDEX IF NOT EXISTS idx_payroll_adjustments_period ON public.payroll_adjustments(payroll_period_id);
CREATE INDEX IF NOT EXISTS idx_payroll_adjustments_employee ON public.payroll_adjustments(employee_id);

-- 4) RLS for payroll_adjustments
ALTER TABLE public.payroll_adjustments ENABLE ROW LEVEL SECURITY;

-- HR/Admin/Finance can manage all adjustments
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname='public' AND tablename='payroll_adjustments' AND policyname='HR can manage payroll adjustments'
  ) THEN
    CREATE POLICY "HR can manage payroll adjustments" ON public.payroll_adjustments
      FOR ALL USING (
        EXISTS (
          SELECT 1 FROM public.user_roles ur
          JOIN public.roles r ON ur.role_id = r.id
          WHERE ur.user_id = auth.uid()
            AND r.name IN ('HR Manager', 'Admin', 'Finance Manager')
            AND ur.is_active = true
        )
      );
  END IF;
END
$$;

-- Employees can view their own adjustments
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname='public' AND tablename='payroll_adjustments' AND policyname='Users can view their own payroll adjustments'
  ) THEN
    CREATE POLICY "Users can view their own payroll adjustments" ON public.payroll_adjustments
      FOR SELECT USING (
        EXISTS (
          SELECT 1 FROM public.employees e
          WHERE e.id = payroll_adjustments.employee_id AND e.user_id = auth.uid()
        )
      );
  END IF;
END
$$;

-- 5) Triggers to keep updated_at fresh
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'update_payroll_adjustments_updated_at'
  ) THEN
    CREATE TRIGGER update_payroll_adjustments_updated_at
      BEFORE UPDATE ON public.payroll_adjustments
      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END
$$;

-- 6) Helper to recalc a single payroll row from adjustments
CREATE OR REPLACE FUNCTION public.recalc_payroll_row(p_payroll_period_id uuid, p_employee_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_additions NUMERIC(15,2);
  v_deductions NUMERIC(15,2);
BEGIN
  SELECT 
    COALESCE(SUM(CASE WHEN adjustment_type = 'addition' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN adjustment_type = 'deduction' THEN amount ELSE 0 END), 0)
  INTO v_additions, v_deductions
  FROM public.payroll_adjustments
  WHERE payroll_period_id = p_payroll_period_id
    AND employee_id = p_employee_id
    AND is_active = true
    AND is_deleted = false;

  UPDATE public.payroll
  SET
    manual_adjustment_total = COALESCE(v_additions - v_deductions, 0),
    net_salary = (COALESCE(gross_salary, 0) - COALESCE(total_deductions, 0)) + COALESCE(v_additions - v_deductions, 0),
    updated_at = CURRENT_TIMESTAMP,
    updated_by = auth.uid()
  WHERE payroll_period_id = p_payroll_period_id
    AND employee_id = p_employee_id;

  RETURN TRUE;
END;
$$;

-- 7) RPC to apply an adjustment and recalc the payroll row
CREATE OR REPLACE FUNCTION public.apply_payroll_adjustment(
  p_payroll_period_id uuid,
  p_employee_id uuid,
  p_amount numeric,
  p_adjustment_type public.adjustment_type,
  p_label text,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.payroll_adjustments (
    payroll_period_id, employee_id, amount, adjustment_type, label, reason, created_by, updated_by
  ) VALUES (
    p_payroll_period_id, p_employee_id, p_amount, p_adjustment_type, p_label, p_reason, auth.uid(), auth.uid()
  );

  PERFORM public.recalc_payroll_row(p_payroll_period_id, p_employee_id);

  RETURN TRUE;
END;
$$;

-- 8) Finalize a period (locks editing by status in UI; RLS already restricts to HR)
CREATE OR REPLACE FUNCTION public.finalize_payroll_period(p_payroll_period_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.payroll_periods
  SET status = 'confirmed',
      confirmed_at = CURRENT_TIMESTAMP,
      confirmed_by = auth.uid(),
      updated_at = CURRENT_TIMESTAMP,
      updated_by = auth.uid()
  WHERE id = p_payroll_period_id;

  UPDATE public.payroll
  SET status = 'confirmed',
      updated_at = CURRENT_TIMESTAMP,
      updated_by = auth.uid()
  WHERE payroll_period_id = p_payroll_period_id;

  RETURN TRUE;
END;
$$;

-- 9) Mark a whole period as paid (record on each payroll row)
CREATE OR REPLACE FUNCTION public.mark_payroll_paid(
  p_payroll_period_id uuid,
  p_payment_method text DEFAULT NULL,
  p_transaction_id text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.payroll
  SET paid_at = CURRENT_TIMESTAMP,
      payment_method = COALESCE(p_payment_method, payment_method),
      transaction_id = COALESCE(p_transaction_id, transaction_id),
      updated_at = CURRENT_TIMESTAMP,
      updated_by = auth.uid()
  WHERE payroll_period_id = p_payroll_period_id;

  RETURN TRUE;
END;
$$;

-- 10) Auto-create current month period daily via pg_cron (idempotent)
-- Enable pg_cron if not enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule a daily run at 00:05 server time to ensure the current month period exists
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'auto-create-payroll-period') THEN
    PERFORM cron.schedule(
      'auto-create-payroll-period',
      '5 0 * * *',
      'SELECT public.auto_create_current_month_period();'
    );
  END IF;
END
$$;
