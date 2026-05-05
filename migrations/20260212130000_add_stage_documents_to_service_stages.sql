ALTER TABLE IF EXISTS public.service_stages 
ADD COLUMN IF NOT EXISTS stage_documents jsonb DEFAULT '[]'::jsonb;
