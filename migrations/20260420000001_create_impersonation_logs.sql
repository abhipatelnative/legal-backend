-- Audit table for "sign in as user" events triggered from the Users page.
-- A row is inserted (best-effort, from the client) every time a user with
-- can_impersonate_users=true successfully mints a magic-link for another user.

CREATE TABLE IF NOT EXISTS public.impersonation_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id   UUID NOT NULL REFERENCES auth.users(id),
  target_user_id  UUID NOT NULL REFERENCES auth.users(id),
  actor_role_name TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_agent      TEXT
);

CREATE INDEX IF NOT EXISTS idx_impersonation_logs_actor
  ON public.impersonation_logs(actor_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_impersonation_logs_target
  ON public.impersonation_logs(target_user_id, created_at DESC);

ALTER TABLE public.impersonation_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "log impersonation events" ON public.impersonation_logs;
CREATE POLICY "log impersonation events" ON public.impersonation_logs
  FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "impersonators read impersonation logs" ON public.impersonation_logs;
CREATE POLICY "impersonators read impersonation logs" ON public.impersonation_logs
  FOR SELECT USING (
    EXISTS (
      SELECT 1
        FROM public.user_roles ur
        JOIN public.roles r ON r.id = ur.role_id
       WHERE ur.user_id = auth.uid()
         AND ur.is_deleted = false
         AND r.is_deleted = false
         AND r.can_impersonate_users = true
    )
  );
