-- Create inquiry_notes table for adding notes/remarks to inquiries

CREATE TABLE IF NOT EXISTS public.inquiry_notes (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  inquiry_id uuid NOT NULL,
  note_text text NOT NULL,
  created_by uuid NULL,
  created_at timestamp with time zone NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamp with time zone NULL DEFAULT CURRENT_TIMESTAMP,
  updated_by uuid NULL,
  is_active boolean NULL DEFAULT true,
  is_deleted boolean NULL DEFAULT false,
  CONSTRAINT inquiry_notes_pkey PRIMARY KEY (id),
  CONSTRAINT inquiry_notes_inquiry_id_fkey FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id) ON DELETE CASCADE,
  CONSTRAINT inquiry_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id),
  CONSTRAINT inquiry_notes_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id),
  CONSTRAINT inquiry_notes_text_not_blank CHECK (length(btrim(note_text)) > 0)
) TABLESPACE pg_default;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_inquiry_notes_inquiry_id ON public.inquiry_notes USING btree (inquiry_id);
CREATE INDEX IF NOT EXISTS idx_inquiry_notes_created_at ON public.inquiry_notes USING btree (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inquiry_notes_is_active ON public.inquiry_notes USING btree (is_active);

-- Enable RLS
ALTER TABLE public.inquiry_notes ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Enable read access for authenticated users" ON public.inquiry_notes
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "Enable insert access for authenticated users" ON public.inquiry_notes
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Enable update access for authenticated users" ON public.inquiry_notes
  FOR UPDATE TO authenticated USING (true);

CREATE POLICY "Enable delete access for authenticated users" ON public.inquiry_notes
  FOR DELETE TO authenticated USING (true);

-- Register permissions
INSERT INTO public.permissions (name, module, can_view, can_add, can_edit, can_delete, description, created_at, updated_at)
VALUES
  ('Inquiry Notes Management', 'inquiry_notes', true, true, true, true, 'Manage notes/remarks on inquiries', NOW(), NOW())
ON CONFLICT DO NOTHING;
