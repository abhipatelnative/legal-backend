-- Add days_before_event column to smtp_settings table
-- This field determines how many days before an event to send email notifications

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'smtp_settings' 
    AND column_name = 'days_before_event'
  ) THEN
    ALTER TABLE public.smtp_settings 
    ADD COLUMN days_before_event INTEGER DEFAULT 7 
    CHECK (days_before_event >= 0 AND days_before_event <= 365);
    
    COMMENT ON COLUMN public.smtp_settings.days_before_event IS 
    'Number of days before an event to send email notifications to employees';
  END IF;
END $$;

-- Create table to track sent event notifications (prevent duplicate emails)
CREATE TABLE IF NOT EXISTS public.event_notification_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.company_events(id) ON DELETE CASCADE,
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  notification_date DATE NOT NULL,
  event_date DATE NOT NULL,
  email_sent_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  email_status VARCHAR(20) DEFAULT 'sent' CHECK (email_status IN ('sent', 'failed', 'pending')),
  error_message TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(event_id, employee_id, notification_date)
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_event_notification_log_event 
  ON public.event_notification_log(event_id);
CREATE INDEX IF NOT EXISTS idx_event_notification_log_employee 
  ON public.event_notification_log(employee_id);
CREATE INDEX IF NOT EXISTS idx_event_notification_log_date 
  ON public.event_notification_log(notification_date);

COMMENT ON TABLE public.event_notification_log IS 
'Logs all event notification emails sent to employees to prevent duplicates';



