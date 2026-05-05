ALTER TABLE cms_homepage
  -- Basic Meta
  ADD COLUMN IF NOT EXISTS meta_title         TEXT,
  ADD COLUMN IF NOT EXISTS meta_description   TEXT,
  ADD COLUMN IF NOT EXISTS meta_keywords      TEXT,
  ADD COLUMN IF NOT EXISTS canonical_url      TEXT,
  ADD COLUMN IF NOT EXISTS robots             VARCHAR(50) DEFAULT 'index, follow',

  -- Open Graph
  ADD COLUMN IF NOT EXISTS og_title           TEXT,
  ADD COLUMN IF NOT EXISTS og_description     TEXT,
  ADD COLUMN IF NOT EXISTS og_image           TEXT,
  ADD COLUMN IF NOT EXISTS og_type            VARCHAR(50) DEFAULT 'website',
  ADD COLUMN IF NOT EXISTS og_url             TEXT,
  ADD COLUMN IF NOT EXISTS og_site_name       TEXT,

  -- Twitter Card
  ADD COLUMN IF NOT EXISTS twitter_card       VARCHAR(50) DEFAULT 'summary_large_image',
  ADD COLUMN IF NOT EXISTS twitter_title      TEXT,
  ADD COLUMN IF NOT EXISTS twitter_description TEXT,
  ADD COLUMN IF NOT EXISTS twitter_image      TEXT,
  ADD COLUMN IF NOT EXISTS twitter_site       TEXT,

  -- Verification
  ADD COLUMN IF NOT EXISTS google_site_verification TEXT,
  ADD COLUMN IF NOT EXISTS bing_site_verification   TEXT,

  -- Structured Data
  ADD COLUMN IF NOT EXISTS schema_type        VARCHAR(100) DEFAULT 'LegalService',
  ADD COLUMN IF NOT EXISTS schema_json        JSONB;

-- Insert default SEO row so the tab loads with sensible defaults
INSERT INTO cms_homepage (section_name, robots, og_type, twitter_card, schema_type)
VALUES ('seo', 'index, follow', 'website', 'summary_large_image', 'LegalService')
ON CONFLICT (section_name) DO NOTHING;
