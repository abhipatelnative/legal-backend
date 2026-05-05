
-- Add service_source column to cms_homepage
ALTER TABLE cms_homepage
ADD COLUMN service_source VARCHAR(50) DEFAULT 'cms';

-- Update existing records to have default value
UPDATE cms_homepage
SET service_source = 'cms'
WHERE service_source IS NULL;
