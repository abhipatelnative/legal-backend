-- Add probation_active column to contracts table
ALTER TABLE public.contracts 
ADD COLUMN IF NOT EXISTS probation_active BOOLEAN DEFAULT false;

-- Update existing contracts based on probation_period
UPDATE public.contracts 
SET probation_active = CASE 
  WHEN probation_period > 0 THEN true 
  ELSE false 
END
WHERE probation_period IS NOT NULL;

-- Function to manage probation status daily
CREATE OR REPLACE FUNCTION public.manage_probation_status()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  contract_record RECORD;
  today_date DATE := CURRENT_DATE;
  probation_end_date DATE;
BEGIN
  -- Get all active contracts with probation ON
  FOR contract_record IN 
    SELECT id, employee_id, start_date, probation_period
    FROM public.contracts
    WHERE status = 'active'
    AND is_active = true
    AND is_deleted = false
    AND probation_active = true
    AND probation_period IS NOT NULL
    AND probation_period > 0
  LOOP
    -- Calculate probation end date from contract start date + probation months
    probation_end_date := contract_record.start_date + (contract_record.probation_period || ' months')::INTERVAL;
    
    -- Check if probation period completed (current date >= probation end date)
    IF today_date >= probation_end_date THEN
      -- Turn OFF probation status
      UPDATE public.contracts 
      SET probation_active = false, updated_at = CURRENT_TIMESTAMP
      WHERE id = contract_record.id;
      
      -- Probation completed - leave management handled by frontend
    END IF;
  END LOOP;
END;
$$;

-- Create cron job
SELECT cron.schedule(
  'daily-probation-check',
  '0 3 * * *',
  'SELECT public.manage_probation_status();'
);

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.manage_probation_status() TO authenticated;