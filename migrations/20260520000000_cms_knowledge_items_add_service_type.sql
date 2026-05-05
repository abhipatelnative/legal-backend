-- Allow 'service' as a third content_type alongside 'article' and 'blog' so the
-- Template 8 service detail pages can be authored with the same rich-text editor.

-- Drop the existing CHECK constraint (Postgres has no IF EXISTS clause for this
-- in older versions, so wrap in DO block to swallow the error).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema = 'public'
      AND table_name = 'cms_knowledge_items'
      AND constraint_name = 'cms_knowledge_items_content_type_check'
  ) THEN
    EXECUTE 'ALTER TABLE public.cms_knowledge_items DROP CONSTRAINT cms_knowledge_items_content_type_check';
  END IF;
END $$;

ALTER TABLE public.cms_knowledge_items
  ADD CONSTRAINT cms_knowledge_items_content_type_check
  CHECK (content_type IN ('article', 'blog', 'service'));

COMMENT ON COLUMN public.cms_knowledge_items.content_type IS
  'One of: article, blog, service. The shared rich-text editor authors all three.';
