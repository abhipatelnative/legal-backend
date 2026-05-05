-- Allow empty allowed_2fa_methods so admins can disable 2FA entirely
ALTER TABLE public.company_settings
  DROP CONSTRAINT IF EXISTS company_settings_allowed_2fa_methods_check;

ALTER TABLE public.company_settings
  ADD CONSTRAINT company_settings_allowed_2fa_methods_check
  CHECK (
    allowed_2fa_methods <@ ARRAY['totp', 'email']::TEXT[]
  );
