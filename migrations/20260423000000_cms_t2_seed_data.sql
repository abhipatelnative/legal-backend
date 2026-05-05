-- ============================================================
-- T2 Template Seed Data Migration
-- Inserts default CMS content for Template 2 (Modern Boutique)
-- All data is manageable from CMS Website Setup > Template 2
-- ============================================================

-- HERO SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title, description,
  image_url, image_type,
  primary_button_text, secondary_button_text,
  experience_years, experience_text
) VALUES (
  'T2', 'hero', true,
  'Premier Legal Council',
  'FORGING JUSTICE WITH INTENT',
  'Advanced legal strategies for complex global challenges. We combine decades of expertise with relentless dedication to deliver outcomes that matter.',
  'https://images.unsplash.com/photo-1589829545856-d10d557cf95f?q=80&w=2070',
  'url',
  'Secure Consultation',
  'Explore Our Work',
  '5k+', 'Trusted Clients'
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
  experience_years      = EXCLUDED.experience_years,
  experience_text       = EXCLUDED.experience_text,
  updated_at            = now();


-- ABOUT SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title, description, secondary_description,
  image_url, image_type,
  extra_title, extra_text,
  points,
  primary_button_text
) VALUES (
  'T2', 'about', true,
  'Firm Identity',
  'EXCELLENCE DEFINED BY OUTCOMES',
  'We are a full-service law firm built on the principle that every client deserves exceptional representation. Our attorneys bring unmatched depth of knowledge across corporate, litigation, and advisory practices.',
  'Founded on integrity and driven by results, we have shaped landmark decisions across industries and jurisdictions for over two decades.',
  'https://images.unsplash.com/photo-1505664194779-8beaceb93744?q=80&w=2070',
  'url',
  'Our Commitment',
  'Justice is not just our profession — it is our purpose. We stand by every client with unwavering resolve.',
  '["Expert Strategic Litigation", "High-Stakes Mediation", "Bespoke IP Solutions", "Corporate Integrity Advisory"]',
  'Learn Our Story'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section           = EXCLUDED.show_section,
  badge                  = EXCLUDED.badge,
  title                  = EXCLUDED.title,
  description            = EXCLUDED.description,
  secondary_description  = EXCLUDED.secondary_description,
  image_url              = EXCLUDED.image_url,
  image_type             = EXCLUDED.image_type,
  extra_title            = EXCLUDED.extra_title,
  extra_text             = EXCLUDED.extra_text,
  points                 = EXCLUDED.points,
  primary_button_text    = EXCLUDED.primary_button_text,
  updated_at             = now();


-- STATS SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  stats
) VALUES (
  'T2', 'stats', true,
  '[
    {"icon": "Scale",       "number": "500+", "label": "Cases Won"},
    {"icon": "Users",       "number": "98%",  "label": "Client Satisfaction"},
    {"icon": "Award",       "number": "25+",  "label": "Years Experience"},
    {"icon": "Briefcase",   "number": "120+", "label": "Expert Attorneys"}
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
  'T2', 'services', true,
  'Legal Expertise',
  'PRECISION PRACTICES',
  'From complex corporate transactions to high-stakes litigation, our practice groups deliver results with precision and purpose.',
  'cms',
  '[
    {
      "icon": "Scale",
      "title": "Corporate Litigation",
      "desc": "We represent corporations, executives, and boards in high-stakes disputes, regulatory investigations, and complex commercial litigation across all major jurisdictions.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Shield",
      "title": "Intellectual Property",
      "desc": "Protecting your innovations and brand assets through comprehensive IP strategy, patent prosecution, trademark registration, and aggressive enforcement.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Briefcase",
      "title": "Mergers & Acquisitions",
      "desc": "End-to-end advisory for transformative transactions — from due diligence and structuring to negotiation, regulatory clearance, and post-merger integration.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Globe",
      "title": "International Arbitration",
      "desc": "Representing clients in cross-border disputes before leading arbitral institutions including ICC, LCIA, SIAC, and UNCITRAL tribunals worldwide.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "FileText",
      "title": "Regulatory & Compliance",
      "desc": "Navigating complex regulatory landscapes with proactive compliance programs, government investigations defense, and strategic policy engagement.",
      "showLink": false,
      "link": "#contact"
    },
    {
      "icon": "Users",
      "title": "Employment & Labour",
      "desc": "Comprehensive employment law counsel for employers — from workforce restructuring and executive agreements to discrimination defense and NLRB matters.",
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


-- CONTACT SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name, show_section,
  badge, title,
  show_contact_info, show_map,
  show_login_button, login_button_position,
  office_hours_weekday, office_hours_weekend
) VALUES (
  'T2', 'contact', true,
  'Connect With Us',
  'IGNITE YOUR DEFENSE',
  true, false,
  true, 'navbar',
  'Monday - Saturday: 9:00 AM - 7:30 PM',
  'Sunday: Closed'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  show_section          = EXCLUDED.show_section,
  badge                 = EXCLUDED.badge,
  title                 = EXCLUDED.title,
  show_contact_info     = EXCLUDED.show_contact_info,
  show_map              = EXCLUDED.show_map,
  show_login_button     = EXCLUDED.show_login_button,
  login_button_position = EXCLUDED.login_button_position,
  office_hours_weekday  = EXCLUDED.office_hours_weekday,
  office_hours_weekend  = EXCLUDED.office_hours_weekend,
  updated_at            = now();


-- APPEARANCE SECTION (T2 defaults — only inserted if no global appearance row exists)
INSERT INTO public.cms_homepage (
  template_id, section_name,
  home_template,
  primary_color, secondary_color,
  background_color, surface_color,
  text_light, text_dark,
  selected_palette, selected_font
) VALUES (
  'global', 'appearance',
  'T2',
  '#b8945f', '#0f172a',
  '#f8fafc', '#ffffff',
  '#94a3b8', '#0f172a',
  'classic_gold', 'Classic Elegance'
)
ON CONFLICT (template_id, section_name) DO NOTHING;


-- SEO SECTION
INSERT INTO public.cms_homepage (
  template_id, section_name,
  meta_title, meta_description, meta_keywords,
  og_title, og_description,
  robots
) VALUES (
  'T2', 'seo',
  'LegalPrime — Premier Legal Council',
  'LegalPrime delivers advanced legal strategies for complex global challenges. Expert litigation, M&A, IP, and regulatory counsel.',
  'law firm, legal services, litigation, corporate law, intellectual property, arbitration',
  'LegalPrime — Forging Justice With Intent',
  'Advanced legal strategies for complex global challenges. Trusted by leading corporations and individuals worldwide.',
  'index, follow'
)
ON CONFLICT (template_id, section_name) DO UPDATE SET
  meta_title        = EXCLUDED.meta_title,
  meta_description  = EXCLUDED.meta_description,
  meta_keywords     = EXCLUDED.meta_keywords,
  og_title          = EXCLUDED.og_title,
  og_description    = EXCLUDED.og_description,
  robots            = EXCLUDED.robots,
  updated_at        = now();
