-- Add can_impersonate_users column to roles table
-- When true, users with this role can sign in as another user from the Users page
-- using a magic-link token (no password required). The button on the Users page
-- is gated by this flag. Frontend-only product control; not a security boundary.

ALTER TABLE IF EXISTS public.roles
ADD COLUMN IF NOT EXISTS can_impersonate_users BOOLEAN DEFAULT false;

COMMENT ON COLUMN public.roles.can_impersonate_users IS
  'When true, users with this role can sign in as another user from the Users page (no password). Frontend-only product control; not a security boundary.';
