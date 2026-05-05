-- Make to-do ownership user-based so every authenticated user can use My To-Do

ALTER TABLE public.employee_todos
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id);

-- Backfill owner from linked employee records for existing rows.
UPDATE public.employee_todos et
SET user_id = e.user_id
FROM public.employees e
WHERE et.employee_id = e.id
  AND et.user_id IS NULL
  AND e.user_id IS NOT NULL;

-- Fallback for legacy rows created before user_id ownership.
UPDATE public.employee_todos
SET user_id = created_by
WHERE user_id IS NULL
  AND created_by IS NOT NULL;

ALTER TABLE public.employee_todos
  ALTER COLUMN user_id SET DEFAULT auth.uid();

ALTER TABLE public.employee_todos
  ALTER COLUMN employee_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_employee_todos_user_status
  ON public.employee_todos(user_id, is_active, is_deleted, status);

CREATE INDEX IF NOT EXISTS idx_employee_todos_user_due_date
  ON public.employee_todos(user_id, due_date);

ALTER TABLE public.employee_todos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Employees can view their own todos" ON public.employee_todos;
DROP POLICY IF EXISTS "Employees can create their own todos" ON public.employee_todos;
DROP POLICY IF EXISTS "Employees can update their own todos" ON public.employee_todos;
DROP POLICY IF EXISTS "Users can view their own todos" ON public.employee_todos;
DROP POLICY IF EXISTS "Users can create their own todos" ON public.employee_todos;
DROP POLICY IF EXISTS "Users can update their own todos" ON public.employee_todos;

CREATE POLICY "Users can view their own todos"
  ON public.employee_todos
  FOR SELECT
  USING (
    user_id = auth.uid()
    OR (
      user_id IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.employees e
        WHERE e.id = employee_id
          AND e.user_id = auth.uid()
          AND e.is_active = true
          AND e.is_deleted = false
      )
    )
  );

CREATE POLICY "Users can create their own todos"
  ON public.employee_todos
  FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update their own todos"
  ON public.employee_todos
  FOR UPDATE
  USING (
    user_id = auth.uid()
    OR (
      user_id IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.employees e
        WHERE e.id = employee_id
          AND e.user_id = auth.uid()
          AND e.is_active = true
          AND e.is_deleted = false
      )
    )
  )
  WITH CHECK (user_id = auth.uid());
