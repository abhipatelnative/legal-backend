-- Create notice_penalties table
CREATE TABLE IF NOT EXISTS public.notice_penalties (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL,
  penalty_date date NOT NULL,
  amount numeric(10, 2) NOT NULL,
  reason text NOT NULL,
  deduction_month date NOT NULL, -- Stored as first day of month
  is_active boolean NULL DEFAULT true,
  is_deleted boolean NULL DEFAULT false,
  created_at timestamp with time zone NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamp with time zone NULL DEFAULT CURRENT_TIMESTAMP,
  created_by uuid NULL,
  updated_by uuid NULL,
  CONSTRAINT notice_penalties_pkey PRIMARY KEY (id),
  CONSTRAINT notice_penalties_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT notice_penalties_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id),
  CONSTRAINT notice_penalties_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id)
) TABLESPACE pg_default;

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_notice_penalties_employee_id ON public.notice_penalties USING btree (employee_id);
CREATE INDEX IF NOT EXISTS idx_notice_penalties_deduction_month ON public.notice_penalties USING btree (deduction_month);
CREATE INDEX IF NOT EXISTS idx_notice_penalties_is_active ON public.notice_penalties USING btree (is_active);

-- Enable RLS
ALTER TABLE public.notice_penalties ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Enable read access for authenticated users" ON public.notice_penalties
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Enable insert access for authenticated users" ON public.notice_penalties
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Enable update access for authenticated users" ON public.notice_penalties
  FOR UPDATE
  TO authenticated
  USING (true);

CREATE POLICY "Enable delete access for authenticated users" ON public.notice_penalties
  FOR DELETE
  TO authenticated
  USING (true);

-- Insert Permission
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description, created_at, updated_at)
VALUES 
  ('Notice Penalties Management', 'notice_penalties', true, true, true, true, 'Manage employee notice period penalties', NOW(), NOW())
ON CONFLICT DO NOTHING;
