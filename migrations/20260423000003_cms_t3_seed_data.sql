-- ============================================================
-- T3 Template Seed Data Migration
-- Inserts default CMS content for Template 3 (PrimeLaw Dark)
-- All data is manageable from CMS Website Setup > Template 3
-- Run with: ON CONFLICT DO UPDATE so it is safe to re-run.
-- ============================================================

-- HERO SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title, description,
  image_url, image_type,
  primary_button_text, secondary_button_text
) VALUES (
  'T3', 'hero', true,
  'Trusted Legal Expertise',
  'Legal Excellence for Every Case',
  'Strategy-driven representation with a modern approach to client service.',
  'https://images.unsplash.com/photo-1521791136064-7986c2920216?auto=format&fit=crop&w=2400&q=70',
  'url',
  'Free Consultation',
  'View Case Studies'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section          = EXCLUDED.show_section,
  badge                 = EXCLUDED.badge,
  title                 = EXCLUDED.title,
  description           = EXCLUDED.description,
  image_url             = EXCLUDED.image_url,
  image_type            = EXCLUDED.image_type,
  primary_button_text   = EXCLUDED.primary_button_text,
  secondary_button_text = EXCLUDED.secondary_button_text,
  updated_at            = now();


-- ABOUT SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title, description, secondary_description,
  image_url, image_type,
  primary_button_text,
  points
) VALUES (
  'T3', 'about', true,
  'About PrimeLaw',
  'A modern firm with classic values',
  'We believe legal services should feel guided and transparent from first consultation to final decision.',
  'Our team brings decades of combined experience across corporate, litigation, and advisory practices.',
  'https://images.unsplash.com/photo-1520607162513-77705c0f0d4a?auto=format&fit=crop&w=1200&q=70',
  'url',
  'Contact Us',
  '["Case strategy tailored to your goals", "Clear documentation and practical guidance", "Transparent communication with milestone updates"]'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section          = EXCLUDED.show_section,
  badge                 = EXCLUDED.badge,
  title                 = EXCLUDED.title,
  description           = EXCLUDED.description,
  secondary_description = EXCLUDED.secondary_description,
  image_url             = EXCLUDED.image_url,
  image_type            = EXCLUDED.image_type,
  primary_button_text   = EXCLUDED.primary_button_text,
  points                = EXCLUDED.points,
  updated_at            = now();


-- STATS SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  stats
) VALUES (
  'T3', 'stats', true,
  '[
    {"icon": "Scale",  "number": "1250+", "label": "Cases Handled"},
    {"icon": "Users",  "number": "560+",  "label": "Active Clients"},
    {"icon": "Award",  "number": "12",    "label": "Years of Experience"},
    {"icon": "Star",   "number": "98%",   "label": "Client Satisfaction"}
  ]'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section = EXCLUDED.show_section,
  stats        = EXCLUDED.stats,
  updated_at   = now();


-- SERVICES SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title, description,
  service_source, services
) VALUES (
  'T3', 'services', true,
  'Practice Areas',
  'Focused expertise for complex matters',
  'We combine legal depth with clear communication to deliver results that matter.',
  'cms',
  '[
    {
      "icon": "Scale",
      "title": "Corporate Law",
      "desc": "Transaction and governance support for businesses of all sizes.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "BriefcaseBusiness",
      "title": "Business Contracts",
      "desc": "Drafting, reviewing, and negotiating commercial agreements.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Shield",
      "title": "Dispute Resolution",
      "desc": "Mediation, arbitration, and litigation strategy for complex disputes.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Gavel",
      "title": "Criminal Defense",
      "desc": "Aggressive representation for individuals facing criminal charges.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Globe",
      "title": "International Law",
      "desc": "Cross-border legal counsel for global transactions and disputes.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Handshake",
      "title": "Family Law",
      "desc": "Compassionate guidance through divorce, custody, and estate matters.",
      "showLink": false,
      "link": "#contact"
    }
  ]'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section   = EXCLUDED.show_section,
  badge          = EXCLUDED.badge,
  title          = EXCLUDED.title,
  description    = EXCLUDED.description,
  service_source = EXCLUDED.service_source,
  services       = EXCLUDED.services,
  updated_at     = now();


-- WHY US SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title,
  points
) VALUES (
  'T3', 'why_us', true,
  'Why Choose Us',
  'The difference is in the details',
  '[
    {"icon": "Zap",    "title": "Fast, Clear Strategy",    "desc": "Straight answers and actionable next steps from day one."},
    {"icon": "Clock",  "title": "Deadline-Driven Work",    "desc": "Milestone-focused case management so nothing slips through."},
    {"icon": "Shield", "title": "Client-First Approach",   "desc": "Confidential, responsive communication at every stage."},
    {"icon": "Award",  "title": "Proven Track Record",     "desc": "Hundreds of successful outcomes across diverse practice areas."}
  ]'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section = EXCLUDED.show_section,
  badge        = EXCLUDED.badge,
  title        = EXCLUDED.title,
  points       = EXCLUDED.points,
  updated_at   = now();


-- TESTIMONIALS SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title,
  testimonials
) VALUES (
  'T3', 'testimonials', true,
  'Testimonials',
  'Clients trust our approach',
  '[
    {
      "name": "Rajesh Mehta",
      "role": "Business Owner",
      "quote": "The team was responsive, strategic, and results-focused. They resolved our contract dispute faster than we expected.",
      "img": ""
    },
    {
      "name": "Priya Sharma",
      "role": "Startup Founder",
      "quote": "Exceptional guidance on our IP filings. Clear communication throughout the entire process.",
      "img": ""
    },
    {
      "name": "Anil Kapoor",
      "role": "Corporate Executive",
      "quote": "Their M&A advisory was thorough and precise. We closed the deal with full confidence.",
      "img": ""
    }
  ]'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section = EXCLUDED.show_section,
  badge        = EXCLUDED.badge,
  title        = EXCLUDED.title,
  testimonials = EXCLUDED.testimonials,
  updated_at   = now();


-- CONTACT SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title, description,
  show_contact_info, show_map,
  map_url,
  show_login_button, login_button_position,
  office_hours_weekday, office_hours_weekend,
  form_fields
) VALUES (
  'T3', 'contact', true,
  'Contact',
  'Tell us what you need',
  'We respond quickly with clear next steps.',
  true, true,
  'https://www.google.com/maps/embed?pb=!1m18!1m12!1m3!1d248849.84916296526!2d77.6309395!3d12.9539974!2m3!1f0!2f0!3f0!3m2!1i1024!2i768!4f13.1!3m3!1m2!1s0x3bae1670c9b44e6d%3A0xf8dfc3e8517e4fe0!2sBengaluru%2C%20Karnataka!5e0!3m2!1sen!2sin!4v1234567890',
  true, 'navbar',
  'Monday - Saturday: 9:00 AM - 7:30 PM',
  'Sunday: Closed',
  '[
    {"label": "FULL NAME",    "placeholder": "Your name",                  "type": "text",     "name": "name",    "required": true},
    {"label": "EMAIL",        "placeholder": "you@company.com",            "type": "email",    "name": "email",   "required": true},
    {"label": "PHONE",        "placeholder": "Your phone number",          "type": "tel",      "name": "phone",   "required": false},
    {"label": "MESSAGE",      "placeholder": "Your legal requirement...",  "type": "textarea", "name": "message", "required": true}
  ]'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section          = EXCLUDED.show_section,
  badge                 = EXCLUDED.badge,
  title                 = EXCLUDED.title,
  description           = EXCLUDED.description,
  show_contact_info     = EXCLUDED.show_contact_info,
  show_map              = EXCLUDED.show_map,
  map_url               = EXCLUDED.map_url,
  show_login_button     = EXCLUDED.show_login_button,
  login_button_position = EXCLUDED.login_button_position,
  office_hours_weekday  = EXCLUDED.office_hours_weekday,
  office_hours_weekend  = EXCLUDED.office_hours_weekend,
  form_fields           = EXCLUDED.form_fields,
  updated_at            = now();


-- APPEARANCE SECTION
-- Only sets home_template = 'T3' if no global appearance row exists yet.
-- If it already exists, DO NOTHING so the user's current selection is preserved.
INSERT INTO public.cms_homepage (
  template_id, section_name,
  home_template,
  primary_color, secondary_color,
  background_color, surface_color,
  text_light, text_dark,
  selected_palette, selected_font
) VALUES (
  'global', 'appearance',
  'T3',
  '#FFD700', '#0f172a',
  '#0d1117', '#161b22',
  '#8b949e', '#f0f6fc',
  'dark_gold', 'Classic Elegance'
)
ON CONFLICT (template_id, section_name) DO NOTHING;


-- SEO SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name,
  meta_title, meta_description, meta_keywords,
  og_title, og_description,
  robots
) VALUES (
  'T3', 'seo',
  'PrimeLaw — Legal Excellence for Every Case',
  'PrimeLaw delivers strategy-driven legal representation with a modern approach. Corporate law, dispute resolution, IP, and more.',
  'law firm, legal services, corporate law, dispute resolution, intellectual property, family law',
  'PrimeLaw — Trusted Legal Expertise',
  'Strategy-driven representation with a modern approach to client service. Trusted by businesses and individuals alike.',
  'index, follow'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  meta_title       = EXCLUDED.meta_title,
  meta_description = EXCLUDED.meta_description,
  meta_keywords    = EXCLUDED.meta_keywords,
  og_title         = EXCLUDED.og_title,
  og_description   = EXCLUDED.og_description,
  robots           = EXCLUDED.robots,
  updated_at       = now();
