BEGIN;

ALTER TABLE public.cms_homepage
  ADD COLUMN IF NOT EXISTS google_analytics_enabled BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS google_analytics_measurement_id TEXT;

COMMENT ON COLUMN public.cms_homepage.google_analytics_enabled IS
  'Enables global Google Analytics tracking for public CMS templates.';

COMMENT ON COLUMN public.cms_homepage.google_analytics_measurement_id IS
  'GA4 measurement ID (for example G-XXXXXXXXXX) applied globally to public CMS templates.';

-- Backfill new columns from payload for existing appearance rows that may
-- already contain the Google Analytics keys.
UPDATE public.cms_homepage
SET
  google_analytics_enabled = COALESCE(
    NULLIF(payload ->> 'google_analytics_enabled', '')::boolean,
    google_analytics_enabled,
    false
  ),
  google_analytics_measurement_id = COALESCE(
    NULLIF(payload ->> 'google_analytics_measurement_id', ''),
    google_analytics_measurement_id
  )
WHERE payload IS NOT NULL
  AND (
    payload ? 'google_analytics_enabled'
    OR payload ? 'google_analytics_measurement_id'
  );

COMMIT;
