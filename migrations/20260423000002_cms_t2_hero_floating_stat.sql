-- Update T2 hero row to add Floating Stat Number and Floating Stat Label
UPDATE public.cms_homepage
SET
  experience_years = '5k+',
  experience_text  = 'Trusted Clients',
  updated_at       = now()
WHERE template_id = 'T2'
  AND section_name = 'hero';
