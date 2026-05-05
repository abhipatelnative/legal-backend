-- ─────────────────────────────────────────────────────────────────────────────
-- Global search: precision fix
--
-- Problems:
--   1. Trigram threshold alone is insufficient for short words.
--      "anand" shares 3/5 trigrams with "and" → word_similarity = 0.60,
--      causing "CASH AND CHANGE", "DISTRICT AND SESSIONS COURT", etc. to match.
--
--   2. FTS has no similarity gate — "Anjali Gupta" appears for "anand" because
--      her vec contains the lexeme (from a linked field), even though her title
--      has zero resemblance to the query.
--
-- Fixes:
--   1. Trigram match: require title ILIKE '%query%' (substring present)
--      OR very-high word_similarity > 0.70 (genuine typo).
--      Add GIN trigram index on global_search_index.title so ILIKE is O(log n).
--
--   2. FTS results: gate on word_similarity(query, title) > 0.12 — a tiny
--      floor that eliminates zero-resemblance titles (Anjali Gupta ≈ 0.05)
--      without touching genuine FTS hits (Anand Kumar ≈ 1.0).
-- ─────────────────────────────────────────────────────────────────────────────

-- GIN trigram index on title for fast ILIKE scans
CREATE INDEX IF NOT EXISTS idx_gsi_title_trgm
  ON public.global_search_index USING GIN (title gin_trgm_ops);

-- ── Rewrite function ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.global_search(
  p_query      TEXT,
  p_branch_id  UUID    DEFAULT NULL,
  p_limit      INTEGER DEFAULT 25
)
RETURNS TABLE (
  entity_group      TEXT,
  entity_type       TEXT,
  entity_id         UUID,
  title             TEXT,
  subtitle          TEXT,
  url               TEXT,
  permission_module TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '10000'
AS $$
  WITH
  params AS (
    SELECT
      NULLIF(TRIM(p_query), '') AS q,
      NULLIF(regexp_replace(TRIM(COALESCE(p_query, '')), '[^0-9]+', '', 'g'), '') AS q_digits
  ),
  parsed AS (
    SELECT
      params.q,
      params.q_digits,
      CASE
        WHEN params.q IS NULL THEN NULL
        ELSE websearch_to_tsquery('simple', params.q)
      END AS tsq
    FROM params
  ),

  -- ── permission resolution ─────────────────────────────────────────────────
  role_perms AS (
    SELECT p.module, BOOL_OR(p.can_view) AS can_view
    FROM   public.user_roles ur
    JOIN   public.role_permissions rp
             ON rp.role_id    = ur.role_id
            AND rp.is_active  = true
            AND rp.is_deleted = false
    JOIN   public.permissions p
             ON p.id          = rp.permission_id
            AND p.is_active   = true
            AND p.is_deleted  = false
    WHERE  ur.user_id   = auth.uid()
      AND  ur.is_active  = true
      AND  ur.is_deleted = false
    GROUP BY p.module
  ),
  user_perms AS (
    SELECT p.module, BOOL_OR(up.can_view) AS can_view
    FROM   public.user_permissions up
    JOIN   public.permissions p
             ON p.id          = up.permission_id
            AND p.is_active   = true
            AND p.is_deleted  = false
    WHERE  up.user_id   = auth.uid()
      AND  up.is_active  = true
      AND  up.is_deleted = false
    GROUP BY p.module
  ),
  filtered_modules AS (
    SELECT COALESCE(up.module, rp.module) AS module
    FROM   role_perms rp
    FULL OUTER JOIN user_perms up ON up.module = rp.module
    WHERE  COALESCE(up.can_view, rp.can_view, false) = true
  ),

  service_order_context AS (
    SELECT
      so.id AS service_order_id,
      so.branch_id,
      so.order_number,
      so.status,
      so.is_case,
      so.created_at::DATE AS order_date,
      cl.name AS client_name,
      sm.name AS service_name,
      scm.category_name AS service_category_name,
      ag.name AS agent_name,
      string_agg(DISTINCT NULLIF(TRIM(oc.case_number), ''), ' ') AS case_numbers,
      string_agg(DISTINCT NULLIF(TRIM(oc.case_title), ''), ' ') AS case_titles,
      string_agg(DISTINCT NULLIF(oc.filing_date::TEXT, ''), ' ') AS filing_dates,
      string_agg(DISTINCT NULLIF(TRIM(c.court_name), ''), ' ') AS court_names
    FROM public.service_orders so
    LEFT JOIN public.clients cl
      ON cl.id = so.client_id
    LEFT JOIN public.service_master sm
      ON sm.id = so.service_id
    LEFT JOIN public.service_category_master scm
      ON scm.id = sm.category_id
    LEFT JOIN public.agent_master ag
      ON ag.id = so.agent_id
    LEFT JOIN public.order_cases oc
      ON oc.service_order_id = so.id
    LEFT JOIN public.courts c
      ON c.id = oc.court_id
    WHERE COALESCE(so.is_deleted, false) = false
    GROUP BY
      so.id,
      so.branch_id,
      so.order_number,
      so.status,
      so.is_case,
      so.created_at,
      cl.name,
      sm.name,
      scm.category_name,
      ag.name
  ),

  hearing_employee_names AS (
    SELECT
      hae.case_hearing_id,
      string_agg(DISTINCT NULLIF(TRIM(concat_ws(' ', up.first_name, up.middle_name, up.last_name)), ''), ' ') AS assigned_employee_names
    FROM public.hearing_assigned_employees hae
    LEFT JOIN public.user_profiles up
      ON up.id = hae.user_id
    WHERE COALESCE(up.is_deleted, false) = false
    GROUP BY hae.case_hearing_id
  ),

  -- ── full-text search ──────────────────────────────────────────────────────
  -- Gate: word_similarity > 0.12 removes zero-resemblance FTS hits
  -- (e.g. "Anjali Gupta" appearing for "anand" due to linked-field indexing).
  -- Genuine hits like "Anand Kumar" score ≈ 1.0 and are unaffected.
  fts_matches AS (
    SELECT
      gsi.entity_group       AS eg,
      gsi.entity_type        AS et,
      gsi.entity_id          AS eid,
      gsi.title              AS ttl,
      gsi.subtitle           AS sub,
      gsi.url                AS url,
      gsi.permission_module  AS pm,
      ts_rank(gsi.vec, prs.tsq)              AS fts_rank,
      word_similarity(prs.q, gsi.title)      AS title_sim
    FROM   parsed prs
    JOIN   public.global_search_index gsi ON prs.tsq IS NOT NULL
    JOIN   filtered_modules fm            ON fm.module = gsi.permission_module
    WHERE  gsi.vec @@ prs.tsq
      AND  word_similarity(prs.q, gsi.title) > 0.12   -- title must resemble query
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY ts_rank(gsi.vec, prs.tsq) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── trigram / typo search ─────────────────────────────────────────────────
  -- Two-condition gate instead of a single threshold:
  --   a) Substring present: title ILIKE '%query%'  (uses GIN trigram index)
  --      → finds "Anand Kumar" for query "anand", exact and partial matches
  --   b) Very-high similarity > 0.70  (genuine single-character typo)
  --      → finds "Mitehs Patil" for "Mitesh Patil"
  --      → does NOT fire for "and" vs "anand" (similarity ≈ 0.60)
  -- Both conditions are mutually exclusive in most cases, giving precision
  -- on substring and tolerance on typos without cross-contamination.
  trigram_matches AS (
    SELECT
      gsi.entity_group       AS eg,
      gsi.entity_type        AS et,
      gsi.entity_id          AS eid,
      gsi.title              AS ttl,
      gsi.subtitle           AS sub,
      gsi.url                AS url,
      gsi.permission_module  AS pm,
      0::REAL                                AS fts_rank,
      word_similarity(prs.q, gsi.title)      AS title_sim
    FROM   parsed prs
    JOIN   public.global_search_index gsi ON prs.q IS NOT NULL
    JOIN   filtered_modules fm            ON fm.module = gsi.permission_module
    WHERE  (
      gsi.title ILIKE '%' || prs.q || '%'                -- substring: exact/partial
      OR word_similarity(prs.q, gsi.title) > 0.70        -- high confidence: typo
    )
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY word_similarity(prs.q, gsi.title) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── live inquiry search ───────────────────────────────────────────────────
  inquiry_matches AS (
    SELECT
      'People'::TEXT                                              AS eg,
      'inquiry'::TEXT                                             AS et,
      i.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(i.full_name),''),
               NULLIF(TRIM(i.email),''),
               NULLIF(TRIM(i.phone),''), 'Inquiry')              AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        i.phone, i.email,
        NULLIF(TRIM(concat_ws(' / ', scm.category_name, sm.name)),''),
        NULLIF(LEFT(TRIM(i.message), 80),''),
        i.status::text
      )), '')                                                     AS sub,
      '/crm/inquiries'::TEXT                                      AS url,
      'crm_inquiries'::TEXT                                       AS pm,
      0.75::REAL                                                  AS fts_rank,
      word_similarity(prs.q, COALESCE(i.full_name,''))           AS title_sim
    FROM   parsed prs
    JOIN   filtered_modules fm ON fm.module = 'crm_inquiries'
    JOIN   public.inquiries i  ON prs.q IS NOT NULL
    LEFT JOIN public.service_master sm           ON sm.id = i.service_id
    LEFT JOIN public.service_category_master scm ON scm.id = i.service_category_id
    WHERE  (
      i.full_name ILIKE '%' || prs.q || '%'
      OR i.phone  ILIKE '%' || prs.q || '%'
      OR i.email  ILIKE '%' || prs.q || '%'
    )
    LIMIT  LEAST(p_limit, 50) * 2
  ),

  client_matches AS (
    SELECT
      'People'::TEXT                                              AS eg,
      'client'::TEXT                                              AS et,
      c.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(c.name), ''), 'Client')                AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        c.email,
        c.mobile,
        c.address,
        c.category
      )), '')                                                     AS sub,
      '/case-matter/clients'::TEXT                                AS url,
      'case_matter_clients'::TEXT                                 AS pm,
      0.78::REAL                                                  AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(c.name, '')),
        word_similarity(prs.q, COALESCE(c.email, '')),
        word_similarity(prs.q, COALESCE(c.mobile, '')),
        word_similarity(COALESCE(prs.q_digits, ''), regexp_replace(COALESCE(c.mobile, ''), '[^0-9]+', '', 'g')),
        word_similarity(prs.q, COALESCE(c.address, '')),
        word_similarity(prs.q, COALESCE(c.category, ''))
      )                                                           AS title_sim
    FROM   parsed prs
    JOIN   filtered_modules fm
             ON fm.module = 'case_matter_clients'
    JOIN   public.clients c
             ON prs.q IS NOT NULL
    WHERE  COALESCE(c.is_deleted, false) = false
      AND (
        COALESCE(c.name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(c.email, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(c.mobile, '') ILIKE '%' || prs.q || '%'
        OR (
          prs.q_digits IS NOT NULL
          AND regexp_replace(COALESCE(c.mobile, ''), '[^0-9]+', '', 'g') LIKE '%' || prs.q_digits || '%'
        )
        OR COALESCE(c.address, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(c.category, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(c.notes, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT  LEAST(p_limit, 50) * 2
  ),

  agent_matches AS (
    SELECT
      'People'::TEXT                                              AS eg,
      'agent'::TEXT                                               AS et,
      a.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(a.name), ''), 'Agent')                 AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        a.mobile,
        a.email,
        a.address,
        a.commission_type
      )), '')                                                     AS sub,
      '/masters/agents'::TEXT                                     AS url,
      'masters_agent'::TEXT                                       AS pm,
      0.78::REAL                                                  AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(a.name, '')),
        word_similarity(prs.q, COALESCE(a.email, '')),
        word_similarity(prs.q, COALESCE(a.mobile, '')),
        word_similarity(COALESCE(prs.q_digits, ''), regexp_replace(COALESCE(a.mobile, ''), '[^0-9]+', '', 'g')),
        word_similarity(prs.q, COALESCE(a.address, '')),
        word_similarity(prs.q, COALESCE(a.commission_type, ''))
      )                                                           AS title_sim
    FROM   parsed prs
    JOIN   filtered_modules fm
             ON fm.module = 'masters_agent'
    JOIN   public.agent_master a
             ON prs.q IS NOT NULL
    WHERE  COALESCE(a.is_deleted, false) = false
      AND (
        COALESCE(a.name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(a.email, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(a.mobile, '') ILIKE '%' || prs.q || '%'
        OR (
          prs.q_digits IS NOT NULL
          AND regexp_replace(COALESCE(a.mobile, ''), '[^0-9]+', '', 'g') LIKE '%' || prs.q_digits || '%'
        )
        OR COALESCE(a.address, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(a.commission_type, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT  LEAST(p_limit, 50) * 2
  ),

  case_matches AS (
    SELECT
      'Cases & Matters'::TEXT                                      AS eg,
      'case'::TEXT                                                 AS et,
      so.service_order_id                                          AS eid,
      COALESCE(NULLIF(TRIM(concat_ws(' - ', so.order_number, so.case_titles)), ''), so.order_number, 'Case Order') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        so.client_name,
        so.service_name,
        so.case_numbers,
        so.order_date::TEXT,
        so.filing_dates,
        so.status
      )), '')                                                      AS sub,
      '/case-matter/case-orders/' || so.service_order_id::TEXT     AS url,
      'service_orders'::TEXT                                       AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(so.order_number, '')),
        word_similarity(prs.q, COALESCE(so.case_titles, '')),
        word_similarity(prs.q, COALESCE(so.case_numbers, '')),
        word_similarity(prs.q, COALESCE(so.client_name, '')),
        word_similarity(prs.q, COALESCE(so.service_name, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'service_orders'
    JOIN service_order_context so
      ON prs.q IS NOT NULL
    WHERE so.is_case = true
      AND (p_branch_id IS NULL OR so.branch_id IS NULL OR so.branch_id = p_branch_id)
      AND (
        COALESCE(so.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.case_titles, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.case_numbers, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.client_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.service_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.service_category_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.agent_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.court_names, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.order_date::TEXT, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.filing_dates, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.status, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
  ),

  service_matches AS (
    SELECT
      'Cases & Matters'::TEXT                                      AS eg,
      'service'::TEXT                                              AS et,
      so.service_order_id                                          AS eid,
      COALESCE(NULLIF(TRIM(so.order_number), ''), 'Service Order') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        so.client_name,
        so.service_name,
        so.order_date::TEXT,
        so.status
      )), '')                                                      AS sub,
      '/case-matter/service-orders/view/' || so.service_order_id::TEXT AS url,
      'service_orders'::TEXT                                       AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(so.order_number, '')),
        word_similarity(prs.q, COALESCE(so.client_name, '')),
        word_similarity(prs.q, COALESCE(so.service_name, '')),
        word_similarity(prs.q, COALESCE(so.service_category_name, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'service_orders'
    JOIN service_order_context so
      ON prs.q IS NOT NULL
    WHERE so.is_case = false
      AND (p_branch_id IS NULL OR so.branch_id IS NULL OR so.branch_id = p_branch_id)
      AND (
        COALESCE(so.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.client_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.service_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.service_category_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.agent_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.order_date::TEXT, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(so.status, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
  ),

  order_case_matches AS (
    SELECT
      'Cases & Matters'::TEXT                                      AS eg,
      'order_case'::TEXT                                           AS et,
      oc.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(oc.case_title), ''), NULLIF(TRIM(oc.case_number), ''), 'Order Case') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        soc.order_number,
        c.court_name,
        oc.filing_date::TEXT,
        oc.status
      )), '')                                                      AS sub,
      '/case-matter/case-orders/' || oc.service_order_id::TEXT     AS url,
      'service_orders'::TEXT                                       AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(oc.case_title, '')),
        word_similarity(prs.q, COALESCE(oc.case_number, '')),
        word_similarity(prs.q, COALESCE(soc.order_number, '')),
        word_similarity(prs.q, COALESCE(c.court_name, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'service_orders'
    JOIN public.order_cases oc
      ON prs.q IS NOT NULL
    LEFT JOIN service_order_context soc
      ON soc.service_order_id = oc.service_order_id
    LEFT JOIN public.courts c
      ON c.id = oc.court_id
    WHERE (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
      AND (
        COALESCE(oc.case_title, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(oc.case_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(oc.case_type, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(oc.status, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(oc.filing_date::TEXT, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(c.court_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(soc.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(soc.client_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(soc.service_name, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
  ),

  hearing_matches AS (
    SELECT
      'Cases & Matters'::TEXT                                      AS eg,
      'hearing'::TEXT                                              AS et,
      ch.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(ch.purpose), ''), NULLIF(TRIM(oc.case_title), ''), 'Hearing') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        c.court_name,
        ch.hearing_date::TEXT,
        soc.order_number,
        soc.client_name,
        hen.assigned_employee_names,
        ch.status
      )), '')                                                      AS sub,
      CASE
        WHEN oc.service_order_id IS NOT NULL THEN '/case-matter/case-orders/' || oc.service_order_id::TEXT
        ELSE '/case-matter/hearings'
      END                                                          AS url,
      'case_matter_hearingss'::TEXT                                AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(ch.purpose, '')),
        word_similarity(prs.q, COALESCE(c.court_name, '')),
        word_similarity(prs.q, COALESCE(oc.case_number, '')),
        word_similarity(prs.q, COALESCE(oc.case_title, '')),
        word_similarity(prs.q, COALESCE(soc.order_number, '')),
        word_similarity(prs.q, COALESCE(soc.client_name, '')),
        word_similarity(prs.q, COALESCE(hen.assigned_employee_names, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'case_matter_hearingss'
    JOIN public.case_hearings ch
      ON prs.q IS NOT NULL
    LEFT JOIN public.order_cases oc
      ON oc.id = ch.order_case_id
    LEFT JOIN public.courts c
      ON c.id = ch.court_id
    LEFT JOIN service_order_context soc
      ON soc.service_order_id = oc.service_order_id
    LEFT JOIN hearing_employee_names hen
      ON hen.case_hearing_id = ch.id
    WHERE (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
      AND (
        COALESCE(ch.purpose, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(c.court_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(oc.case_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(oc.case_title, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(soc.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(soc.client_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(soc.service_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(hen.assigned_employee_names, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ch.hearing_date::TEXT, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ch.next_hearing_date::TEXT, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ch.status, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
  ),

  template_content_matches AS (
    SELECT
      'Documents, Templates & Knowledge'::TEXT                         AS eg,
      'document_template'::TEXT                                        AS et,
      dt.id                                                            AS eid,
      COALESCE(NULLIF(TRIM(dt.template_name),''), 'Document Template') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        dt.document_type,
        dt.base_language,
        NULLIF(LEFT(TRIM(COALESCE(dt.description, '')), 80), ''),
        translation_summary.matched_languages
      )), '')                                                          AS sub,
      '/case-matter-masters/document/view/' || dt.id::TEXT             AS url,
      'case_matter_document'::TEXT                                     AS pm,
      0.82::REAL                                                       AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(dt.template_name, '')),
        word_similarity(prs.q, COALESCE(dt.document_type, '')),
        word_similarity(prs.q, COALESCE(dt.base_language, ''))
      )                                                                AS title_sim
    FROM   parsed prs
    JOIN   filtered_modules fm
             ON fm.module = 'case_matter_document'
    JOIN   public.document_templates dt
             ON prs.q IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT
        string_agg(COALESCE(dtt.language_name, dtt.language_code), ' | ') AS matched_languages,
        string_agg(COALESCE(dtt.translated_content, ''), ' ')              AS translated_content
      FROM public.document_template_translations dtt
      WHERE dtt.template_id = dt.id
        AND (
          COALESCE(dtt.translated_content, '') ILIKE '%' || prs.q || '%'
          OR COALESCE(dtt.language_name, '') ILIKE '%' || prs.q || '%'
          OR COALESCE(dtt.language_code, '') ILIKE '%' || prs.q || '%'
        )
    ) translation_summary ON true
    WHERE  COALESCE(dt.is_deleted, false) = false
      AND (
        COALESCE(dt.template_name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(dt.document_type, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(dt.base_language, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(dt.description, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(dt.template_content, '') ILIKE '%' || prs.q || '%'
        OR translation_summary.translated_content IS NOT NULL
      )
    LIMIT  LEAST(p_limit, 50) * 2
  ),

  merged AS (
    SELECT * FROM fts_matches
    UNION ALL
    SELECT * FROM trigram_matches
    UNION ALL
    SELECT * FROM inquiry_matches
    UNION ALL
    SELECT * FROM client_matches
    UNION ALL
    SELECT * FROM agent_matches
    UNION ALL
    SELECT * FROM case_matches
    UNION ALL
    SELECT * FROM service_matches
    UNION ALL
    SELECT * FROM order_case_matches
    UNION ALL
    SELECT * FROM hearing_matches
    UNION ALL
    SELECT * FROM template_content_matches
  ),
  normalised AS (
    SELECT
      CASE
        WHEN m.et = 'supplier'
          THEN 'Procurement, Expenses & Commercial'
        WHEN m.et IN ('role','permission','role_permission','user_role','user_permission')
          THEN 'Permissions & Access'
        WHEN m.et IN ('approval_setting','company_setting','system_setting','smtp_setting','biometric_device')
          THEN 'Settings & Configuration'
        WHEN m.et IN ('notification','notification_rule','notification_rule_role',
                      'notification_global_setting','push_subscription')
          THEN 'Notifications'
        WHEN m.et IN ('report','report_execution','audit_log','activity_log','data_export')
          THEN 'Reports & Analytics'
        WHEN m.et IN ('dashboard','dashboard_widget')
          THEN 'Dashboards & Widgets'
        WHEN m.et IN ('company_event','event_notification')
          THEN 'Events & Calendar'
        WHEN m.et IN ('cms_homepage','external_review','review_source')
          THEN 'Website & CMS'
        ELSE m.eg
      END AS eg,
      m.et,
      m.eid,
      m.ttl,
      m.sub,
      m.url,
      m.pm,
      m.fts_rank,
      m.title_sim
    FROM merged m
  ),
  deduped AS (
    SELECT DISTINCT ON (n.et, n.eid)
      n.eg, n.et, n.eid, n.ttl, n.sub, n.url, n.pm, n.fts_rank, n.title_sim
    FROM normalised n
    ORDER BY n.et, n.eid,
             (n.fts_rank * 0.7 + n.title_sim * 0.3) DESC,
             n.ttl ASC
  )

  SELECT
    d.eg   AS entity_group,
    d.et   AS entity_type,
    d.eid  AS entity_id,
    d.ttl  AS title,
    d.sub  AS subtitle,
    d.url  AS url,
    d.pm   AS permission_module
  FROM deduped d
  WHERE d.et NOT IN (
    'employee', 'user_profile',
    'smtp_setting', 'approval_setting', 'company_setting', 'system_setting',
    'biometric_device', 'notification_rule', 'notification_global_setting',
    'push_subscription', 'dashboard', 'dashboard_widget',
    'audit_log', 'activity_log', 'data_export', 'report_execution',
    'permission', 'role', 'role_permission', 'user_role', 'user_permission'
  )
  ORDER BY (d.fts_rank * 0.7 + d.title_sim * 0.3) DESC, d.ttl ASC
  LIMIT LEAST(p_limit, 50);
$$;

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) FROM anon;
