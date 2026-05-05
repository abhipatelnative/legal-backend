-- Migration: Add appearance columns to cms_homepage table
-- This adds the columns needed for CMS theme customization with full palette and font support

-- Add the appearance-related columns to cms_homepage
ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS primary_color VARCHAR(20) DEFAULT '#b8945f';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS secondary_color VARCHAR(20) DEFAULT '#0f172a';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS background_color VARCHAR(20) DEFAULT '#f8fafc';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS surface_color VARCHAR(20) DEFAULT '#ffffff';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS text_light VARCHAR(20) DEFAULT '#94a3b8';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS text_dark VARCHAR(20) DEFAULT '#0f172a';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS selected_palette VARCHAR(100) DEFAULT 'Classic Gold & Navy';

-- Add font-related columns
ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS heading_font VARCHAR(200) DEFAULT '''Cormorant Garamond'', serif';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS body_font VARCHAR(200) DEFAULT '''Montserrat'', sans-serif';

ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS selected_font VARCHAR(100) DEFAULT 'Classic Elegance';

-- Insert a default appearance row if it doesn't exist
INSERT INTO cms_homepage (section_name, primary_color, secondary_color, background_color, surface_color, text_light, text_dark, selected_palette, heading_font, body_font, selected_font, updated_at)
VALUES ('appearance', '#b8945f', '#0f172a', '#f8fafc', '#ffffff', '#94a3b8', '#0f172a', 'Classic Gold & Navy', '''Cormorant Garamond'', serif', '''Montserrat'', sans-serif', 'Classic Elegance', NOW())
ON CONFLICT (section_name) DO NOTHING;
