ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS enforce_2fa_all BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS enforce_2fa_role_ids UUID[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS allowed_2fa_methods TEXT[] NOT NULL DEFAULT ARRAY['totp', 'email'];

ALTER TABLE public.company_settings
  DROP CONSTRAINT IF EXISTS company_settings_allowed_2fa_methods_check;

ALTER TABLE public.company_settings
  ADD CONSTRAINT company_settings_allowed_2fa_methods_check
  CHECK (
    cardinality(allowed_2fa_methods) >= 1
    AND allowed_2fa_methods <@ ARRAY['totp', 'email']::TEXT[]
  );

CREATE TABLE IF NOT EXISTS public.user_two_factor_preferences (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  primary_method TEXT NULL CHECK (primary_method IN ('totp', 'email')),
  totp_enabled BOOLEAN NOT NULL DEFAULT false,
  email_enabled BOOLEAN NOT NULL DEFAULT false,
  recovery_codes_generated_at TIMESTAMPTZ NULL,
  last_verified_method TEXT NULL CHECK (last_verified_method IN ('totp', 'email', 'recovery')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID NULL REFERENCES auth.users(id),
  updated_by UUID NULL REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.user_two_factor_email_challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  purpose TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 5,
  blocked_until TIMESTAMPTZ NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ NULL,
  session_key TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID NULL REFERENCES auth.users(id),
  updated_by UUID NULL REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.user_two_factor_recovery_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL,
  used_at TIMESTAMPTZ NULL,
  expires_at TIMESTAMPTZ NULL,
  batch_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID NULL REFERENCES auth.users(id),
  updated_by UUID NULL REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.security_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_user_id UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_company_settings_enforce_2fa_all
  ON public.company_settings (enforce_2fa_all);

CREATE INDEX IF NOT EXISTS idx_user_two_factor_email_challenges_user_id
  ON public.user_two_factor_email_challenges (user_id, purpose, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_two_factor_email_challenges_expires_at
  ON public.user_two_factor_email_challenges (expires_at);

CREATE INDEX IF NOT EXISTS idx_user_two_factor_recovery_codes_user_id
  ON public.user_two_factor_recovery_codes (user_id, batch_id);

CREATE INDEX IF NOT EXISTS idx_security_audit_log_user_id
  ON public.security_audit_log (user_id, created_at DESC);

ALTER TABLE public.user_two_factor_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_two_factor_email_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_two_factor_recovery_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_audit_log ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_two_factor_preferences'
      AND policyname = 'Users can view own 2fa preferences'
  ) THEN
    CREATE POLICY "Users can view own 2fa preferences"
      ON public.user_two_factor_preferences
      FOR SELECT
      USING (auth.uid() = user_id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_two_factor_preferences'
      AND policyname = 'Users can update own 2fa preferences'
  ) THEN
    CREATE POLICY "Users can update own 2fa preferences"
      ON public.user_two_factor_preferences
      FOR UPDATE
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_user_two_factor_preferences_updated_at'
  ) THEN
    CREATE TRIGGER update_user_two_factor_preferences_updated_at
      BEFORE UPDATE ON public.user_two_factor_preferences
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_user_two_factor_email_challenges_updated_at'
  ) THEN
    CREATE TRIGGER update_user_two_factor_email_challenges_updated_at
      BEFORE UPDATE ON public.user_two_factor_email_challenges
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_user_two_factor_recovery_codes_updated_at'
  ) THEN
    CREATE TRIGGER update_user_two_factor_recovery_codes_updated_at
      BEFORE UPDATE ON public.user_two_factor_recovery_codes
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;
