-- ============================================================================
-- Add role-based access restriction to leave_types
-- ============================================================================
-- When restrict_to_roles is true, only users whose role_id is linked in
-- leave_type_roles can see and apply this leave type. When false, all roles
-- with a leave balance can see it (existing behaviour).
-- ============================================================================

ALTER TABLE public.leave_types
  ADD COLUMN IF NOT EXISTS restrict_to_roles BOOLEAN DEFAULT false;

COMMENT ON COLUMN public.leave_types.restrict_to_roles IS
  'When true, leave type is visible only to roles listed in leave_type_roles';

CREATE TABLE IF NOT EXISTS public.leave_type_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  leave_type_id UUID NOT NULL REFERENCES public.leave_types(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  UNIQUE(leave_type_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_leave_type_roles_leave_type_id
  ON public.leave_type_roles(leave_type_id);
CREATE INDEX IF NOT EXISTS idx_leave_type_roles_role_id
  ON public.leave_type_roles(role_id);
