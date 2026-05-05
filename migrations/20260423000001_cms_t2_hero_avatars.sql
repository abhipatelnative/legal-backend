-- Add avatar show/hide toggle and placeholder avatar URLs to T2 hero row
UPDATE public.cms_homepage
SET
  show_contact_info = true,
  points            = '["https://images.unsplash.com/photo-1494790108377-be9c29b29330?q=80&w=100", "https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?q=80&w=100", "https://images.unsplash.com/photo-1500648767791-00dcc994a43e?q=80&w=100", "https://images.unsplash.com/photo-1438761681033-6461ffad8d80?q=80&w=100"]',
  updated_at        = now()
WHERE template_id = 'T2'
  AND section_name = 'hero';
