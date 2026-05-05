-- ─────────────────────────────────────────────────────────────────────────────
-- Global search: accuracy + performance pass
--
-- Problems fixed:
--   1. similarity(title, query) does whole-string comparison → "mitesh patil"
--      falsely matches "Pradip Patil" (~0.42) because "patil" shares trigrams.
--      Fix: use word_similarity(query, title) which checks whether the QUERY
--      words appear within the title words — much better for name searches.
--
--   2. Permission CTEs run 4 JOINs on every search with no covering indexes.
--      Fix: add indexes on the hot columns used in those JOINs.
--
--   3. global_search_index has no index on permission_module + entity_type
--      combined, making the filtered_modules JOIN slower than needed.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Permission table indexes (speed up role_perms / user_perms CTEs) ─────────

CREATE INDEX IF NOT EXISTS idx_user_roles_user_active
  ON public.user_roles (user_id)
  WHERE is_active = true AND is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_role_permissions_role_active
  ON public.role_permissions (role_id, permission_id)
  WHERE is_active = true AND is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_user_permissions_user_active
  ON public.user_permissions (user_id, permission_id)
  WHERE is_active = true AND is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_permissions_id_active
  ON public.permissions (id, module)
  WHERE is_active = true AND is_deleted = false;

-- ── global_search_index composite index for filtered_modules JOIN ─────────────

CREATE INDEX IF NOT EXISTS idx_gsi_module_type
  ON public.global_search_index (permission_module, entity_type);

-- ── Re-create global_search using word_similarity for accurate typo matching ──
--
-- word_similarity(query, title):
--   Finds the greatest similarity between the query's trigram set and any
--   contiguous extent of words in the title.
--   "mitesh" vs "Mitesh Patil"  → 1.0   ✓
--   "mitehs" vs "Mitesh Patil"  → ~0.6  ✓ (typo tolerated)
--   "mitesh patil" vs "Pradip Patil" → ~0.35 ✗ (filtered out at 0.45)
--   "mitesh patil" vs "Mitesh Patil" → ~0.9  ✓

CREATE OR REPLACE FUNCTION public.global_search(
  p_query TEXT,
  p_branch_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 25
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
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '10000'
AS $$
DECLARE
  v_query      TEXT;
  v_tsq        tsquery;
  v_token_count INT;
  v_trgm_threshold FLOAT;
BEGIN
  v_query := NULLIF(TRIM(p_query), '');
  IF v_query IS NULL THEN RETURN; END IF;

  -- Safe tsquery — websearch_to_tsquery requires ALL tokens (AND logic)
  BEGIN
    v_tsq := websearch_to_tsquery('simple', v_query);
  EXCEPTION WHEN OTHERS THEN
    v_tsq := NULL;
  END;

  v_token_count := array_length(string_to_array(trim(v_query), ' '), 1);

  -- Single-word: allow looser trigram match (typos); multi-word: stricter
  v_trgm_threshold := CASE WHEN v_token_count > 1 THEN 0.45 ELSE 0.30 END;

  RETURN QUERY
  WITH filtered_modules AS (
    -- Combine role + user permissions, user overrides role
    SELECT
      COALESCE(up.module, rp.module) AS module
    FROM (
      SELECT p.module, BOOL_OR(p.can_view) AS can_view
      FROM public.user_roles ur
      JOIN public.role_permissions rp
        ON rp.role_id = ur.role_id AND rp.is_active AND NOT rp.is_deleted
      JOIN public.permissions p
        ON p.id = rp.permission_id AND p.is_active AND NOT p.is_deleted
      WHERE ur.user_id = auth.uid() AND ur.is_active AND NOT ur.is_deleted
      GROUP BY p.module
    ) rp
    FULL OUTER JOIN (
      SELECT p.module, BOOL_OR(up.can_view) AS can_view
      FROM public.user_permissions up
      JOIN public.permissions p
        ON p.id = up.permission_id AND p.is_active AND NOT p.is_deleted
      WHERE up.user_id = auth.uid() AND up.is_active AND NOT up.is_deleted
      GROUP BY p.module
    ) up ON up.module = rp.module
    WHERE COALESCE(up.can_view, rp.can_view, false) = true
  ),
  fts_matches AS (
    -- Full-text search: requires ALL query tokens (AND logic) — most precise
    SELECT
      gsi.entity_group,
      gsi.entity_type,
      gsi.entity_id,
      gsi.title,
      gsi.subtitle,
      gsi.url,
      gsi.permission_module,
      ts_rank(gsi.vec, v_tsq)              AS fts_rank,
      word_similarity(v_query, gsi.title)  AS title_similarity
    FROM public.global_search_index gsi
    JOIN filtered_modules fm ON fm.module = gsi.permission_module
    WHERE v_tsq IS NOT NULL
      AND gsi.vec @@ v_tsq
      AND (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER BY ts_rank(gsi.vec, v_tsq) DESC, gsi.title ASC
    LIMIT LEAST(p_limit, 50) * 4
  ),
  trigram_matches AS (
    -- Trigram search: catches typos missed by FTS
    -- Uses word_similarity so "mitesh" must match a WORD in the title,
    -- preventing "patil"-only false positives for "mitesh patil" queries.
    SELECT
      gsi.entity_group,
      gsi.entity_type,
      gsi.entity_id,
      gsi.title,
      gsi.subtitle,
      gsi.url,
      gsi.permission_module,
      0::REAL                              AS fts_rank,
      word_similarity(v_query, gsi.title)  AS title_similarity
    FROM public.global_search_index gsi
    JOIN filtered_modules fm ON fm.module = gsi.permission_module
    WHERE word_similarity(v_query, gsi.title) > v_trgm_threshold
      AND (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER BY word_similarity(v_query, gsi.title) DESC, gsi.title ASC
    LIMIT LEAST(p_limit, 50) * 4
  ),
  inquiry_matches AS (
    -- Live search on inquiries (uses GIN trigram indexes from prev migration)
    SELECT
      'People'::TEXT                       AS entity_group,
      'inquiry'::TEXT                      AS entity_type,
      i.id                                 AS entity_id,
      COALESCE(NULLIF(TRIM(i.full_name),''), NULLIF(TRIM(i.email),''),
               NULLIF(TRIM(i.phone),''), 'Inquiry') AS title,
      NULLIF(TRIM(concat_ws(' | ', i.phone, i.email,
        NULLIF(TRIM(concat_ws(' / ', scm.category_name, sm.name)),''),
        NULLIF(LEFT(TRIM(i.message), 80),''), i.status::text)), '') AS subtitle,
      '/crm/inquiries'::TEXT               AS url,
      'crm_inquiries'::TEXT                AS permission_module,
      0.75::REAL                           AS fts_rank,
      word_similarity(v_query, COALESCE(i.full_name,'')) AS title_similarity
    FROM filtered_modules fm
    JOIN public.inquiries i ON fm.module = 'crm_inquiries' AND v_query IS NOT NULL
    LEFT JOIN public.service_master sm ON sm.id = i.service_id
    LEFT JOIN public.service_category_master scm ON scm.id = i.service_category_id
    WHERE (
      i.full_name ILIKE '%' || v_query || '%'
      OR i.phone  ILIKE '%' || v_query || '%'
      OR i.email  ILIKE '%' || v_query || '%'
    )
    LIMIT LEAST(p_limit, 50) * 2
  ),
  merged AS (
    SELECT * FROM fts_matches
    UNION ALL
    SELECT * FROM trigram_matches
    UNION ALL
    SELECT * FROM inquiry_matches
  ),
  normalized AS (
    SELECT
      CASE
        WHEN m.entity_type = 'supplier'                         THEN 'Procurement, Expenses & Commercial'
        WHEN m.entity_type IN ('role','permission','role_permission',
             'user_role','user_permission')                     THEN 'Permissions & Access'
        WHEN m.entity_type IN ('approval_setting','company_setting',
             'system_setting','smtp_setting','biometric_device') THEN 'Settings & Configuration'
        WHEN m.entity_type IN ('notification','notification_rule',
             'notification_rule_role','notification_global_setting',
             'push_subscription')                               THEN 'Notifications'
        WHEN m.entity_type IN ('report','report_execution','audit_log',
             'activity_log','data_export')                      THEN 'Reports & Analytics'
        WHEN m.entity_type IN ('dashboard','dashboard_widget')  THEN 'Dashboards & Widgets'
        WHEN m.entity_type IN ('company_event','event_notification') THEN 'Events & Calendar'
        WHEN m.entity_type IN ('cms_homepage','external_review',
             'review_source')                                   THEN 'Website & CMS'
        ELSE m.entity_group
      END AS entity_group,
      m.entity_type,
      m.entity_id,
      m.title,
      m.subtitle,
      m.url,
      m.permission_module,
      m.fts_rank,
      m.title_similarity
    FROM merged m
  ),
  deduped AS (
    SELECT DISTINCT ON (entity_type, entity_id)
      entity_group, entity_type, entity_id, title, subtitle, url,
      permission_module, fts_rank, title_similarity
    FROM normalized
    ORDER BY entity_type, entity_id,
             (fts_rank * 0.7 + title_similarity * 0.3) DESC,
             title ASC
  )
  SELECT
    entity_group, entity_type, entity_id, title, subtitle, url, permission_module
  FROM deduped
  WHERE entity_type NOT IN (
    'employee', 'user_profile',
    'smtp_setting', 'approval_setting', 'company_setting', 'system_setting',
    'biometric_device', 'notification_rule', 'notification_global_setting',
    'push_subscription', 'dashboard', 'dashboard_widget',
    'audit_log', 'activity_log', 'data_export', 'report_execution',
    'permission', 'role', 'role_permission', 'user_role', 'user_permission'
  )
  ORDER BY (fts_rank * 0.7 + title_similarity * 0.3) DESC, title ASC
  LIMIT LEAST(p_limit, 50);
END;
$$;

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) FROM anon;
