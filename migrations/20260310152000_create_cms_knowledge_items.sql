-- Dynamic CMS knowledge content for public T1 website.
-- Supports both articles and blogs from a single managed table.

CREATE TABLE IF NOT EXISTS public.cms_knowledge_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content_type TEXT NOT NULL CHECK (content_type IN ('article', 'blog')),
  title TEXT NOT NULL,
  slug TEXT NOT NULL,
  excerpt TEXT NOT NULL,
  content_html TEXT NOT NULL,
  image_url TEXT,
  image_path TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_cms_knowledge_items_type
ON public.cms_knowledge_items (content_type);

CREATE INDEX IF NOT EXISTS idx_cms_knowledge_items_active
ON public.cms_knowledge_items (is_active, is_deleted);

CREATE UNIQUE INDEX IF NOT EXISTS ux_cms_knowledge_items_type_slug_not_deleted
ON public.cms_knowledge_items (content_type, slug)
WHERE is_deleted = FALSE;

-- Keep updated_at synchronized for updates.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'update_updated_at_column'
      AND pronamespace = 'public'::regnamespace
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_cms_knowledge_items_updated_at'
      AND tgrelid = 'public.cms_knowledge_items'::regclass
  ) THEN
    CREATE TRIGGER update_cms_knowledge_items_updated_at
      BEFORE UPDATE ON public.cms_knowledge_items
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

ALTER TABLE public.cms_knowledge_items ENABLE ROW LEVEL SECURITY;

-- Public site can read only active and non-deleted rows.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'cms_knowledge_items'
      AND policyname = 'Public can view active cms knowledge items'
  ) THEN
    CREATE POLICY "Public can view active cms knowledge items"
    ON public.cms_knowledge_items
    FOR SELECT
    USING (is_active = TRUE AND is_deleted = FALSE);
  END IF;
END $$;

-- Authenticated users can manage CMS records from admin panel.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'cms_knowledge_items'
      AND policyname = 'Authenticated can manage cms knowledge items'
  ) THEN
    CREATE POLICY "Authenticated can manage cms knowledge items"
    ON public.cms_knowledge_items
    FOR ALL
    TO authenticated
    USING (TRUE)
    WITH CHECK (TRUE);
  END IF;
END $$;

COMMENT ON TABLE public.cms_knowledge_items IS
'Stores dynamic website article/blog entries managed from CMS Website Management.';

COMMENT ON COLUMN public.cms_knowledge_items.content_html IS
'Rich HTML body rendered on public detail pages.';

-- Public image bucket for CMS knowledge items.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'cms-knowledge-images',
  'cms-knowledge-images',
  TRUE,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/jpg', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'CMS knowledge images public read'
  ) THEN
    CREATE POLICY "CMS knowledge images public read"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'cms-knowledge-images');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Authenticated can upload cms knowledge images'
  ) THEN
    CREATE POLICY "Authenticated can upload cms knowledge images"
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'cms-knowledge-images'
      AND auth.role() = 'authenticated'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Authenticated can update cms knowledge images'
  ) THEN
    CREATE POLICY "Authenticated can update cms knowledge images"
    ON storage.objects
    FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'cms-knowledge-images'
      AND auth.role() = 'authenticated'
    )
    WITH CHECK (
      bucket_id = 'cms-knowledge-images'
      AND auth.role() = 'authenticated'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Authenticated can delete cms knowledge images'
  ) THEN
    CREATE POLICY "Authenticated can delete cms knowledge images"
    ON storage.objects
    FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'cms-knowledge-images'
      AND auth.role() = 'authenticated'
    );
  END IF;
END $$;
