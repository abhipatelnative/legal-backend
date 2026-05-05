-- Employee self-service to-do list (initial employee-linked version)

CREATE TABLE IF NOT EXISTS public.employee_todos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  priority VARCHAR(20) NOT NULL DEFAULT 'medium',
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  due_date DATE,
  completed_at TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  CONSTRAINT employee_todos_title_not_blank CHECK (length(btrim(title)) > 0),
  CONSTRAINT employee_todos_priority_check CHECK (priority IN ('low', 'medium', 'high')),
  CONSTRAINT employee_todos_status_check CHECK (status IN ('pending', 'in_progress', 'done'))
);

CREATE INDEX IF NOT EXISTS idx_employee_todos_employee_status
  ON public.employee_todos(employee_id, is_active, is_deleted, status);

CREATE INDEX IF NOT EXISTS idx_employee_todos_employee_due_date
  ON public.employee_todos(employee_id, due_date);

CREATE INDEX IF NOT EXISTS idx_employee_todos_created_at
  ON public.employee_todos(created_at DESC);

DROP TRIGGER IF EXISTS update_employee_todos_updated_at ON public.employee_todos;
CREATE TRIGGER update_employee_todos_updated_at
  BEFORE UPDATE ON public.employee_todos
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.employee_todos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Employees can view their own todos" ON public.employee_todos;
CREATE POLICY "Employees can view their own todos"
  ON public.employee_todos
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.employees e
      WHERE e.id = employee_id
        AND e.user_id = auth.uid()
        AND e.is_active = true
        AND e.is_deleted = false
    )
  );

DROP POLICY IF EXISTS "Employees can create their own todos" ON public.employee_todos;
CREATE POLICY "Employees can create their own todos"
  ON public.employee_todos
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.employees e
      WHERE e.id = employee_id
        AND e.user_id = auth.uid()
        AND e.is_active = true
        AND e.is_deleted = false
    )
  );

DROP POLICY IF EXISTS "Employees can update their own todos" ON public.employee_todos;
CREATE POLICY "Employees can update their own todos"
  ON public.employee_todos
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.employees e
      WHERE e.id = employee_id
        AND e.user_id = auth.uid()
        AND e.is_active = true
        AND e.is_deleted = false
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.employees e
      WHERE e.id = employee_id
        AND e.user_id = auth.uid()
        AND e.is_active = true
        AND e.is_deleted = false
    )
  );

INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description)
VALUES (
  'Employee To-Do',
  'employee_todos',
  true,
  true,
  true,
  true,
  'Employee self-service to-do list access'
)
ON CONFLICT (name)
DO UPDATE SET
  module = EXCLUDED.module,
  can_view = EXCLUDED.can_view,
  can_add = EXCLUDED.can_add,
  can_edit = EXCLUDED.can_edit,
  can_delete = EXCLUDED.can_delete,
  description = EXCLUDED.description,
  is_active = true,
  is_deleted = false,
  updated_at = CURRENT_TIMESTAMP;

DO $$
DECLARE
  v_employee_role_id UUID;
  v_permission_id UUID;
BEGIN
  SELECT id
  INTO v_employee_role_id
  FROM public.roles
  WHERE name = 'Employee'
    AND is_active = true
    AND is_deleted = false
  LIMIT 1;

  SELECT id
  INTO v_permission_id
  FROM public.permissions
  WHERE name = 'Employee To-Do'
    AND is_active = true
    AND is_deleted = false
  LIMIT 1;

  IF v_employee_role_id IS NOT NULL AND v_permission_id IS NOT NULL THEN
    INSERT INTO public.role_permissions (role_id, permission_id, is_active, is_deleted)
    VALUES (v_employee_role_id, v_permission_id, true, false)
    ON CONFLICT (role_id, permission_id)
    DO UPDATE SET
      is_active = true,
      is_deleted = false,
      updated_at = CURRENT_TIMESTAMP;
  END IF;
END $$;
