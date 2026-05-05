ALTER TABLE public.user_two_factor_preferences
  ADD COLUMN IF NOT EXISTS mfa_opt_out BOOLEAN NOT NULL DEFAULT false;