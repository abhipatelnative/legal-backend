-- Create inquiry_tasks table for tasks created from inquiries
-- This is separate from service_order_tasks which is for service order related tasks

CREATE TABLE IF NOT EXISTS public.inquiry_tasks (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  inquiry_id uuid NOT NULL,
  task_name varchar(255) NOT NULL,
  description text,
  assigned_to uuid,
  status varchar(50) NOT NULL DEFAULT 'Not Started',
  priority varchar(20) NOT NULL DEFAULT 'Medium',
  due_date date,
  start_date date,
  completed_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_by uuid,
  is_active boolean NULL DEFAULT true,
  is_deleted boolean NULL DEFAULT false,
  CONSTRAINT inquiry_tasks_pkey PRIMARY KEY (id),
  CONSTRAINT inquiry_tasks_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id) ON DELETE CASCADE,
  CONSTRAINT inquiry_tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT inquiry_tasks_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id),
  CONSTRAINT inquiry_tasks_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id),
  CONSTRAINT inquiry_tasks_name_not_blank CHECK (length(btrim(task_name)) > 0),
  CONSTRAINT inquiry_tasks_status_check CHECK (status IN ('Not Started', 'In Progress', 'On Hold', 'Review', 'Completed')),
  CONSTRAINT inquiry_tasks_priority_check CHECK (priority IN ('Low', 'Medium', 'High'))
) TABLESPACE pg_default;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_inquiry_tasks_inquiry_id ON public.inquiry_tasks USING btree (inquiry_id);
CREATE INDEX IF NOT EXISTS idx_inquiry_tasks_assigned_to ON public.inquiry_tasks USING btree (assigned_to);
CREATE INDEX IF NOT EXISTS idx_inquiry_tasks_status ON public.inquiry_tasks USING btree (status);
CREATE INDEX IF NOT EXISTS idx_inquiry_tasks_due_date ON public.inquiry_tasks USING btree (due_date);
CREATE INDEX IF NOT EXISTS idx_inquiry_tasks_created_at ON public.inquiry_tasks USING btree (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inquiry_tasks_is_active ON public.inquiry_tasks USING btree (is_active);

-- Trigger for updated_at
DROP TRIGGER IF EXISTS update_inquiry_tasks_updated_at ON public.inquiry_tasks;
CREATE TRIGGER update_inquiry_tasks_updated_at
  BEFORE UPDATE ON public.inquiry_tasks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Enable RLS
ALTER TABLE public.inquiry_tasks ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Enable read access for authenticated users" ON public.inquiry_tasks
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Enable insert access for authenticated users" ON public.inquiry_tasks
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Enable update access for authenticated users" ON public.inquiry_tasks
  FOR UPDATE TO authenticated USING (true);

CREATE POLICY "Enable delete access for authenticated users" ON public.inquiry_tasks
  FOR DELETE TO authenticated USING (true);

-- Register permissions
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description, created_at, updated_at)
VALUES
  ('Inquiry Tasks Management', 'inquiry_tasks', true, true, true, true, 'Manage tasks created from inquiries', NOW(), NOW())
ON CONFLICT DO NOTHING;
