ALTER TABLE IF EXISTS public.service_master
ADD COLUMN IF NOT EXISTS legal_templates jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE IF EXISTS public.service_orders
ADD COLUMN IF NOT EXISTS legal_templates jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE TABLE IF NOT EXISTS public.service_order_document_fields (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  service_order_id uuid NOT NULL,
  document_template_id uuid NULL,
  field_name text NOT NULL,
  field_value text NULL,
  field_type text NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  created_by uuid NULL,
  updated_by uuid NULL,
  CONSTRAINT service_order_document_fields_pkey PRIMARY KEY (id),
  CONSTRAINT service_order_document_fields_service_order_id_fkey
    FOREIGN KEY (service_order_id) REFERENCES public.service_orders (id) ON DELETE CASCADE,
  CONSTRAINT service_order_document_fields_document_template_id_fkey
    FOREIGN KEY (document_template_id) REFERENCES public.document_templates (id) ON DELETE SET NULL,
  CONSTRAINT service_order_document_fields_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE SET NULL,
  CONSTRAINT service_order_document_fields_updated_by_fkey
    FOREIGN KEY (updated_by) REFERENCES auth.users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_service_order_document_fields_order_id
ON public.service_order_document_fields USING btree (service_order_id);

CREATE INDEX IF NOT EXISTS idx_service_order_document_fields_template_id
ON public.service_order_document_fields USING btree (document_template_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_service_order_document_fields_unique
ON public.service_order_document_fields USING btree (service_order_id, document_template_id, field_name);

WITH active_stage_templates AS (
  SELECT
    sm.id AS service_id,
    ss.stage_order,
    ss.id AS stage_id,
    doc.ordinality AS template_position,
    CASE
      WHEN jsonb_typeof(doc.entry) = 'object' THEN doc.entry ->> 'template_id'
      ELSE trim(both '"' from doc.entry::text)
    END AS template_id,
    COALESCE(
      NULLIF(doc.entry ->> 'language_code', ''),
      'en'
    ) AS language_code
  FROM public.service_master sm
  JOIN public.service_stages ss
    ON ss.service_id = sm.id
   AND ss.is_active = true
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(ss.stage_documents, '[]'::jsonb)) WITH ORDINALITY AS doc(entry, ordinality)
  WHERE COALESCE(ss.stage_documents, '[]'::jsonb) <> '[]'::jsonb
),
deduped_service_templates AS (
  SELECT DISTINCT ON (service_id, template_id, language_code)
    service_id,
    jsonb_build_object(
      'template_id', template_id,
      'language_code', language_code
    ) AS template_entry,
    stage_order,
    stage_id,
    template_position
  FROM active_stage_templates
  WHERE template_id IS NOT NULL
    AND template_id <> ''
  ORDER BY service_id, template_id, language_code, stage_order, stage_id, template_position
),
service_template_payloads AS (
  SELECT
    service_id,
    COALESCE(
      jsonb_agg(template_entry ORDER BY stage_order, stage_id, template_position),
      '[]'::jsonb
    ) AS legal_templates
  FROM deduped_service_templates
  GROUP BY service_id
)
UPDATE public.service_master sm
SET legal_templates = COALESCE(stp.legal_templates, '[]'::jsonb)
FROM service_template_payloads stp
WHERE sm.id = stp.service_id
  AND (
    sm.legal_templates IS NULL
    OR sm.legal_templates = '[]'::jsonb
  );

WITH order_stage_templates AS (
  SELECT
    so.id AS service_order_id,
    sos.stage_order,
    sos.id AS stage_instance_id,
    doc.ordinality AS template_position,
    CASE
      WHEN jsonb_typeof(doc.entry) = 'object' THEN doc.entry ->> 'template_id'
      ELSE trim(both '"' from doc.entry::text)
    END AS template_id,
    COALESCE(
      NULLIF(doc.entry ->> 'language_code', ''),
      'en'
    ) AS language_code
  FROM public.service_orders so
  JOIN public.service_order_stages sos
    ON sos.service_order_id = so.id
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(sos.stage_documents, '[]'::jsonb)) WITH ORDINALITY AS doc(entry, ordinality)
  WHERE COALESCE(sos.stage_documents, '[]'::jsonb) <> '[]'::jsonb
),
deduped_order_templates AS (
  SELECT DISTINCT ON (service_order_id, template_id, language_code)
    service_order_id,
    jsonb_build_object(
      'template_id', template_id,
      'language_code', language_code
    ) AS template_entry,
    stage_order,
    stage_instance_id,
    template_position
  FROM order_stage_templates
  WHERE template_id IS NOT NULL
    AND template_id <> ''
  ORDER BY service_order_id, template_id, language_code, stage_order, stage_instance_id, template_position
),
order_template_payloads AS (
  SELECT
    service_order_id,
    COALESCE(
      jsonb_agg(template_entry ORDER BY stage_order, stage_instance_id, template_position),
      '[]'::jsonb
    ) AS legal_templates
  FROM deduped_order_templates
  GROUP BY service_order_id
)
UPDATE public.service_orders so
SET legal_templates = CASE
  WHEN COALESCE(sm.legal_templates, '[]'::jsonb) <> '[]'::jsonb
    THEN sm.legal_templates
  ELSE COALESCE(otp.legal_templates, '[]'::jsonb)
END
FROM public.service_master sm,
     order_template_payloads otp
WHERE so.service_id = sm.id
  AND otp.service_order_id = so.id
  AND (
    so.legal_templates IS NULL
    OR so.legal_templates = '[]'::jsonb
  );
