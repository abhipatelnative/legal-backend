-- Google reviews workflow for CMS testimonials moderation and configuration.

CREATE TABLE IF NOT EXISTS public.cms_external_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL DEFAULT 'google_places' CHECK (provider IN ('google_places')),
  source_location_id TEXT NOT NULL,
  external_review_id TEXT NOT NULL,
  reviewer_name TEXT NOT NULL,
  reviewer_photo_url TEXT,
  rating NUMERIC(2,1) NOT NULL CHECK (rating >= 0 AND rating <= 5),
  review_text TEXT,
  review_time TIMESTAMP WITH TIME ZONE,
  raw_payload JSONB,
  moderation_status TEXT NOT NULL DEFAULT 'pending' CHECK (moderation_status IN ('pending', 'approved', 'rejected')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.cms_review_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL DEFAULT 'google_places' CHECK (provider IN ('google_places')),
  source_location_id TEXT NOT NULL,
  business_name TEXT NOT NULL,
  api_key TEXT NOT NULL,
  sync_mode TEXT NOT NULL DEFAULT 'manual_and_daily' CHECK (sync_mode IN ('manual_and_daily')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  last_synced_at TIMESTAMP WITH TIME ZONE,
  last_sync_status TEXT CHECK (last_sync_status IN ('success', 'failed')),
  last_sync_error TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_cms_external_reviews_provider_source_external_not_deleted
ON public.cms_external_reviews (provider, source_location_id, external_review_id)
WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_cms_external_reviews_status
ON public.cms_external_reviews (moderation_status, is_active, is_deleted);

CREATE INDEX IF NOT EXISTS idx_cms_external_reviews_source
ON public.cms_external_reviews (source_location_id, provider);

CREATE UNIQUE INDEX IF NOT EXISTS ux_cms_review_sources_provider_source_not_deleted
ON public.cms_review_sources (provider, source_location_id)
WHERE is_deleted = FALSE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'update_updated_at_column'
      AND pronamespace = 'public'::regnamespace
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_cms_external_reviews_updated_at'
      AND tgrelid = 'public.cms_external_reviews'::regclass
  ) THEN
    CREATE TRIGGER update_cms_external_reviews_updated_at
      BEFORE UPDATE ON public.cms_external_reviews
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'update_updated_at_column'
      AND pronamespace = 'public'::regnamespace
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_cms_review_sources_updated_at'
      AND tgrelid = 'public.cms_review_sources'::regclass
  ) THEN
    CREATE TRIGGER update_cms_review_sources_updated_at
      BEFORE UPDATE ON public.cms_review_sources
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

ALTER TABLE public.cms_external_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cms_review_sources ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'cms_external_reviews'
      AND policyname = 'Public can read approved external reviews'
  ) THEN
    CREATE POLICY "Public can read approved external reviews"
    ON public.cms_external_reviews
    FOR SELECT
    USING (
      moderation_status = 'approved'
      AND is_active = TRUE
      AND is_deleted = FALSE
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'cms_external_reviews'
      AND policyname = 'Authenticated can manage external reviews'
  ) THEN
    CREATE POLICY "Authenticated can manage external reviews"
    ON public.cms_external_reviews
    FOR ALL
    TO authenticated
    USING (TRUE)
    WITH CHECK (TRUE);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'cms_review_sources'
      AND policyname = 'Authenticated can manage review sources'
  ) THEN
    CREATE POLICY "Authenticated can manage review sources"
    ON public.cms_review_sources
    FOR ALL
    TO authenticated
    USING (TRUE)
    WITH CHECK (TRUE);
  END IF;
END $$;

COMMENT ON TABLE public.cms_external_reviews IS
'External review entries imported from providers like Google Places for moderated website display.';

COMMENT ON TABLE public.cms_review_sources IS
'Provider configuration and sync metadata for fetching external reviews.';
