-- Migration: Add office hours fields to cms_homepage table for contact section
-- Created: 2026-03-17
-- Description: Adds office_hours_weekday and office_hours_weekend columns to store customizable office hours

-- Add office_hours_weekday column
ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS office_hours_weekday TEXT DEFAULT 'Monday - Saturday: 9:00 AM - 7:30 PM';

-- Add office_hours_weekend column
ALTER TABLE cms_homepage 
ADD COLUMN IF NOT EXISTS office_hours_weekend TEXT DEFAULT 'Sunday: Closed';

-- Add comment to document the columns
COMMENT ON COLUMN cms_homepage.office_hours_weekday IS 'Customizable weekday office hours text displayed on the website contact section';
COMMENT ON COLUMN cms_homepage.office_hours_weekend IS 'Customizable weekend office hours text displayed on the website contact section';

-- Update existing contact section record with default values if it exists
UPDATE cms_homepage 
SET 
    office_hours_weekday = COALESCE(office_hours_weekday, 'Monday - Saturday: 9:00 AM - 7:30 PM'),
    office_hours_weekend = COALESCE(office_hours_weekend, 'Sunday: Closed')
WHERE section_name = 'contact';
