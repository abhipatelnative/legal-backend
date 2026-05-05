-- Add configurable email OTP expiry time to company_settings
ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS email_otp_expiry_minutes INTEGER NOT NULL DEFAULT 10;

COMMENT ON COLUMN public.company_settings.email_otp_expiry_minutes
  IS 'How many minutes an email OTP code stays valid (default 10).';
