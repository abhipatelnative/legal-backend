CREATE OR REPLACE FUNCTION public.global_search(
  p_query TEXT,
  p_branch_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  entity_group TEXT,
  entity_type TEXT,
  entity_id UUID,
  title TEXT,
  subtitle TEXT,
  url TEXT,
  permission_module TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH normalized_query AS (
    SELECT NULLIF(TRIM(p_query), '') AS query
  ),
  parsed_query AS (
    SELECT
      nq.query,
      CASE
        WHEN nq.query IS NULL THEN NULL
        ELSE websearch_to_tsquery('simple', nq.query)
      END AS tsq
    FROM normalized_query nq
  ),
  role_perms AS (
    SELECT
      p.module,
      BOOL_OR(p.can_view) AS can_view
    FROM public.user_roles ur
    JOIN public.role_permissions rp
      ON rp.role_id = ur.role_id
     AND rp.is_active = true
     AND rp.is_deleted = false
    JOIN public.permissions p
      ON p.id = rp.permission_id
     AND p.is_active = true
     AND p.is_deleted = false
    WHERE ur.user_id = auth.uid()
      AND ur.is_active = true
      AND ur.is_deleted = false
    GROUP BY p.module
  ),
  user_perms AS (
    SELECT
      p.module,
      BOOL_OR(up.can_view) AS can_view
    FROM public.user_permissions up
    JOIN public.permissions p
      ON p.id = up.permission_id
     AND p.is_active = true
     AND p.is_deleted = false
    WHERE up.user_id = auth.uid()
      AND up.is_active = true
      AND up.is_deleted = false
    GROUP BY p.module
  ),
  allowed_modules AS (
    SELECT
      COALESCE(up.module, rp.module) AS module,
      COALESCE(up.can_view, rp.can_view, false) AS can_view
    FROM role_perms rp
    FULL OUTER JOIN user_perms up
      ON up.module = rp.module
  ),
  filtered_modules AS (
    SELECT am.module
    FROM allowed_modules am
    WHERE am.can_view = true
  ),
  inquiry_live_matches AS (
    SELECT
      'People'::TEXT AS entity_group,
      'inquiry'::TEXT AS entity_type,
      i.id AS entity_id,
      COALESCE(NULLIF(TRIM(i.full_name), ''), NULLIF(TRIM(i.email), ''), NULLIF(TRIM(i.phone), ''), 'Inquiry') AS title,
      NULLIF(
        TRIM(
          concat_ws(
            ' | ',
            i.phone,
            i.email,
            NULLIF(TRIM(concat_ws(' / ', scm.category_name, sm.name)), ''),
            NULLIF(LEFT(TRIM(i.message), 80), ''),
            i.status
          )
        ),
        ''
      ) AS subtitle,
      '/crm/inquiries'::TEXT AS url,
      'crm_inquiries'::TEXT AS permission_module,
      GREATEST(
        COALESCE(
          ts_rank(
            to_tsvector(
              'simple',
              concat_ws(' ', i.full_name, i.phone, i.email, i.status, i.message, sm.name, scm.category_name)
            ),
            pq.tsq
          ),
          0::REAL
        ),
        CASE
          WHEN pq.query IS NOT NULL AND (
            COALESCE(i.full_name, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(i.phone, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(i.email, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(i.message, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(sm.name, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(scm.category_name, '') ILIKE '%' || pq.query || '%'
          ) THEN 0.75::REAL
          ELSE 0::REAL
        END
      ) AS fts_rank,
      GREATEST(
        similarity(COALESCE(i.full_name, ''), COALESCE(pq.query, '')),
        similarity(COALESCE(i.phone, ''), COALESCE(pq.query, '')),
        similarity(COALESCE(i.email, ''), COALESCE(pq.query, '')),
        similarity(COALESCE(sm.name, ''), COALESCE(pq.query, '')),
        similarity(COALESCE(scm.category_name, ''), COALESCE(pq.query, ''))
      ) AS title_similarity
    FROM parsed_query pq
    JOIN filtered_modules fm
      ON fm.module = 'crm_inquiries'
    JOIN public.inquiries i
      ON pq.query IS NOT NULL
    LEFT JOIN public.service_master sm
      ON sm.id = i.service_id
    LEFT JOIN public.service_category_master scm
      ON scm.id = i.service_category_id
    WHERE (
      (
        pq.tsq IS NOT NULL
        AND to_tsvector(
          'simple',
          concat_ws(' ', i.full_name, i.phone, i.email, i.status, i.message, sm.name, scm.category_name)
        ) @@ pq.tsq
      )
      OR COALESCE(i.full_name, '') ILIKE '%' || pq.query || '%'
      OR COALESCE(i.phone, '') ILIKE '%' || pq.query || '%'
      OR COALESCE(i.email, '') ILIKE '%' || pq.query || '%'
      OR COALESCE(i.message, '') ILIKE '%' || pq.query || '%'
      OR COALESCE(sm.name, '') ILIKE '%' || pq.query || '%'
      OR COALESCE(scm.category_name, '') ILIKE '%' || pq.query || '%'
    )
    ORDER BY
      GREATEST(
        COALESCE(
          ts_rank(
            to_tsvector(
              'simple',
              concat_ws(' ', i.full_name, i.phone, i.email, i.status, i.message, sm.name, scm.category_name)
            ),
            pq.tsq
          ),
          0::REAL
        ),
        CASE
          WHEN pq.query IS NOT NULL AND (
            COALESCE(i.full_name, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(i.phone, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(i.email, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(i.message, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(sm.name, '') ILIKE '%' || pq.query || '%'
            OR COALESCE(scm.category_name, '') ILIKE '%' || pq.query || '%'
          ) THEN 0.75::REAL
          ELSE 0::REAL
        END
      ) DESC,
      COALESCE(NULLIF(TRIM(i.full_name), ''), NULLIF(TRIM(i.email), ''), NULLIF(TRIM(i.phone), ''), 'Inquiry') ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100) * 2
  ),
  fts_matches AS (
    SELECT
      gsi.entity_group,
      gsi.entity_type,
      gsi.entity_id,
      gsi.title,
      gsi.subtitle,
      gsi.url,
      gsi.permission_module,
      ts_rank(gsi.vec, pq.tsq) AS fts_rank,
      similarity(gsi.title, pq.query) AS title_similarity
    FROM parsed_query pq
    JOIN public.global_search_index gsi
      ON pq.tsq IS NOT NULL
    JOIN filtered_modules fm
      ON fm.module = gsi.permission_module
    WHERE gsi.vec @@ pq.tsq
      AND (
        p_branch_id IS NULL
        OR gsi.branch_id IS NULL
        OR gsi.branch_id = p_branch_id
      )
    ORDER BY ts_rank(gsi.vec, pq.tsq) DESC, gsi.title ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100) * 4
  ),
  trigram_matches AS (
    SELECT
      gsi.entity_group,
      gsi.entity_type,
      gsi.entity_id,
      gsi.title,
      gsi.subtitle,
      gsi.url,
      gsi.permission_module,
      0::REAL AS fts_rank,
      similarity(gsi.title, pq.query) AS title_similarity
    FROM parsed_query pq
    JOIN public.global_search_index gsi
      ON pq.query IS NOT NULL
    JOIN filtered_modules fm
      ON fm.module = gsi.permission_module
    WHERE gsi.title % pq.query
      AND (
        p_branch_id IS NULL
        OR gsi.branch_id IS NULL
        OR gsi.branch_id = p_branch_id
      )
    ORDER BY similarity(gsi.title, pq.query) DESC, gsi.title ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100) * 4
  ),
  merged_matches AS (
    SELECT * FROM fts_matches
    UNION ALL
    SELECT * FROM trigram_matches
    UNION ALL
    SELECT * FROM inquiry_live_matches
  ),
  normalized_matches AS (
    SELECT
      CASE
        WHEN mm.entity_type = 'supplier' THEN 'Procurement, Expenses & Commercial'
        WHEN mm.entity_type IN ('role', 'permission', 'role_permission', 'user_role', 'user_permission') THEN 'Permissions & Access'
        WHEN mm.entity_type IN ('approval_setting', 'company_setting', 'system_setting', 'smtp_setting', 'biometric_device') THEN 'Settings & Configuration'
        WHEN mm.entity_type IN ('notification', 'notification_rule', 'notification_rule_role', 'notification_global_setting', 'push_subscription') THEN 'Notifications'
        WHEN mm.entity_type IN ('report', 'report_execution', 'audit_log', 'activity_log', 'data_export') THEN 'Reports & Analytics'
        WHEN mm.entity_type IN ('dashboard', 'dashboard_widget') THEN 'Dashboards & Widgets'
        WHEN mm.entity_type IN ('company_event', 'event_notification') THEN 'Events & Calendar'
        WHEN mm.entity_type IN ('cms_homepage', 'external_review', 'review_source') THEN 'Website & CMS'
        ELSE mm.entity_group
      END AS entity_group,
      mm.entity_type,
      mm.entity_id,
      mm.title,
      mm.subtitle,
      mm.url,
      mm.permission_module,
      mm.fts_rank,
      mm.title_similarity
    FROM merged_matches mm
  ),
  deduped_matches AS (
    SELECT DISTINCT ON (nm.entity_type, nm.entity_id)
      nm.entity_group,
      nm.entity_type,
      nm.entity_id,
      nm.title,
      nm.subtitle,
      nm.url,
      nm.permission_module,
      nm.fts_rank,
      nm.title_similarity
    FROM normalized_matches nm
    ORDER BY
      nm.entity_type,
      nm.entity_id,
      (nm.fts_rank * 0.8 + nm.title_similarity * 0.2) DESC,
      nm.title ASC
  )
  SELECT
    dm.entity_group,
    dm.entity_type,
    dm.entity_id,
    dm.title,
    dm.subtitle,
    dm.url,
    dm.permission_module
  FROM deduped_matches dm
  ORDER BY
    (dm.fts_rank * 0.8 + dm.title_similarity * 0.2) DESC,
    dm.title ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
$$;
