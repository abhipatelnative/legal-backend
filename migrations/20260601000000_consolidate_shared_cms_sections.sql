-- Migration: Consolidate firm-wide CMS sections into a single shared row.
--
-- Until now every homepage template stored its own copy of every section in
-- public.cms_homepage scoped by template_id ('T1' .. 'T10'). The vast majority
-- of those sections (about, team, clients, contact, footer, etc.) hold the
-- same firm-wide content regardless of which template is active. Editing
-- "Our Clients" while T2 was active would NOT propagate to T3, leading to
-- pointless duplication and lost content when admins switched templates.
--
-- After this migration:
--   - Sections in `shared_sections` below live as a single row with
--     template_id = 'shared'. Every template that lists the section in its
--     schema reads from that row.
--   - The `hero` section (and any future template-specific section) keeps
--     its per-template rows untouched.
--   - Global sections (appearance, seo) keep template_id = 'global' as today.
--
-- The migration is idempotent: re-running it is a no-op once the shared rows
-- exist and the per-template duplicates are gone.

BEGIN;

DO $$
DECLARE
    shared_sections TEXT[] := ARRAY[
        'about','team','clients','affiliates','awards','testimonials',
        'contact','footer','blogs','articles','why_us','process',
        'services','stats'
    ];
    s TEXT;
    picked_ctid TID;
    has_shared BOOLEAN;
BEGIN
    FOREACH s IN ARRAY shared_sections LOOP
        -- Does a 'shared' row already exist for this section?
        SELECT EXISTS (
            SELECT 1 FROM public.cms_homepage
            WHERE template_id = 'shared' AND section_name = s
        ) INTO has_shared;

        IF NOT has_shared THEN
            -- Pick the most-populated per-template row (longest payload). If
            -- multiple are tied, the lower template_id wins for determinism.
            -- ctid avoids assumptions about the id column's data type
            -- (BIGINT / UUID / etc.) — both work.
            SELECT ctid INTO picked_ctid
            FROM public.cms_homepage
            WHERE section_name = s
              AND template_id NOT IN ('global', 'shared')
            ORDER BY
                COALESCE(length(payload::text), 0) DESC,
                template_id ASC
            LIMIT 1;

            IF picked_ctid IS NOT NULL THEN
                -- Reassign that row to template_id = 'shared'. The unique
                -- constraint (template_id, section_name) guarantees only one
                -- shared row per section.
                UPDATE public.cms_homepage
                SET template_id = 'shared',
                    updated_at = NOW()
                WHERE ctid = picked_ctid;
            END IF;
        END IF;

        -- Drop every remaining per-template row for this shared section.
        -- After this point, only 'shared' or 'global' rows exist for `s`.
        DELETE FROM public.cms_homepage
        WHERE section_name = s
          AND template_id NOT IN ('global', 'shared');
    END LOOP;
END $$;

COMMIT;
