-- Add enable_event_notifications column to smtp_settings table
-- This field controls whether event notification emails should be sent

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'smtp_settings' 
    AND column_name = 'enable_event_notifications'
  ) THEN
    ALTER TABLE public.smtp_settings 
    ADD COLUMN enable_event_notifications BOOLEAN DEFAULT true;
    
    COMMENT ON COLUMN public.smtp_settings.enable_event_notifications IS 
    'Enable or disable sending event notification emails to employees';
  END IF;
END $$;


