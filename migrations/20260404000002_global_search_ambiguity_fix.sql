-- ─────────────────────────────────────────────────────────────────────────────
-- Fix: column reference "entity_group" is ambiguous (PG error 42702)
--
-- Root cause: plpgsql RETURNS TABLE declares entity_group/entity_type/… as
-- output variables. Inside RETURN QUERY, unqualified column names are
-- ambiguous between the CTE columns and the plpgsql output variables.
--
-- Fix: rewrite as LANGUAGE sql (no output variables) and compute the dynamic
-- trigram threshold via a CTE instead of a DECLARE variable.
-- ─────────────────────────────────────────────────────────────────────────────

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
  -- ── query normalisation + dynamic threshold ───────────────────────────────
  params AS (
    SELECT
      NULLIF(TRIM(p_query), '') AS q,
      CASE
        WHEN array_length(string_to_array(TRIM(NULLIF(TRIM(p_query), '')), ' '), 1) > 1
        THEN 0.45::FLOAT
        ELSE 0.30::FLOAT
      END AS trgm_threshold
  ),
  parsed AS (
    SELECT
      params.q,
      params.trgm_threshold,
      CASE
        WHEN params.q IS NULL THEN NULL
        ELSE (
          SELECT ts
          FROM (
            SELECT websearch_to_tsquery('simple', params.q) AS ts
          ) t
          -- swallow parse errors by returning NULL if it fails
        )
      END AS tsq
    FROM params
  ),

  -- ── permission resolution ─────────────────────────────────────────────────
  role_perms AS (
    SELECT p.module, BOOL_OR(p.can_view) AS can_view
    FROM   public.user_roles ur
    JOIN   public.role_permissions rp
             ON rp.role_id = ur.role_id
            AND rp.is_active  = true
            AND rp.is_deleted = false
    JOIN   public.permissions p
             ON p.id         = rp.permission_id
            AND p.is_active  = true
            AND p.is_deleted = false
    WHERE  ur.user_id   = auth.uid()
      AND  ur.is_active  = true
      AND  ur.is_deleted = false
    GROUP BY p.module
  ),
  user_perms AS (
    SELECT p.module, BOOL_OR(up.can_view) AS can_view
    FROM   public.user_permissions up
    JOIN   public.permissions p
             ON p.id         = up.permission_id
            AND p.is_active  = true
            AND p.is_deleted = false
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

  -- ── full-text search ──────────────────────────────────────────────────────
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
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY ts_rank(gsi.vec, prs.tsq) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── trigram search (typo-tolerant) ────────────────────────────────────────
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
    WHERE  word_similarity(prs.q, gsi.title) > prs.trgm_threshold
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY word_similarity(prs.q, gsi.title) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── live inquiry search (uses GIN trigram indexes) ────────────────────────
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
    LEFT JOIN public.service_master sm         ON sm.id = i.service_id
    LEFT JOIN public.service_category_master scm ON scm.id = i.service_category_id
    WHERE  (
      i.full_name ILIKE '%' || prs.q || '%'
      OR i.phone  ILIKE '%' || prs.q || '%'
      OR i.email  ILIKE '%' || prs.q || '%'
    )
    LIMIT  LEAST(p_limit, 50) * 2
  ),

  -- ── merge + normalise group names ─────────────────────────────────────────
  merged AS (
    SELECT * FROM fts_matches
    UNION ALL
    SELECT * FROM trigram_matches
    UNION ALL
    SELECT * FROM inquiry_matches
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
        WHEN m.et IN ('notification','notification_rule','notification_rule_role','notification_global_setting','push_subscription')
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

  -- ── deduplicate, keeping best-scored row per entity ───────────────────────
  deduped AS (
    SELECT DISTINCT ON (n.et, n.eid)
      n.eg, n.et, n.eid, n.ttl, n.sub, n.url, n.pm, n.fts_rank, n.title_sim
    FROM normalised n
    ORDER BY n.et, n.eid,
             (n.fts_rank * 0.7 + n.title_sim * 0.3) DESC,
             n.ttl ASC
  )

  -- ── final result ──────────────────────────────────────────────────────────
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
