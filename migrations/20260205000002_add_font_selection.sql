-- Migration: Add font selection column to cms_homepage table

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS selected_font VARCHAR(100) DEFAULT 'Modern Professional';

-- Update the appearance row to include the default font if it exists
UPDATE cms_homepage
SET selected_font = 'Modern Professional'
WHERE section_name = 'appearance' AND selected_font IS NULL;
