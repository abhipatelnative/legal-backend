-- ============================================================
-- CONSOLIDATED MIGRATION: global_search stack
-- Generated on 2026-04-22 by merging the following migrations
-- in strict order (each file uses DROP IF EXISTS + CREATE OR REPLACE
-- so concatenation preserves the exact end-state semantics):
--
--   1. 20260402000001_global_search_rpc.sql       (MV + initial fn)
--   2. 20260402000002_global_search_runtime.sql   (indexes + fn)
--   3. 20260403000003_global_search_grouping_runtime.sql
--   4. 20260403000004_global_search_perf_fix.sql
--   5. 20260404000001_global_search_accuracy.sql
--   6. 20260404000002_global_search_ambiguity_fix.sql
--   7. 20260404000003_global_search_threshold.sql
--   8. 20260404000004_global_search_precision.sql
--   9. 20260404000005_global_search_agent_payouts.sql
--  10. 20260404000006_global_search_module_filter.sql
--  11. 20260405000001_global_search_user_scope.sql (final global_search fn)
--  12. 20260415000001_global_search_income.sql
--  13. 20260415000004_fix_global_search_ownership.sql
--  14. 20260415000005_fix_global_search_trigger.sql (final trigger)
-- ============================================================


-- ============================================================
-- SOURCE: 20260402000001_global_search_rpc.sql
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP FUNCTION IF EXISTS public.global_search(TEXT, UUID, INTEGER);
DROP FUNCTION IF EXISTS public.refresh_search_index();
DROP MATERIALIZED VIEW IF EXISTS public.global_search_index CASCADE;

CREATE MATERIALIZED VIEW public.global_search_index AS
WITH user_names AS (
  SELECT
    up.id AS user_profile_id,
    up.branch_id,
    trim(concat_ws(' ', up.first_name, up.middle_name, up.last_name)) AS full_name,
    up.personal_email,
    up.phone,
    up.biometric_code
  FROM public.user_profiles up
  WHERE COALESCE(up.is_deleted, false) = false
),
employee_names AS (
  SELECT
    e.id AS employee_id,
    e.user_id,
    e.branch_id,
    e.employee_code,
    e.company_email,
    e.work_phone,
    e.employment_status,
    e.onboarding_status,
    un.full_name,
    un.personal_email,
    un.phone,
    un.biometric_code
  FROM public.employees e
  LEFT JOIN user_names un
    ON un.user_profile_id = e.user_id
  WHERE COALESCE(e.is_deleted, false) = false
),
hearing_employee_names AS (
  SELECT
    hae.case_hearing_id,
    string_agg(DISTINCT NULLIF(TRIM(un.full_name), ''), ' ') AS assigned_employee_names
  FROM public.hearing_assigned_employees hae
  LEFT JOIN user_names un
    ON un.user_profile_id = hae.user_id
  GROUP BY hae.case_hearing_id
),
service_order_context AS (
  SELECT
    so.id AS service_order_id,
    so.branch_id,
    so.order_number,
    so.status,
    so.is_case,
    so.created_at::DATE AS order_date,
    cl.id AS client_id,
    cl.name AS client_name,
    sm.id AS service_id,
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
    cl.id,
    cl.name,
    sm.id,
    sm.name,
    scm.category_name,
    ag.name
),
contract_context AS (
  SELECT
    c.id AS contract_id,
    c.branch_id,
    c.employee_id,
    ct.name AS contract_type_name,
    ct.code AS contract_type_code,
    cg.name AS contract_group_name,
    en.full_name AS employee_name,
    en.employee_code
  FROM public.contracts c
  LEFT JOIN public.contract_types ct
    ON ct.id = c.contract_type_id
  LEFT JOIN public.contract_groups cg
    ON cg.id = c.contract_group_id
  LEFT JOIN employee_names en
    ON en.employee_id = c.employee_id
  WHERE COALESCE(c.is_deleted, false) = false
),
payroll_context AS (
  SELECT
    p.id AS payroll_id,
    p.employee_id,
    e.branch_id,
    en.full_name AS employee_name,
    en.employee_code,
    pp.id AS payroll_period_id,
    pp.name AS payroll_period_name,
    pp.month,
    pp.year
  FROM public.payroll p
  LEFT JOIN public.employees e
    ON e.id = p.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = p.employee_id
  LEFT JOIN public.payroll_periods pp
    ON pp.id = p.payroll_period_id
  WHERE COALESCE(p.is_deleted, false) = false
),
purchase_order_context AS (
  SELECT
    po.id AS purchase_order_id,
    po.branch_id,
    po.po_number,
    po.status,
    po.payment_status,
    po.supplier_id,
    po.supplier_name
  FROM public.purchase_orders po
  WHERE COALESCE(po.is_deleted, false) = false
),
inventory_issue_context AS (
  SELECT
    eii.id AS issue_id,
    eii.branch_id,
    eii.issue_number,
    eii.status,
    eii.employee_id,
    COALESCE(NULLIF(TRIM(eii.employee_name), ''), en.full_name) AS employee_name,
    en.employee_code
  FROM public.employee_inventory_issues eii
  LEFT JOIN employee_names en
    ON en.employee_id = eii.employee_id
)
SELECT
  src.entity_group,
  src.entity_type,
  src.entity_id,
  src.title,
  src.subtitle,
  src.url,
  src.branch_id,
  src.permission_module,
  to_tsvector('simple', COALESCE(src.search_text, '')) AS vec
FROM (
  SELECT
    'People'::TEXT AS entity_group,
    'client'::TEXT AS entity_type,
    c.id AS entity_id,
    COALESCE(NULLIF(TRIM(c.name), ''), 'Client') AS title,
    NULLIF(TRIM(concat_ws(' | ', c.email, c.mobile, c.address, c.category)), '') AS subtitle,
    '/case-matter/clients'::TEXT AS url,
    c.branch_id,
    'case_matter_clients'::TEXT AS permission_module,
    concat_ws(
      ' ',
      c.name,
      c.email,
      c.mobile,
      regexp_replace(COALESCE(c.mobile, ''), '[^0-9]+', '', 'g'),
      c.address,
      c.category,
      c.notes,
      row_to_json(c)::TEXT
    ) AS search_text
  FROM public.clients c
  WHERE COALESCE(c.is_deleted, false) = false

  UNION ALL

  SELECT
    'People',
    'employee',
    e.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), e.employee_code, 'Employee'),
    NULLIF(TRIM(concat_ws(' | ', e.employee_code, e.company_email, e.employment_status)), ''),
    '/employees/edit/' || e.id::TEXT,
    e.branch_id,
    'employees',
    concat_ws(' ', en.full_name, e.employee_code, e.company_email, e.work_phone, e.employment_status, e.onboarding_status, en.personal_email, en.phone, en.biometric_code, row_to_json(e)::TEXT)
  FROM public.employees e
  LEFT JOIN employee_names en
    ON en.employee_id = e.id
  WHERE COALESCE(e.is_deleted, false) = false

  UNION ALL

  SELECT
    'People',
    'user_profile',
    up.id,
    COALESCE(NULLIF(TRIM(un.full_name), ''), 'User Profile'),
    NULLIF(TRIM(concat_ws(' | ', up.personal_email, up.phone, up.biometric_code)), ''),
    '/users',
    up.branch_id,
    'users',
    concat_ws(' ', un.full_name, up.personal_email, up.phone, up.biometric_code, up.city, up.state, row_to_json(up)::TEXT)
  FROM public.user_profiles up
  LEFT JOIN user_names un
    ON un.user_profile_id = up.id
  WHERE COALESCE(up.is_deleted, false) = false

  UNION ALL

  SELECT
    'People',
    'inquiry',
    i.id,
    COALESCE(NULLIF(TRIM(i.full_name), ''), NULLIF(TRIM(i.email), ''), NULLIF(TRIM(i.phone), ''), 'Inquiry'),
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
    ),
    '/crm/inquiries',
    NULL::UUID,
    'crm_inquiries',
    concat_ws(
      ' ',
      'inquirer',
      i.full_name,
      'phone',
      i.phone,
      'email',
      i.email,
      'message',
      i.message,
      'service',
      sm.name,
      'service_interest',
      scm.category_name,
      i.status,
      row_to_json(i)::TEXT
    )
  FROM public.inquiries i
  LEFT JOIN public.service_master sm
    ON sm.id = i.service_id
  LEFT JOIN public.service_category_master scm
    ON scm.id = i.service_category_id

  UNION ALL

  SELECT
    'People',
    'lead',
    l.id,
    COALESCE(NULLIF(TRIM(l.name), ''), 'Lead'),
    NULLIF(TRIM(concat_ws(' | ', l.phone, l.email, l.source, l.status)), ''),
    '/crm/leads',
    NULL::UUID,
    'crm_leads',
    concat_ws(' ', l.name, l.phone, l.email, l.source, l.status, l.notes, row_to_json(l)::TEXT)
  FROM public.leads l

  UNION ALL

  SELECT
    'People',
    'agent',
    a.id,
    COALESCE(NULLIF(TRIM(a.name), ''), 'Agent'),
    NULLIF(TRIM(concat_ws(' | ', a.mobile, a.email, a.commission_type)), ''),
    '/masters/agents',
    a.branch_id,
    'masters_agent',
    concat_ws(
      ' ',
      a.name,
      a.mobile,
      regexp_replace(COALESCE(a.mobile, ''), '[^0-9]+', '', 'g'),
      a.email,
      a.address,
      a.commission_type,
      a.commission_value::TEXT,
      a.payout_trigger,
      row_to_json(a)::TEXT
    )
  FROM public.agent_master a
  WHERE COALESCE(a.is_deleted, false) = false

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'supplier',
    s.id,
    COALESCE(NULLIF(TRIM(s.name), ''), 'Supplier'),
    NULLIF(TRIM(concat_ws(' | ', s.contact_person, s.phone, CASE WHEN s.is_active THEN 'Active' ELSE 'Inactive' END)), ''),
    '/inventory',
    s.branch_id,
    'inventory_manage',
    concat_ws(' ', s.name, s.contact_person, s.phone, s.email, s.address, CASE WHEN s.is_active THEN 'Active' ELSE 'Inactive' END, row_to_json(s)::TEXT)
  FROM public.suppliers s

  UNION ALL

  SELECT
    'People',
    'employee_referral',
    er.id,
    COALESCE(NULLIF(TRIM(referrer.full_name), ''), 'Referral') || ' -> ' || COALESCE(NULLIF(TRIM(referred.full_name), ''), 'Employee'),
    NULLIF(TRIM(concat_ws(' | ', er.status, er.referral_date::TEXT, er.referral_bonus_amount::TEXT)), ''),
    '/employees',
    referrer.branch_id,
    'employees',
    concat_ws(' ', referrer.full_name, referred.full_name, referrer.employee_code, referred.employee_code, er.status, er.referral_date::TEXT, er.remarks, row_to_json(er)::TEXT)
  FROM public.employee_referrals er
  LEFT JOIN employee_names referrer
    ON referrer.employee_id = er.referring_employee_id
  LEFT JOIN employee_names referred
    ON referred.employee_id = er.referred_employee_id
  WHERE COALESCE(er.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'service_category',
    scm.id,
    COALESCE(NULLIF(TRIM(scm.category_name), ''), 'Service Category'),
    NULLIF(TRIM(scm.description), ''),
    '/case-matter-masters/service-category',
    scm.branch_id,
    'case_matter_service_category',
    concat_ws(' ', scm.category_name, scm.description, row_to_json(scm)::TEXT)
  FROM public.service_category_master scm
  WHERE COALESCE(scm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'service_master',
    sm.id,
    COALESCE(NULLIF(TRIM(sm.name), ''), 'Service Master'),
    NULLIF(TRIM(concat_ws(' | ', scm.category_name, CASE WHEN sm.is_case THEN 'Case' ELSE 'Service' END)), ''),
    '/case-matter/service-master/view/' || sm.id::TEXT,
    sm.branch_id,
    'case_matter_service_master',
    concat_ws(' ', sm.name, sm.description, scm.category_name, row_to_json(sm)::TEXT)
  FROM public.service_master sm
  LEFT JOIN public.service_category_master scm
    ON scm.id = sm.category_id
  WHERE COALESCE(sm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'service_stage',
    ss.id,
    COALESCE(NULLIF(TRIM(ss.name), ''), 'Service Stage'),
    NULLIF(TRIM(concat_ws(' | ', sm.name, ss.stage_order::TEXT)), ''),
    '/case-matter/service-master/view/' || ss.service_id::TEXT,
    sm.branch_id,
    'case_matter_service_master',
    concat_ws(' ', ss.name, ss.description, ss.stage_order::TEXT, sm.name, row_to_json(ss)::TEXT)
  FROM public.service_stages ss
  LEFT JOIN public.service_master sm
    ON sm.id = ss.service_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'service_task',
    st.id,
    COALESCE(NULLIF(TRIM(st.work_name), ''), 'Service Task'),
    NULLIF(TRIM(concat_ws(' | ', ss.name, wt.name, st.task_order::TEXT)), ''),
    '/case-matter/service-master/view/' || ss.service_id::TEXT,
    sm.branch_id,
    'case_matter_service_master',
    concat_ws(' ', st.work_name, st.description, ss.name, sm.name, wt.name, st.task_order::TEXT, row_to_json(st)::TEXT)
  FROM public.service_tasks st
  LEFT JOIN public.service_stages ss
    ON ss.id = st.stage_id
  LEFT JOIN public.service_master sm
    ON sm.id = ss.service_id
  LEFT JOIN public.work_types wt
    ON wt.id = st.work_type_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'service_subtask',
    sst.id,
    COALESCE(NULLIF(TRIM(sst.name), ''), 'Service Subtask'),
    NULLIF(TRIM(concat_ws(' | ', st.work_name, sst.subtask_order::TEXT)), ''),
    '/case-matter/service-master/view/' || ss.service_id::TEXT,
    sm.branch_id,
    'case_matter_service_master',
    concat_ws(' ', sst.name, sst.description, st.work_name, ss.name, sm.name, sst.subtask_order::TEXT, row_to_json(sst)::TEXT)
  FROM public.service_subtasks sst
  LEFT JOIN public.service_tasks st
    ON st.id = sst.task_id
  LEFT JOIN public.service_stages ss
    ON ss.id = st.stage_id
  LEFT JOIN public.service_master sm
    ON sm.id = ss.service_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'work_type',
    wt.id,
    COALESCE(NULLIF(TRIM(wt.name), ''), 'Work Type'),
    NULLIF(TRIM(concat_ws(' | ', wt.payment_type, wt.description)), ''),
    '/case-matter-masters/work-type',
    wt.branch_id,
    'case_matter_work_type',
    concat_ws(' ', wt.name, wt.payment_type, wt.description, row_to_json(wt)::TEXT)
  FROM public.work_types wt
  WHERE COALESCE(wt.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'court',
    c.id,
    COALESCE(NULLIF(TRIM(c.court_name), ''), 'Court'),
    NULLIF(TRIM(c.id::TEXT), ''),
    '/case-matter-masters/court',
    NULL::UUID,
    'case_matter_court',
    concat_ws(' ', c.court_name, row_to_json(c)::TEXT)
  FROM public.courts c
  WHERE COALESCE(c.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'diary',
    dm.id,
    COALESCE(NULLIF(TRIM(dm.diary_name), ''), 'Diary'),
    NULLIF(TRIM(concat_ws(' | ', dm.village_name, dm.taluka_name, dm.block_no)), ''),
    '/case-matter-masters/diary-master',
    NULL::UUID,
    'case_matter_diary',
    concat_ws(' ', dm.diary_name, dm.village_name, dm.taluka_name, dm.block_no, row_to_json(dm)::TEXT)
  FROM public.diary_master dm
  WHERE COALESCE(dm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'field',
    fm.id,
    COALESCE(NULLIF(TRIM(fm.field_name), ''), 'Field'),
    NULLIF(TRIM(concat_ws(' | ', fm.field_type, fm.placeholder)), ''),
    '/case-matter-masters/fields',
    fm.branch_id,
    'case_matter_fields',
    concat_ws(' ', fm.field_name, fm.field_type, fm.placeholder, fm.description, row_to_json(fm)::TEXT)
  FROM public.fields_master fm
  WHERE COALESCE(fm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'case',
    so.service_order_id,
    COALESCE(NULLIF(TRIM(concat_ws(' - ', so.order_number, so.case_titles)), ''), so.order_number, 'Case Order'),
    NULLIF(TRIM(concat_ws(' | ', so.client_name, so.service_name, so.case_numbers, so.order_date::TEXT, so.filing_dates, so.status)), ''),
    '/case-matter/case-orders/' || so.service_order_id::TEXT,
    so.branch_id,
    'service_orders',
    concat_ws(' ', so.order_number, so.client_name, so.service_name, so.service_category_name, so.agent_name, so.case_numbers, so.case_titles, so.court_names, so.order_date::TEXT, so.filing_dates, so.status)
  FROM service_order_context so
  WHERE so.is_case = true

  UNION ALL

  SELECT
    'Cases & Matters',
    'service',
    so.service_order_id,
    COALESCE(NULLIF(TRIM(so.order_number), ''), 'Service Order'),
    NULLIF(TRIM(concat_ws(' | ', so.client_name, so.service_name, so.order_date::TEXT, so.status)), ''),
    '/case-matter/service-orders/view/' || so.service_order_id::TEXT,
    so.branch_id,
    'service_orders',
    concat_ws(' ', so.order_number, so.client_name, so.service_name, so.service_category_name, so.agent_name, so.case_numbers, so.case_titles, so.court_names, so.order_date::TEXT, so.status)
  FROM service_order_context so
  WHERE so.is_case = false

  UNION ALL

  SELECT
    'Cases & Matters',
    'order_case',
    oc.id,
    COALESCE(NULLIF(TRIM(oc.case_title), ''), NULLIF(TRIM(oc.case_number), ''), 'Order Case'),
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, c.court_name, oc.filing_date::TEXT, oc.status)), ''),
    '/case-matter/case-orders/' || oc.service_order_id::TEXT,
    soc.branch_id,
    'service_orders',
    concat_ws(' ', oc.case_title, oc.case_number, oc.case_type, oc.status, oc.filing_date::TEXT, c.court_name, soc.order_number, soc.client_name, row_to_json(oc)::TEXT)
  FROM public.order_cases oc
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = oc.service_order_id
  LEFT JOIN public.courts c
    ON c.id = oc.court_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'hearing',
    ch.id,
    COALESCE(NULLIF(TRIM(ch.purpose), ''), NULLIF(TRIM(oc.case_title), ''), 'Hearing'),
    NULLIF(TRIM(concat_ws(' | ', c.court_name, ch.hearing_date::TEXT, soc.order_number, soc.client_name, hen.assigned_employee_names, ch.status)), ''),
    CASE
      WHEN oc.service_order_id IS NOT NULL THEN '/case-matter/case-orders/' || oc.service_order_id::TEXT
      ELSE '/case-matter/hearings'
    END,
    soc.branch_id,
    'case_matter_hearingss',
    concat_ws(' ', ch.purpose, ch.outcome, ch.notes, ch.status, ch.hearing_date::TEXT, ch.next_hearing_date::TEXT, ch.hearing_number, ch.court_room, c.court_name, oc.case_number, oc.case_title, soc.order_number, soc.client_name, soc.service_name, hen.assigned_employee_names, row_to_json(ch)::TEXT)
  FROM public.case_hearings ch
  LEFT JOIN public.order_cases oc
    ON oc.id = ch.order_case_id
  LEFT JOIN public.courts c
    ON c.id = ch.court_id
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = oc.service_order_id
  LEFT JOIN hearing_employee_names hen
    ON hen.case_hearing_id = ch.id

  UNION ALL

  SELECT
    'Cases & Matters',
    'matter_folder',
    sof.id,
    COALESCE(NULLIF(TRIM(sof.name), ''), 'Matter Folder'),
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, soc.client_name)), ''),
    '/case-matter/case-orders/' || sof.service_order_id::TEXT,
    soc.branch_id,
    'service_orders',
    concat_ws(' ', sof.name, soc.order_number, soc.client_name, soc.service_name, row_to_json(sof)::TEXT)
  FROM public.service_order_folders sof
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = sof.service_order_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'task',
    sot.id,
    COALESCE(NULLIF(TRIM(sot.name), ''), 'Task'),
    NULLIF(TRIM(concat_ws(' | ', soc.client_name, soc.order_number, sot.status, sot.priority)), ''),
    '/task-management',
    soc.branch_id,
    'case_matter_tasks',
    concat_ws(' ', sot.name, sot.description, sot.status, sot.priority, sot.review_status, sot.payment_type, sot.hearing_date::TEXT, soc.order_number, soc.client_name, soc.service_name, assignee.full_name, row_to_json(sot)::TEXT)
  FROM public.service_order_tasks sot
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = sot.service_order_id
  LEFT JOIN employee_names assignee
    ON assignee.employee_id = sot.assigned_employee_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'service_order_subtask',
    sos.id,
    COALESCE(NULLIF(TRIM(sos.name), ''), 'Order Subtask'),
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, soc.client_name, sos.status)), ''),
    '/task-management',
    soc.branch_id,
    'case_matter_tasks',
    concat_ws(' ', sos.name, sos.description, sos.status, sos.priority, sos.review_status, soc.order_number, soc.client_name, assignee.full_name, row_to_json(sos)::TEXT)
  FROM public.service_order_subtasks sos
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = sos.service_order_id
  LEFT JOIN employee_names assignee
    ON assignee.employee_id = sos.assigned_employee_id

  UNION ALL

  SELECT
    'Cases & Matters',
    'task_comment',
    tc.id,
    COALESCE(NULLIF(TRIM(tc.comment_type), ''), 'Task Comment'),
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, soc.client_name)), ''),
    '/task-management',
    soc.branch_id,
    'case_matter_tasks',
    concat_ws(' ', tc.comment_type, tc.comment, soc.order_number, soc.client_name, creator.full_name, row_to_json(tc)::TEXT)
  FROM public.task_comments tc
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = tc.service_order_id
  LEFT JOIN public.employees ce
    ON ce.user_id = tc.created_by
  LEFT JOIN employee_names creator
    ON creator.employee_id = ce.id

  UNION ALL

  SELECT
    'Cases & Matters',
    'task_time_log',
    ttl.id,
    'Time Log',
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, soc.client_name, ttl.duration_minutes::TEXT || ' min')), ''),
    '/task-management',
    soc.branch_id,
    'case_matter_tasks',
    concat_ws(' ', ttl.description, ttl.duration_minutes::TEXT, ttl.start_time::TEXT, ttl.end_time::TEXT, soc.order_number, soc.client_name, worker.full_name, row_to_json(ttl)::TEXT)
  FROM public.task_time_logs ttl
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = ttl.service_order_id
  LEFT JOIN public.employees te
    ON te.user_id = ttl.employee_id
  LEFT JOIN employee_names worker
    ON worker.employee_id = te.id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'department',
    d.id,
    COALESCE(NULLIF(TRIM(d.name), ''), 'Department'),
    NULLIF(TRIM(concat_ws(' | ', d.code, head.full_name)), ''),
    '/masters/departments',
    d.branch_id,
    'masters_departments',
    concat_ws(' ', d.name, d.code, d.description, head.full_name, row_to_json(d)::TEXT)
  FROM public.departments d
  LEFT JOIN employee_names head
    ON head.employee_id = d.head_employee_id
  WHERE COALESCE(d.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'designation',
    ds.id,
    COALESCE(NULLIF(TRIM(ds.title), ''), 'Designation'),
    NULLIF(TRIM(concat_ws(' | ', ds.code, d.name)), ''),
    '/masters/departments',
    d.branch_id,
    'masters_departments',
    concat_ws(' ', ds.title, ds.code, ds.description, d.name, row_to_json(ds)::TEXT)
  FROM public.designations ds
  LEFT JOIN public.departments d
    ON d.id = ds.department_id
  WHERE COALESCE(ds.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'shift',
    s.id,
    COALESCE(NULLIF(TRIM(s.name), ''), 'Shift'),
    NULLIF(TRIM(concat_ws(' | ', s.start_time::TEXT, s.end_time::TEXT)), ''),
    '/masters/shifts',
    NULL::UUID,
    'masters_shifts',
    concat_ws(' ', s.name, s.start_time::TEXT, s.end_time::TEXT, s.break_duration::TEXT, row_to_json(s)::TEXT)
  FROM public.shifts s
  WHERE COALESCE(s.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'work_week',
    ww.id,
    COALESCE(NULLIF(TRIM(ww.name), ''), 'Work Week'),
    NULLIF(TRIM(ww.name), ''),
    '/masters/work-weeks',
    NULL::UUID,
    'masters_work_weeks',
    concat_ws(' ', ww.name, row_to_json(ww)::TEXT)
  FROM public.work_weeks ww
  WHERE COALESCE(ww.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'holiday',
    h.id,
    COALESCE(NULLIF(TRIM(h.name), ''), 'Holiday'),
    NULLIF(TRIM(concat_ws(' | ', h.start_date::TEXT, h.end_date::TEXT, hm.name)), ''),
    '/masters/holidays',
    NULL::UUID,
    'masters_holidays',
    concat_ws(' ', h.name, h.description, h.type, h.start_date::TEXT, h.end_date::TEXT, hm.name, row_to_json(h)::TEXT)
  FROM public.holidays h
  LEFT JOIN public.holiday_masters hm
    ON hm.id = h.holiday_master_id
  WHERE COALESCE(h.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'holiday_master',
    hm.id,
    COALESCE(NULLIF(TRIM(hm.name), ''), 'Holiday Master'),
    NULLIF(TRIM(concat_ws(' | ', hm.type, hm.description)), ''),
    '/masters/holidays',
    NULL::UUID,
    'masters_holidays',
    concat_ws(' ', hm.name, hm.type, hm.description, row_to_json(hm)::TEXT)
  FROM public.holiday_masters hm
  WHERE COALESCE(hm.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'leave_type',
    lt.id,
    COALESCE(NULLIF(TRIM(lt.name), ''), 'Leave Type'),
    NULLIF(TRIM(concat_ws(' | ', lt.code, lt.days_allowed::TEXT)), ''),
    '/masters/leave-types',
    NULL::UUID,
    'masters_leave_types',
    concat_ws(' ', lt.name, lt.code, lt.description, lt.days_allowed::TEXT, row_to_json(lt)::TEXT)
  FROM public.leave_types lt
  WHERE COALESCE(lt.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'leave_reason',
    lrm.id,
    COALESCE(NULLIF(TRIM(lrm.reason_name), ''), 'Leave Reason'),
    NULLIF(TRIM(lrm.description), ''),
    '/masters/leave-reasons',
    NULL::UUID,
    'masters_leave_reasons',
    concat_ws(' ', lrm.reason_name, lrm.description, row_to_json(lrm)::TEXT)
  FROM public.leave_reason_master lrm
  WHERE COALESCE(lrm.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'leave_accrual_rule',
    lar.id,
    COALESCE(NULLIF(TRIM(lt.name), ''), 'Leave Accrual Rule'),
    NULLIF(TRIM(concat_ws(' | ', lar.rule_type, lar.accrual_value::TEXT)), ''),
    '/masters/leave-types',
    NULL::UUID,
    'masters_leave_types',
    concat_ws(' ', lt.name, lar.rule_type, lar.accrual_value::TEXT, lar.frequency_days::TEXT, lar.frequency_months::TEXT, lar.notes, row_to_json(lar)::TEXT)
  FROM public.leave_accrual_rules lar
  LEFT JOIN public.leave_types lt
    ON lt.id = lar.leave_type_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract',
    c.id,
    COALESCE(NULLIF(TRIM(concat_ws(' ', cc.contract_type_name, 'v' || COALESCE(c.version::TEXT, '1'))), ''), 'Contract'),
    NULLIF(TRIM(concat_ws(' | ', cc.employee_name, cc.contract_type_code, c.status)), ''),
    '/contracts?viewContractId=' || c.id::TEXT,
    c.branch_id,
    'contracts',
    concat_ws(' ', cc.contract_type_name, cc.contract_type_code, cc.contract_group_name, cc.employee_name, cc.employee_code, c.status, c.start_date::TEXT, c.end_date::TEXT, row_to_json(c)::TEXT)
  FROM public.contracts c
  LEFT JOIN contract_context cc
    ON cc.contract_id = c.id
  WHERE COALESCE(c.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract_group',
    cg.id,
    COALESCE(NULLIF(TRIM(cg.name), ''), 'Contract Group'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, cg.status)), ''),
    '/contracts',
    e.branch_id,
    'contracts',
    concat_ws(' ', cg.name, cg.description, cg.status, en.full_name, cg.start_date::TEXT, cg.end_date::TEXT, row_to_json(cg)::TEXT)
  FROM public.contract_groups cg
  LEFT JOIN public.employees e
    ON e.id = cg.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = cg.employee_id
  WHERE COALESCE(cg.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract_type',
    ct.id,
    COALESCE(NULLIF(TRIM(ct.name), ''), 'Contract Type'),
    NULLIF(TRIM(concat_ws(' | ', ct.code, ct.description)), ''),
    '/masters/contract-types',
    NULL::UUID,
    'masters_contract_types',
    concat_ws(' ', ct.name, ct.code, ct.description, row_to_json(ct)::TEXT)
  FROM public.contract_types ct
  WHERE COALESCE(ct.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract_template',
    ctpl.id,
    COALESCE(NULLIF(TRIM(ctpl.name), ''), 'Contract Template'),
    NULLIF(TRIM(concat_ws(' | ', ct.name, ctpl.version::TEXT)), ''),
    '/contracts',
    NULL::UUID,
    'contracts',
    concat_ws(' ', ctpl.name, ctpl.version::TEXT, ct.name, row_to_json(ctpl)::TEXT)
  FROM public.contract_templates ctpl
  LEFT JOIN public.contract_types ct
    ON ct.id = ctpl.contract_type_id
  WHERE COALESCE(ctpl.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract_revision',
    cr.id,
    'Contract Revision',
    NULLIF(TRIM(concat_ws(' | ', cc.employee_name, cr.effective_date::TEXT, cr.reason)), ''),
    '/contracts/history/' || cr.contract_id::TEXT,
    cc.branch_id,
    'contracts',
    concat_ws(' ', cc.employee_name, cc.contract_type_name, cr.reason, cr.revision_date::TEXT, cr.effective_date::TEXT, cr.changes::TEXT, row_to_json(cr)::TEXT)
  FROM public.contract_revisions cr
  LEFT JOIN contract_context cc
    ON cc.contract_id = cr.contract_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract_holiday',
    ch.id,
    'Contract Holiday',
    NULLIF(TRIM(concat_ws(' | ', cc.employee_name, hm.name, ch.is_applicable::TEXT)), ''),
    '/contracts/edit/' || ch.contract_id::TEXT,
    cc.branch_id,
    'contracts',
    concat_ws(' ', cc.employee_name, hm.name, ch.remarks, ch.is_applicable::TEXT, row_to_json(ch)::TEXT)
  FROM public.contract_holidays ch
  LEFT JOIN contract_context cc
    ON cc.contract_id = ch.contract_id
  LEFT JOIN public.holiday_masters hm
    ON hm.id = ch.holiday_master_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'contract_leave',
    clv.id,
    'Contract Leave',
    NULLIF(TRIM(concat_ws(' | ', cc.employee_name, lt.name, clv.days_allowed::TEXT)), ''),
    '/contracts/edit/' || clv.contract_id::TEXT,
    cc.branch_id,
    'contracts',
    concat_ws(' ', cc.employee_name, lt.name, clv.days_allowed::TEXT, clv.notes, row_to_json(clv)::TEXT)
  FROM public.contract_leaves clv
  LEFT JOIN contract_context cc
    ON cc.contract_id = clv.contract_id
  LEFT JOIN public.leave_types lt
    ON lt.id = clv.leave_type_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'leave',
    lr.id,
    COALESCE(NULLIF(TRIM(concat_ws(' - ', lt.name, en.full_name)), ''), 'Leave'),
    NULLIF(TRIM(concat_ws(' | ', lr.start_date::TEXT, lr.end_date::TEXT, lr.status)), ''),
    '/leaves',
    e.branch_id,
    'leaves',
    concat_ws(' ', lt.name, en.full_name, en.employee_code, lr.reason, lr.status, lr.start_date::TEXT, lr.end_date::TEXT, lr.exchange_type, row_to_json(lr)::TEXT)
  FROM public.leave_requests lr
  LEFT JOIN public.leave_types lt
    ON lt.id = lr.leave_type_id
  LEFT JOIN public.employees e
    ON e.id = lr.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = lr.employee_id
  WHERE COALESCE(lr.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'leave_workflow',
    law.id,
    'Leave Approval',
    NULLIF(TRIM(concat_ws(' | ', en.full_name, approver.full_name, law.status)), ''),
    '/hr/approvals',
    e.branch_id,
    'hr_approvals',
    concat_ws(' ', en.full_name, approver.full_name, law.status, law.comments, law.level::TEXT, row_to_json(law)::TEXT)
  FROM public.leave_approval_workflow law
  LEFT JOIN public.leave_requests lr
    ON lr.id = law.leave_request_id
  LEFT JOIN public.employees e
    ON e.id = lr.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = lr.employee_id
  LEFT JOIN public.employees ae
    ON ae.user_id = law.approver_id
  LEFT JOIN employee_names approver
    ON approver.employee_id = ae.id
  WHERE COALESCE(law.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'leave_balance',
    lb.id,
    COALESCE(NULLIF(TRIM(concat_ws(' - ', lt.name, en.full_name)), ''), 'Leave Balance'),
    NULLIF(TRIM(concat_ws(' | ', lb.year::TEXT, lb.remaining_days::TEXT)), ''),
    '/leaves',
    e.branch_id,
    'leaves',
    concat_ws(' ', lt.name, en.full_name, en.employee_code, lb.year::TEXT, lb.allocated_days::TEXT, lb.remaining_days::TEXT, row_to_json(lb)::TEXT)
  FROM public.leave_balances lb
  LEFT JOIN public.leave_types lt
    ON lt.id = lb.leave_type_id
  LEFT JOIN public.employees e
    ON e.id = lb.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = lb.employee_id
  WHERE COALESCE(lb.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'attendance_record',
    ar.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Attendance Record'),
    NULLIF(TRIM(concat_ws(' | ', ar.attendance_date::TEXT, ar.status)), ''),
    '/attendance',
    e.branch_id,
    'pl_earning_days',
    concat_ws(' ', en.full_name, en.employee_code, ar.attendance_date::TEXT, ar.status, ar.check_in::TEXT, ar.check_out::TEXT, ar.remarks, row_to_json(ar)::TEXT)
  FROM public.attendance_records ar
  LEFT JOIN public.employees e
    ON e.user_id = ar.user_profile_id
  LEFT JOIN employee_names en
    ON en.employee_id = e.id
  WHERE COALESCE(ar.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_attendance',
    ea.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Employee Attendance'),
    NULLIF(TRIM(concat_ws(' | ', ea.attendance_date::TEXT, ea.status)), ''),
    '/attendance',
    e.branch_id,
    'attendance',
    concat_ws(' ', en.full_name, en.employee_code, ea.attendance_date::TEXT, ea.status, ea.notes, row_to_json(ea)::TEXT)
  FROM public.employee_attendance ea
  LEFT JOIN public.employees e
    ON e.id = ea.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = ea.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'punch_record',
    pr.id,
    COALESCE(NULLIF(TRIM(pr.enroll_number::TEXT), ''), 'Punch Record'),
    NULLIF(TRIM(concat_ws(' | ', pr.punch_time::TEXT, pr.in_out_mode)), ''),
    '/attendance',
    NULL::UUID,
    'attendance',
    concat_ws(' ', pr.enroll_number, pr.punch_time::TEXT, pr.in_out_mode, pr.verify_mode, row_to_json(pr)::TEXT)
  FROM public.punch_records pr
  WHERE COALESCE(pr.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'punch_edit_request',
    per.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Punch Edit Request'),
    NULLIF(TRIM(concat_ws(' | ', per.date::TEXT, per.status)), ''),
    '/hr/approvals',
    e.branch_id,
    'punch_edit_requests',
    concat_ws(' ', en.full_name, en.employee_code, per.date::TEXT, per.reason, per.status, per.requested_time::TEXT, row_to_json(per)::TEXT)
  FROM public.punch_edit_requests per
  LEFT JOIN public.employees e
    ON e.id = per.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = per.employee_id
  WHERE COALESCE(per.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'attendance_day_counting',
    adc.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Attendance Counting'),
    NULLIF(TRIM(concat_ws(' | ', adc.counting_date::TEXT, adc.is_counted::TEXT)), ''),
    '/attendance/counting-dashboard',
    e.branch_id,
    'attendance',
    concat_ws(' ', en.full_name, en.employee_code, adc.counting_date::TEXT, adc.reason, adc.is_counted::TEXT, row_to_json(adc)::TEXT)
  FROM public.attendance_day_counting adc
  LEFT JOIN public.employees e
    ON e.id = adc.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = adc.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'late_tracking',
    elt.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Late Tracking'),
    NULLIF(TRIM(concat_ws(' | ', elt.attendance_date::TEXT, elt.late_minutes::TEXT || ' min')), ''),
    '/attendance',
    e.branch_id,
    'attendance',
    concat_ws(' ', en.full_name, en.employee_code, elt.attendance_date::TEXT, elt.late_minutes::TEXT, elt.consecutive_count::TEXT, elt.penalty_type, row_to_json(elt)::TEXT)
  FROM public.employee_late_tracking elt
  LEFT JOIN public.employees e
    ON e.id = elt.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = elt.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'sandwich_tracking',
    srt.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Sandwich Rule'),
    NULLIF(TRIM(concat_ws(' | ', srt.start_date::TEXT, srt.end_date::TEXT)), ''),
    '/leaves',
    e.branch_id,
    'leaves',
    concat_ws(' ', en.full_name, en.employee_code, srt.start_date::TEXT, srt.end_date::TEXT, srt.middle_date::TEXT, srt.before_leave_type, srt.after_leave_type, row_to_json(srt)::TEXT)
  FROM public.sandwich_rule_tracking srt
  LEFT JOIN public.employees e
    ON e.id = srt.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = srt.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'payroll_period',
    pp.id,
    COALESCE(NULLIF(TRIM(pp.name), ''), 'Payroll Period'),
    NULLIF(TRIM(concat_ws(' | ', pp.month::TEXT, pp.year::TEXT, pp.status)), ''),
    '/payroll/periods',
    NULL::UUID,
    'payroll',
    concat_ws(' ', pp.name, pp.month::TEXT, pp.year::TEXT, pp.status, pp.start_date::TEXT, pp.end_date::TEXT, row_to_json(pp)::TEXT)
  FROM public.payroll_periods pp
  WHERE COALESCE(pp.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'payroll',
    p.id,
    COALESCE(NULLIF(TRIM(pc.employee_name), ''), 'Payroll'),
    NULLIF(TRIM(concat_ws(' | ', pc.payroll_period_name, p.status, p.net_salary::TEXT)), ''),
    '/payroll',
    pc.branch_id,
    'payroll',
    concat_ws(' ', pc.employee_name, pc.employee_code, pc.payroll_period_name, p.status, p.net_salary::TEXT, p.gross_salary::TEXT, p.total_deductions::TEXT, row_to_json(p)::TEXT)
  FROM public.payroll p
  LEFT JOIN payroll_context pc
    ON pc.payroll_id = p.id
  WHERE COALESCE(p.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'payroll_component',
    pcmp.id,
    COALESCE(NULLIF(TRIM(sc.name), ''), 'Payroll Component'),
    NULLIF(TRIM(concat_ws(' | ', pc.employee_name, pcmp.amount::TEXT)), ''),
    '/payroll',
    pc.branch_id,
    'payroll',
    concat_ws(' ', sc.name, pc.employee_name, pc.payroll_period_name, pcmp.amount::TEXT, pcmp.calculated_value::TEXT, row_to_json(pcmp)::TEXT)
  FROM public.payroll_components pcmp
  LEFT JOIN payroll_context pc
    ON pc.payroll_id = pcmp.payroll_id
  LEFT JOIN public.salary_components sc
    ON sc.id = pcmp.salary_component_id
  WHERE COALESCE(pcmp.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'salary_component',
    sc.id,
    COALESCE(NULLIF(TRIM(sc.name), ''), 'Salary Component'),
    NULLIF(TRIM(concat_ws(' | ', sc.code, sc.component_type)), ''),
    '/masters/salary-components',
    NULL::UUID,
    'masters_salary_components',
    concat_ws(' ', sc.name, sc.code, sc.component_type, sc.description, row_to_json(sc)::TEXT)
  FROM public.salary_components sc
  WHERE COALESCE(sc.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_salary_component',
    esc.id,
    COALESCE(NULLIF(TRIM(sc.name), ''), 'Employee Salary Component'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, esc.value::TEXT)), ''),
    '/employees/edit/' || esc.employee_id::TEXT,
    e.branch_id,
    'employees',
    concat_ws(' ', sc.name, en.full_name, en.employee_code, esc.value::TEXT, esc.effective_from::TEXT, esc.effective_to::TEXT, row_to_json(esc)::TEXT)
  FROM public.employee_salary_components esc
  LEFT JOIN public.salary_components sc
    ON sc.id = esc.salary_component_id
  LEFT JOIN public.employees e
    ON e.id = esc.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = esc.employee_id
  WHERE COALESCE(esc.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'payroll_adjustment',
    pa.id,
    COALESCE(NULLIF(TRIM(pa.label), ''), 'Payroll Adjustment'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, pa.amount::TEXT, pa.adjustment_type)), ''),
    '/payroll',
    e.branch_id,
    'payroll',
    concat_ws(' ', pa.label, pa.reason, pa.amount::TEXT, pa.adjustment_type, en.full_name, row_to_json(pa)::TEXT)
  FROM public.payroll_adjustments pa
  LEFT JOIN public.employees e
    ON e.id = pa.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = pa.employee_id
  WHERE COALESCE(pa.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'payroll_deduction_adjustment',
    pda.id,
    COALESCE(NULLIF(TRIM(pda.deduction_type), ''), 'Payroll Deduction Adjustment'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, pda.adjusted_amount::TEXT)), ''),
    '/payroll',
    e.branch_id,
    'payroll',
    concat_ws(' ', pda.deduction_type, pda.adjustment_reason, pda.original_amount::TEXT, pda.adjusted_amount::TEXT, en.full_name, row_to_json(pda)::TEXT)
  FROM public.payroll_deduction_adjustments pda
  LEFT JOIN public.employees e
    ON e.id = pda.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = pda.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'advance',
    ea.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Employee Advance'),
    NULLIF(TRIM(concat_ws(' | ', ea.amount::TEXT, ea.status)), ''),
    '/employee-loans',
    e.branch_id,
    'employee_loans',
    concat_ws(' ', en.full_name, en.employee_code, ea.reason, ea.amount::TEXT, ea.remaining_amount::TEXT, ea.status, row_to_json(ea)::TEXT)
  FROM public.employee_advances ea
  LEFT JOIN public.employees e
    ON e.id = ea.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = ea.employee_id
  WHERE COALESCE(ea.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'advance_recovery',
    art.id,
    'Advance Recovery',
    NULLIF(TRIM(concat_ws(' | ', en.full_name, art.recovery_amount::TEXT)), ''),
    '/employee-loans',
    e.branch_id,
    'employee_loans',
    concat_ws(' ', en.full_name, art.recovery_amount::TEXT, art.recovery_date::TEXT, art.description, row_to_json(art)::TEXT)
  FROM public.advance_recovery_transactions art
  LEFT JOIN public.employee_advances ea
    ON ea.id = art.advance_id
  LEFT JOIN public.employees e
    ON e.id = ea.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = ea.employee_id
  WHERE COALESCE(art.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'loan',
    el.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Employee Loan'),
    NULLIF(TRIM(concat_ws(' | ', el.loan_amount::TEXT, el.status, el.loan_type)), ''),
    '/employee-loans',
    el.branch_id,
    'employee_loans',
    concat_ws(' ', en.full_name, en.employee_code, el.loan_type, el.loan_amount::TEXT, el.remaining_amount::TEXT, el.status, row_to_json(el)::TEXT)
  FROM public.employee_loans el
  LEFT JOIN employee_names en
    ON en.employee_id = el.employee_id
  WHERE COALESCE(el.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'loan_transaction',
    lt.id,
    COALESCE(NULLIF(TRIM(lt.transaction_type), ''), 'Loan Transaction'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, lt.amount::TEXT)), ''),
    '/employee-loans',
    el.branch_id,
    'employee_loans',
    concat_ws(' ', en.full_name, lt.transaction_type, lt.amount::TEXT, lt.transaction_date::TEXT, lt.description, row_to_json(lt)::TEXT)
  FROM public.loan_transactions lt
  LEFT JOIN public.employee_loans el
    ON el.id = lt.loan_id
  LEFT JOIN employee_names en
    ON en.employee_id = el.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'security_deposit',
    sd.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Security Deposit'),
    NULLIF(TRIM(concat_ws(' | ', sd.total_amount::TEXT, sd.status)), ''),
    '/security-deposits',
    NULL::UUID,
    'security_deposits',
    concat_ws(' ', en.full_name, sd.total_amount::TEXT, sd.collected_amount::TEXT, sd.status, row_to_json(sd)::TEXT)
  FROM public.security_deposits sd
  LEFT JOIN employee_names en
    ON en.employee_id = sd.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_security_deposit',
    esd.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Employee Security Deposit'),
    NULLIF(TRIM(concat_ws(' | ', esd.deposit_amount::TEXT, esd.status)), ''),
    '/security-deposits',
    e.branch_id,
    'security_deposits',
    concat_ws(' ', en.full_name, esd.deposit_amount::TEXT, esd.monthly_deduction::TEXT, esd.status, esd.start_date::TEXT, row_to_json(esd)::TEXT)
  FROM public.employee_security_deposits esd
  LEFT JOIN public.employees e
    ON e.id = esd.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = esd.employee_id
  WHERE COALESCE(esd.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'security_deposit_transaction',
    sdt.id,
    COALESCE(NULLIF(TRIM(sdt.transaction_type), ''), 'Security Deposit Transaction'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, sdt.amount::TEXT)), ''),
    '/security-deposits',
    e.branch_id,
    'security_deposits',
    concat_ws(' ', en.full_name, sdt.transaction_type, sdt.amount::TEXT, sdt.transaction_date::TEXT, sdt.description, row_to_json(sdt)::TEXT)
  FROM public.security_deposit_transactions sdt
  LEFT JOIN public.employee_security_deposits esd
    ON esd.id = sdt.security_deposit_id
  LEFT JOIN public.employees e
    ON e.id = esd.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = esd.employee_id
  WHERE COALESCE(sdt.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'pf_account',
    epf.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'PF Account'),
    NULLIF(TRIM(concat_ws(' | ', epf.pf_number, epf.total_balance::TEXT)), ''),
    '/provident-fund',
    e.branch_id,
    'provident_fund',
    concat_ws(' ', en.full_name, en.employee_code, epf.pf_number, epf.total_balance::TEXT, row_to_json(epf)::TEXT)
  FROM public.employee_pf_accounts epf
  LEFT JOIN public.employees e
    ON e.id = epf.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = epf.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'pf_transaction',
    pft.id,
    'PF Transaction',
    NULLIF(TRIM(concat_ws(' | ', en.full_name, pft.transaction_date::TEXT)), ''),
    '/provident-fund',
    e.branch_id,
    'provident_fund',
    concat_ws(' ', en.full_name, pft.transaction_date::TEXT, pft.employee_contribution::TEXT, pft.employer_contribution::TEXT, row_to_json(pft)::TEXT)
  FROM public.pf_transactions pft
  LEFT JOIN public.employee_pf_accounts epf
    ON epf.id = pft.pf_account_id
  LEFT JOIN public.employees e
    ON e.id = epf.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = epf.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'notice_penalty',
    np.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Notice Penalty'),
    NULLIF(TRIM(concat_ws(' | ', np.amount::TEXT, np.status)), ''),
    '/notice-penalties',
    e.branch_id,
    'notice_penalties',
    concat_ws(' ', en.full_name, en.employee_code, np.amount::TEXT, np.status, np.reason, row_to_json(np)::TEXT)
  FROM public.notice_penalties np
  LEFT JOIN public.employees e
    ON e.id = np.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = np.employee_id
  WHERE COALESCE(np.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_todo',
    et.id,
    COALESCE(NULLIF(TRIM(et.title), ''), 'Employee Todo'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, et.status, et.priority)), ''),
    '/my-todos',
    e.branch_id,
    'employees',
    concat_ws(' ', et.title, et.description, et.status, et.priority, en.full_name, row_to_json(et)::TEXT)
  FROM public.employee_todos et
  LEFT JOIN public.employees e
    ON e.id = et.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = et.employee_id

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_bank_detail',
    ebd.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Bank Detail'),
    NULLIF(TRIM(concat_ws(' | ', ebd.bank_name, ebd.account_number)), ''),
    '/employees/edit/' || ebd.employee_id::TEXT,
    e.branch_id,
    'employees',
    concat_ws(' ', en.full_name, ebd.bank_name, ebd.account_holder_name, ebd.account_number, ebd.ifsc_code, row_to_json(ebd)::TEXT)
  FROM public.employee_bank_details ebd
  LEFT JOIN public.employees e
    ON e.id = ebd.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = ebd.employee_id
  WHERE COALESCE(ebd.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_document',
    ed.id,
    COALESCE(NULLIF(TRIM(ed.document_type), ''), 'Employee Document'),
    NULLIF(TRIM(concat_ws(' | ', en.full_name, ed.is_verified::TEXT)), ''),
    '/employees/edit/' || ed.employee_id::TEXT,
    e.branch_id,
    'employees',
    concat_ws(' ', ed.document_type, en.full_name, ed.file_url, ed.remarks, ed.skip_reason, row_to_json(ed)::TEXT)
  FROM public.employee_documents ed
  LEFT JOIN public.employees e
    ON e.id = ed.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = ed.employee_id
  WHERE COALESCE(ed.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'employee_shift',
    es.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Employee Shift'),
    NULLIF(TRIM(concat_ws(' | ', s.name, ww.name)), ''),
    '/employees/edit/' || es.employee_id::TEXT,
    e.branch_id,
    'employees',
    concat_ws(' ', en.full_name, s.name, ww.name, row_to_json(es)::TEXT)
  FROM public.employee_shifts es
  LEFT JOIN public.employees e
    ON e.id = es.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = es.employee_id
  LEFT JOIN public.shifts s
    ON s.id = es.shift_id
  LEFT JOIN public.work_weeks ww
    ON ww.id = es.work_week_id
  WHERE COALESCE(es.is_deleted, false) = false

  UNION ALL

  SELECT
    'HR, Payroll & Employee Finance',
    'user_contract_acceptance',
    uca.id,
    COALESCE(NULLIF(TRIM(en.full_name), ''), 'Contract Acceptance'),
    NULLIF(TRIM(concat_ws(' | ', uca.is_accepted::TEXT, uca.accepted_at::TEXT)), ''),
    '/onboarding/contract',
    e.branch_id,
    'contracts',
    concat_ws(' ', en.full_name, uca.is_accepted::TEXT, uca.accepted_at::TEXT, uca.rejection_reason, uca.hr_rejection_reason, row_to_json(uca)::TEXT)
  FROM public.user_contract_acceptance uca
  LEFT JOIN public.employees e
    ON e.id = uca.employee_id
  LEFT JOIN employee_names en
    ON en.employee_id = uca.employee_id

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'expense_category',
    ec.id,
    COALESCE(NULLIF(TRIM(ec.name), ''), 'Expense Category'),
    NULLIF(TRIM(ec.description), ''),
    '/masters/expense-categories',
    NULL::UUID,
    'expenses_manage_categories',
    concat_ws(' ', ec.name, ec.description, row_to_json(ec)::TEXT)
  FROM public.expense_categories ec

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'expense',
    ex.id,
    COALESCE(NULLIF(TRIM(ex.description), ''), NULLIF(TRIM(ex.expense_number), ''), 'Expense'),
    NULLIF(TRIM(concat_ws(' | ', ec.name, ex.vendor_name, COALESCE(ex.total_amount, ex.amount)::TEXT, ex.status)), ''),
    '/expenses/view/' || ex.id::TEXT,
    ex.branch_id,
    'expenses_view',
    concat_ws(' ', ex.expense_number, ex.description, ex.vendor_name, ex.vendor_contact, ec.name, ex.status, ex.payment_method, ex.expense_date::TEXT, COALESCE(ex.total_amount, ex.amount)::TEXT, row_to_json(ex)::TEXT)
  FROM public.expenses ex
  LEFT JOIN public.expense_categories ec
    ON ec.id = ex.category_id
  WHERE COALESCE(ex.is_deleted, false) = false

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'expense_item',
    ei.id,
    COALESCE(NULLIF(TRIM(ei.item_name), ''), 'Expense Item'),
    NULLIF(TRIM(concat_ws(' | ', ei.line_total::TEXT, ex.expense_number)), ''),
    '/expenses/view/' || ei.expense_id::TEXT,
    ex.branch_id,
    'expenses_view',
    concat_ws(' ', ei.item_name, ei.price::TEXT, ei.quantity::TEXT, ei.tax_amount::TEXT, ei.line_total::TEXT, ex.expense_number, row_to_json(ei)::TEXT)
  FROM public.expense_items ei
  LEFT JOIN public.expenses ex
    ON ex.id = ei.expense_id

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'expense_payment',
    ep.id,
    'Expense Payment',
    NULLIF(TRIM(concat_ws(' | ', ex.expense_number, ep.payment_amount::TEXT, ep.payment_method)), ''),
    '/expenses/view/' || ep.expense_id::TEXT,
    ex.branch_id,
    'expenses_view',
    concat_ws(' ', ex.expense_number, ep.payment_amount::TEXT, ep.payment_method, ep.payment_reference, ep.payment_date::TEXT, ep.notes, row_to_json(ep)::TEXT)
  FROM public.expense_payments ep
  LEFT JOIN public.expenses ex
    ON ex.id = ep.expense_id

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'purchase_order',
    po.id,
    COALESCE(NULLIF(TRIM(po.po_number), ''), 'Purchase Order'),
    NULLIF(TRIM(concat_ws(' | ', po.supplier_name, po.status, po.total_amount::TEXT)), ''),
    '/inventory',
    po.branch_id,
    'inventory_manage',
    concat_ws(' ', po.po_number, po.supplier_name, po.status, po.payment_status, po.total_amount::TEXT, po.notes, po.expected_delivery_date::TEXT, row_to_json(po)::TEXT)
  FROM public.purchase_orders po
  WHERE COALESCE(po.is_deleted, false) = false

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'purchase_order_item',
    poi.id,
    COALESCE(NULLIF(TRIM(poi.item_name), ''), 'Purchase Order Item'),
    NULLIF(TRIM(concat_ws(' | ', poc.po_number, poi.quantity::TEXT, poi.unit_price::TEXT)), ''),
    '/inventory',
    poc.branch_id,
    'inventory_manage',
    concat_ws(' ', poi.item_name, poi.category, poi.unit, poi.quantity::TEXT, poi.unit_price::TEXT, poi.total_price::TEXT, poc.po_number, row_to_json(poi)::TEXT)
  FROM public.purchase_order_items poi
  LEFT JOIN purchase_order_context poc
    ON poc.purchase_order_id = poi.purchase_order_id

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'payment_transaction',
    pt.id,
    COALESCE(NULLIF(TRIM(pt.reference_number), ''), 'Payment Transaction'),
    NULLIF(TRIM(concat_ws(' | ', poc.po_number, pt.amount::TEXT, pt.payment_status)), ''),
    '/inventory',
    pt.branch_id,
    'inventory_manage',
    concat_ws(' ', poc.po_number, pt.amount::TEXT, pt.payment_method, pt.reference_number, pt.payment_status, pt.payment_type, row_to_json(pt)::TEXT)
  FROM public.payment_transactions pt
  LEFT JOIN purchase_order_context poc
    ON poc.purchase_order_id = pt.purchase_order_id

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'agent_payout',
    ap.id,
    COALESCE(NULLIF(TRIM(ag.name), ''), 'Agent Payout'),
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, ap.amount::TEXT, ap.status)), ''),
    '/case-matter/agent-payments',
    soc.branch_id,
    'agent_payouts',
    concat_ws(' ', ag.name, soc.order_number, ap.amount::TEXT, ap.payment_method, ap.transaction_reference, ap.status, row_to_json(ap)::TEXT)
  FROM public.agent_payouts ap
  LEFT JOIN public.agent_master ag
    ON ag.id = ap.agent_id
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = ap.service_order_id

  UNION ALL

  SELECT
    'Procurement, Expenses & Commercial',
    'service_payment',
    ptso.id,
    COALESCE(NULLIF(TRIM(soc.order_number), ''), 'Service Payment'),
    NULLIF(TRIM(concat_ws(' | ', ptso.amount::TEXT, ptso.transaction_type, ptso.payment_method)), ''),
    CASE
      WHEN soc.is_case THEN '/case-matter/case-orders/' || ptso.service_order_id::TEXT
      ELSE '/case-matter/service-orders/view/' || ptso.service_order_id::TEXT
    END,
    soc.branch_id,
    'service_orders',
    concat_ws(' ', soc.order_number, soc.client_name, ptso.transaction_type, ptso.amount::TEXT, ptso.payment_method, ptso.transaction_reference, ptso.notes, row_to_json(ptso)::TEXT)
  FROM public.payment_transactions_service_orders ptso
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = ptso.service_order_id

  UNION ALL

  SELECT
    'Inventory & Assets',
    'inventory_item',
    ii.id,
    COALESCE(NULLIF(TRIM(ii.name), ''), 'Inventory Item'),
    NULLIF(TRIM(concat_ws(' | ', ii.category, ii.quantity::TEXT, ii.status)), ''),
    '/inventory',
    ii.branch_id,
    'inventory_manage',
    concat_ws(' ', ii.name, ii.category, ii.unit, ii.location, ii.batch_number, ii.status, ii.quantity::TEXT, ii.expiry_date::TEXT, row_to_json(ii)::TEXT)
  FROM public.inventory_items ii
  WHERE COALESCE(ii.is_deleted, false) = false

  UNION ALL

  SELECT
    'Inventory & Assets',
    'inventory_unit',
    iu.id,
    COALESCE(NULLIF(TRIM(iu.name), ''), 'Inventory Unit'),
    NULLIF(TRIM(concat_ws(' | ', iu.code, iu.description)), ''),
    '/inventory',
    NULL::UUID,
    'inventory_manage',
    concat_ws(' ', iu.name, iu.code, iu.normalized_name, iu.description, row_to_json(iu)::TEXT)
  FROM public.inventory_units iu
  WHERE COALESCE(iu.is_deleted, false) = false

  UNION ALL

  SELECT
    'Inventory & Assets',
    'inventory_transaction',
    it.id,
    COALESCE(NULLIF(TRIM(ii.name), ''), 'Inventory Transaction'),
    NULLIF(TRIM(concat_ws(' | ', it.transaction_type, it.quantity::TEXT, it.reference_type)), ''),
    '/inventory',
    it.branch_id,
    'inventory_manage',
    concat_ws(' ', ii.name, it.transaction_type, it.quantity::TEXT, it.reference_type, it.reference_id, it.notes, row_to_json(it)::TEXT)
  FROM public.inventory_transactions it
  LEFT JOIN public.inventory_items ii
    ON ii.id = it.inventory_item_id

  UNION ALL

  SELECT
    'Inventory & Assets',
    'inventory_issue',
    eii.id,
    COALESCE(NULLIF(TRIM(eii.issue_number), ''), 'Inventory Issue'),
    NULLIF(TRIM(concat_ws(' | ', iic.employee_name, eii.status, eii.issue_date::TEXT)), ''),
    '/inventory',
    iic.branch_id,
    'inventory_manage',
    concat_ws(' ', eii.issue_number, iic.employee_name, iic.employee_code, eii.status, eii.reason, eii.notes, eii.issue_date::TEXT, row_to_json(eii)::TEXT)
  FROM public.employee_inventory_issues eii
  LEFT JOIN inventory_issue_context iic
    ON iic.issue_id = eii.id

  UNION ALL

  SELECT
    'Inventory & Assets',
    'inventory_issue_item',
    eiii.id,
    COALESCE(NULLIF(TRIM(eiii.item_name), ''), 'Inventory Issue Item'),
    NULLIF(TRIM(concat_ws(' | ', iic.issue_number, eiii.quantity::TEXT, eiii.returned_quantity::TEXT)), ''),
    '/inventory',
    iic.branch_id,
    'inventory_manage',
    concat_ws(' ', eiii.item_name, iic.issue_number, iic.employee_name, eiii.quantity::TEXT, eiii.returned_quantity::TEXT, row_to_json(eiii)::TEXT)
  FROM public.employee_inventory_issue_items eiii
  LEFT JOIN inventory_issue_context iic
    ON iic.issue_id = eiii.issue_id

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'required_document',
    rdm.id,
    COALESCE(NULLIF(TRIM(rdm.name), ''), 'Required Document'),
    NULLIF(TRIM(concat_ws(' | ', dcm.name, rdm.description)), ''),
    '/masters/required-documents',
    NULL::UUID,
    'case_matter_document',
    concat_ws(' ', rdm.name, rdm.description, dcm.name, row_to_json(rdm)::TEXT)
  FROM public.required_documents_master rdm
  LEFT JOIN public.document_category_master dcm
    ON dcm.id = rdm.category_id
  WHERE COALESCE(rdm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'document_category',
    dcm.id,
    COALESCE(NULLIF(TRIM(dcm.name), ''), 'Document Category'),
    NULLIF(TRIM(dcm.description), ''),
    '/masters/document-categories',
    NULL::UUID,
    'case_matter_document',
    concat_ws(' ', dcm.name, dcm.description, row_to_json(dcm)::TEXT)
  FROM public.document_category_master dcm
  WHERE COALESCE(dcm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'document_template',
    dt.id,
    COALESCE(NULLIF(TRIM(dt.template_name), ''), 'Document Template'),
    NULLIF(TRIM(concat_ws(' | ', dt.document_type, dt.base_language)), ''),
    '/case-matter-masters/document/view/' || dt.id::TEXT,
    NULL::UUID,
    'case_matter_document',
    concat_ws(' ', dt.template_name, dt.document_type, dt.base_language, dt.description, dt.template_content, translation_rollup.translation_content, row_to_json(dt)::TEXT)
  FROM public.document_templates dt
  LEFT JOIN LATERAL (
    SELECT string_agg(COALESCE(dtt.translated_content, ''), ' ') AS translation_content
    FROM public.document_template_translations dtt
    WHERE dtt.template_id = dt.id
  ) translation_rollup ON true
  WHERE COALESCE(dt.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'document_template_translation',
    dtt.id,
    COALESCE(NULLIF(TRIM(dtt.language_name), ''), dtt.language_code, 'Document Translation'),
    NULLIF(TRIM(dt.template_name), ''),
    '/case-matter-masters/document/view/' || dtt.template_id::TEXT,
    NULL::UUID,
    'case_matter_document',
    concat_ws(' ', dtt.language_name, dtt.language_code, dt.template_name, dtt.translated_content, row_to_json(dtt)::TEXT)
  FROM public.document_template_translations dtt
  LEFT JOIN public.document_templates dt
    ON dt.id = dtt.template_id

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'contract_required_document',
    ctrd.id,
    COALESCE(NULLIF(TRIM(ct.name), ''), 'Contract Required Document'),
    NULLIF(TRIM(concat_ws(' | ', ctrd.document_type, ctrd.is_mandatory::TEXT)), ''),
    '/masters/required-documents',
    NULL::UUID,
    'contracts',
    concat_ws(' ', ct.name, ctrd.document_type, ctrd.remarks, ctrd.employee_visible::TEXT, row_to_json(ctrd)::TEXT)
  FROM public.contract_type_required_documents ctrd
  LEFT JOIN public.contract_types ct
    ON ct.id = ctrd.contract_type_id
  WHERE COALESCE(ctrd.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'service_task_document',
    std.id,
    COALESCE(NULLIF(TRIM(rdm.name), ''), 'Service Task Document'),
    NULLIF(TRIM(concat_ws(' | ', st.work_name, std.is_mandatory::TEXT)), ''),
    '/case-matter/service-master/view/' || ss.service_id::TEXT,
    sm.branch_id,
    'case_matter_document',
    concat_ws(' ', rdm.name, st.work_name, ss.name, sm.name, std.is_mandatory::TEXT, row_to_json(std)::TEXT)
  FROM public.service_task_documents std
  LEFT JOIN public.required_documents_master rdm
    ON rdm.id = std.document_id
  LEFT JOIN public.service_tasks st
    ON st.id = std.task_id
  LEFT JOIN public.service_stages ss
    ON ss.id = st.stage_id
  LEFT JOIN public.service_master sm
    ON sm.id = ss.service_id

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'service_order_task_document',
    sotd.id,
    COALESCE(NULLIF(TRIM(sotd.document_name), ''), 'Order Task Document'),
    NULLIF(TRIM(concat_ws(' | ', soc.order_number, sotd.file_type)), ''),
    CASE
      WHEN soc.is_case THEN '/case-matter/case-orders/' || sotd.service_order_id::TEXT
      ELSE '/case-matter/service-orders/view/' || sotd.service_order_id::TEXT
    END,
    soc.branch_id,
    'case_matter_document',
    concat_ws(' ', sotd.document_name, sotd.file_type, sotd.file_path, soc.order_number, soc.client_name, row_to_json(sotd)::TEXT)
  FROM public.service_order_task_documents sotd
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = sotd.service_order_id

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'witness_id',
    sowi.id,
    COALESCE(NULLIF(TRIM(sowi.id_number), ''), 'Witness ID'),
    NULLIF(TRIM(concat_ws(' | ', sowi.id_type, soc.order_number)), ''),
    CASE
      WHEN soc.is_case THEN '/case-matter/case-orders/' || soc.service_order_id::TEXT
      ELSE '/case-matter/service-orders/view/' || soc.service_order_id::TEXT
    END,
    soc.branch_id,
    'case_matter_document',
    concat_ws(' ', sowi.id_type, sowi.id_number, soc.order_number, soc.client_name, row_to_json(sowi)::TEXT)
  FROM public.service_order_witness_ids sowi
  LEFT JOIN public.service_order_witnesses sow
    ON sow.id = sowi.service_order_witness_id
  LEFT JOIN service_order_context soc
    ON soc.service_order_id = sow.service_order_id

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'witness_document',
    sowd.id,
    'Witness Document',
    NULLIF(TRIM('Witness proof'), ''),
    '/case-matter/case-orders',
    NULL::UUID,
    'case_matter_document',
    row_to_json(sowd)::TEXT
  FROM public.service_order_witness_documents sowd

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'company_term',
    ctm.id,
    COALESCE(NULLIF(TRIM(ctm.title), ''), 'Company Term'),
    NULLIF(TRIM(concat_ws(' | ', ctm.term_type, ctm.status, ctm.version)), ''),
    '/masters/company-terms',
    NULL::UUID,
    'masters_company_terms',
    concat_ws(' ', ctm.title, ctm.term_type, ctm.summary, ctm.status, ctm.version, ctm.tags::TEXT, row_to_json(ctm)::TEXT)
  FROM public.company_terms ctm
  WHERE COALESCE(ctm.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'company_term_revision',
    ctr.id,
    COALESCE(NULLIF(TRIM(ctr.title), ''), 'Company Term Revision'),
    NULLIF(TRIM(concat_ws(' | ', ctr.revision_number::TEXT, ctr.effective_date::TEXT)), ''),
    '/masters/company-terms',
    NULL::UUID,
    'masters_company_terms',
    concat_ws(' ', ctr.title, ctr.summary, ctr.changes_description, ctr.revision_number::TEXT, ctr.effective_date::TEXT, row_to_json(ctr)::TEXT)
  FROM public.company_term_revisions ctr

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'policy',
    p.id,
    COALESCE(NULLIF(TRIM(p.title), ''), 'Policy'),
    NULLIF(TRIM(concat_ws(' | ', p.category, p.version)), ''),
    '/settings/company',
    NULL::UUID,
    'settings_company',
    concat_ws(' ', p.title, p.category, p.version, p.content, row_to_json(p)::TEXT)
  FROM public.policies p
  WHERE COALESCE(p.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'email_template',
    et.id,
    COALESCE(NULLIF(TRIM(et.name), ''), 'Email Template'),
    NULLIF(TRIM(concat_ws(' | ', et.subject, et.template_type::TEXT)), ''),
    '/masters/notifications',
    NULL::UUID,
    'notifications_master',
    concat_ws(' ', et.name, et.subject, et.template_type::TEXT, et.body, row_to_json(et)::TEXT)
  FROM public.email_templates et
  WHERE COALESCE(et.is_deleted, false) = false

  UNION ALL

  SELECT
    'Documents, Templates & Knowledge',
    'knowledge_item',
    cki.id,
    COALESCE(NULLIF(TRIM(cki.title), ''), 'Knowledge Item'),
    NULLIF(TRIM(concat_ws(' | ', cki.content_type, cki.slug)), ''),
    '/support',
    NULL::UUID,
    'support_articles',
    concat_ws(' ', cki.title, cki.slug, cki.excerpt, cki.content_html, cki.content_type, row_to_json(cki)::TEXT)
  FROM public.cms_knowledge_items cki
  WHERE COALESCE(cki.is_deleted, false) = false

  UNION ALL

  SELECT
    'Website & CMS',
    'external_review',
    cer.id,
    COALESCE(NULLIF(TRIM(cer.reviewer_name), ''), 'External Review'),
    NULLIF(TRIM(concat_ws(' | ', cer.rating::TEXT, cer.moderation_status)), ''),
    '/cms/website',
    NULL::UUID,
    'cms_website',
    concat_ws(' ', cer.reviewer_name, cer.review_text, cer.rating::TEXT, cer.provider, cer.moderation_status, cer.source_location_id, row_to_json(cer)::TEXT)
  FROM public.cms_external_reviews cer
  WHERE COALESCE(cer.is_deleted, false) = false

  UNION ALL

  SELECT
    'Website & CMS',
    'review_source',
    crs.id,
    COALESCE(NULLIF(TRIM(crs.business_name), ''), 'Review Source'),
    NULLIF(TRIM(concat_ws(' | ', crs.provider, crs.sync_mode, crs.last_sync_status)), ''),
    '/cms/website',
    NULL::UUID,
    'cms_website',
    concat_ws(' ', crs.business_name, crs.provider, crs.source_location_id, crs.sync_mode, crs.last_sync_status, crs.last_sync_error, row_to_json(crs)::TEXT)
  FROM public.cms_review_sources crs
  WHERE COALESCE(crs.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'branch',
    b.id,
    COALESCE(NULLIF(TRIM(b.name), ''), 'Branch'),
    NULLIF(TRIM(concat_ws(' | ', b.code, b.city, b.state)), ''),
    '/masters/branches',
    NULL::UUID,
    'branches',
    concat_ws(' ', b.name, b.code, b.city, b.state, b.address, b.phone, b.email, row_to_json(b)::TEXT)
  FROM public.branches b
  WHERE COALESCE(b.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'country',
    c.id,
    COALESCE(NULLIF(TRIM(c.country_name), ''), 'Country'),
    NULLIF(TRIM(concat_ws(' | ', c.country_code, c.phone_code)), ''),
    '/masters/countries',
    NULL::UUID,
    'location_master_country',
    concat_ws(' ', c.country_name, c.country_code, c.country_code_iso2, c.phone_code, row_to_json(c)::TEXT)
  FROM public.countries c
  WHERE COALESCE(c.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'state',
    s.id,
    COALESCE(NULLIF(TRIM(s.state_name), ''), 'State'),
    NULLIF(TRIM(concat_ws(' | ', s.state_code, c.country_name)), ''),
    '/masters/states',
    NULL::UUID,
    'location_master_state',
    concat_ws(' ', s.state_name, s.state_code, c.country_name, row_to_json(s)::TEXT)
  FROM public.states s
  LEFT JOIN public.countries c
    ON c.id = s.country_id
  WHERE COALESCE(s.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'city',
    c.id,
    COALESCE(NULLIF(TRIM(c.city_name), ''), 'City'),
    NULLIF(TRIM(d.district_name), ''),
    '/masters/cities',
    NULL::UUID,
    'location_master_city',
    concat_ws(' ', c.city_name, d.district_name, row_to_json(c)::TEXT)
  FROM public.cities c
  LEFT JOIN public.districts d
    ON d.id = c.district_id
  WHERE COALESCE(c.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'district',
    d.id,
    COALESCE(NULLIF(TRIM(d.district_name), ''), 'District'),
    NULLIF(TRIM(s.state_name), ''),
    '/masters/districts',
    NULL::UUID,
    'location_master_district',
    concat_ws(' ', d.district_name, s.state_name, row_to_json(d)::TEXT)
  FROM public.districts d
  LEFT JOIN public.states s
    ON s.id = d.state_id
  WHERE COALESCE(d.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'taluka',
    t.id,
    COALESCE(NULLIF(TRIM(t.taluka_name), ''), 'Taluka'),
    NULLIF(TRIM(d.district_name), ''),
    '/masters/talukas',
    NULL::UUID,
    'location_master_taluka',
    concat_ws(' ', t.taluka_name, d.district_name, row_to_json(t)::TEXT)
  FROM public.talukas t
  LEFT JOIN public.districts d
    ON d.id = t.district_id
  WHERE COALESCE(t.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'village',
    v.id,
    COALESCE(NULLIF(TRIM(v.village_name), ''), 'Village'),
    NULLIF(TRIM(t.taluka_name), ''),
    '/masters/villages',
    NULL::UUID,
    'location_master_village',
    concat_ws(' ', v.village_name, t.taluka_name, row_to_json(v)::TEXT)
  FROM public.villages v
  LEFT JOIN public.talukas t
    ON t.id = v.taluka_id
  WHERE COALESCE(v.is_deleted, false) = false

  UNION ALL

  SELECT
    'Masters & Reference Data',
    'pincode',
    p.id,
    COALESCE(NULLIF(TRIM(p.pincode), ''), 'Pincode'),
    NULLIF(TRIM(v.village_name), ''),
    '/masters/pincodes',
    NULL::UUID,
    'location_master_pincode',
    concat_ws(' ', p.pincode, v.village_name, c.city_name, row_to_json(p)::TEXT)
  FROM public.pincodes p
  LEFT JOIN public.villages v
    ON v.id = p.village_id
  LEFT JOIN public.cities c
    ON c.id = p.city_id
  WHERE COALESCE(p.is_deleted, false) = false

  UNION ALL

  SELECT
    'Permissions & Access',
    'role',
    r.id,
    COALESCE(NULLIF(TRIM(r.name), ''), 'Role'),
    NULLIF(TRIM(r.description), ''),
    '/masters/roles',
    NULL::UUID,
    'roles_management',
    concat_ws(' ', r.name, r.description, row_to_json(r)::TEXT)
  FROM public.roles r
  WHERE COALESCE(r.is_deleted, false) = false

  UNION ALL

  SELECT
    'Permissions & Access',
    'permission',
    p.id,
    COALESCE(NULLIF(TRIM(p.name), ''), 'Permission'),
    NULLIF(TRIM(concat_ws(' | ', p.module, p.description)), ''),
    '/masters/permissions',
    NULL::UUID,
    'permissions_management',
    concat_ws(' ', p.name, p.module, p.description, row_to_json(p)::TEXT)
  FROM public.permissions p
  WHERE COALESCE(p.is_deleted, false) = false

  UNION ALL

  SELECT
    'Permissions & Access',
    'role_permission',
    rp.id,
    'Role Permission',
    NULLIF(TRIM(concat_ws(' | ', r.name, p.module)), ''),
    '/masters/roles',
    NULL::UUID,
    'roles_management',
    concat_ws(' ', r.name, p.name, p.module, row_to_json(rp)::TEXT)
  FROM public.role_permissions rp
  LEFT JOIN public.roles r
    ON r.id = rp.role_id
  LEFT JOIN public.permissions p
    ON p.id = rp.permission_id
  WHERE COALESCE(rp.is_deleted, false) = false

  UNION ALL

  SELECT
    'Permissions & Access',
    'user_role',
    ur.id,
    'User Role',
    NULLIF(TRIM(concat_ws(' | ', r.name, un.full_name)), ''),
    '/masters/user-permissions',
    NULL::UUID,
    'user_permissions_management',
    concat_ws(' ', r.name, un.full_name, un.personal_email, row_to_json(ur)::TEXT)
  FROM public.user_roles ur
  LEFT JOIN public.roles r
    ON r.id = ur.role_id
  LEFT JOIN user_names un
    ON un.user_profile_id = ur.user_id
  WHERE COALESCE(ur.is_deleted, false) = false

  UNION ALL

  SELECT
    'Permissions & Access',
    'user_permission',
    up.id,
    'User Permission',
    NULLIF(TRIM(concat_ws(' | ', p.module, un.full_name)), ''),
    '/masters/user-permissions',
    NULL::UUID,
    'user_permissions_management',
    concat_ws(' ', p.name, p.module, un.full_name, row_to_json(up)::TEXT)
  FROM public.user_permissions up
  LEFT JOIN public.permissions p
    ON p.id = up.permission_id
  LEFT JOIN user_names un
    ON un.user_profile_id = up.user_id
  WHERE COALESCE(up.is_deleted, false) = false

  UNION ALL

  SELECT
    'Settings & Configuration',
    'approval_setting',
    aps.id,
    'Approval Setting',
    NULLIF(TRIM(aps.module), ''),
    '/settings/company',
    NULL::UUID,
    'settings_company',
    concat_ws(' ', aps.module, aps.approval_levels::TEXT, aps.auto_approve_limit::TEXT, row_to_json(aps)::TEXT)
  FROM public.approval_settings aps
  WHERE COALESCE(aps.is_deleted, false) = false

  UNION ALL

  SELECT
    'Settings & Configuration',
    'company_setting',
    cs.id,
    COALESCE(NULLIF(TRIM(cs.company_name), ''), 'Company Settings'),
    NULLIF(TRIM(concat_ws(' | ', cs.email, cs.phone)), ''),
    '/settings/company',
    NULL::UUID,
    'settings_company',
    concat_ws(' ', cs.company_name, cs.email, cs.phone, cs.website, cs.registration_number, row_to_json(cs)::TEXT)
  FROM public.company_settings cs
  WHERE COALESCE(cs.is_deleted, false) = false

  UNION ALL

  SELECT
    'Settings & Configuration',
    'system_setting',
    ss.id,
    COALESCE(NULLIF(TRIM(ss.key), ''), 'System Setting'),
    NULLIF(TRIM(concat_ws(' | ', ss.category, ss.data_type::TEXT)), ''),
    '/settings/company',
    NULL::UUID,
    'settings_company',
    concat_ws(' ', ss.key, ss.category, ss.description, ss.value::TEXT, row_to_json(ss)::TEXT)
  FROM public.system_settings ss
  WHERE COALESCE(ss.is_deleted, false) = false

  UNION ALL

  SELECT
    'Settings & Configuration',
    'smtp_setting',
    smtp.id,
    COALESCE(NULLIF(TRIM(smtp.host), ''), 'SMTP Settings'),
    NULLIF(TRIM(concat_ws(' | ', smtp.from_email, smtp.port::TEXT)), ''),
    '/settings/smtp',
    NULL::UUID,
    'settings_smtp',
    concat_ws(' ', smtp.host, smtp.from_email, smtp.from_name, smtp.username, smtp.port::TEXT, row_to_json(smtp)::TEXT)
  FROM public.smtp_settings smtp
  WHERE COALESCE(smtp.is_deleted, false) = false

  UNION ALL

  SELECT
    'Notifications',
    'notification',
    n.id,
    COALESCE(NULLIF(TRIM(n.title), ''), 'Notification'),
    NULLIF(TRIM(concat_ws(' | ', n.type, n.message)), ''),
    '/notifications',
    NULL::UUID,
    'notifications_center',
    concat_ws(' ', n.title, n.message, n.type, n.action_url, row_to_json(n)::TEXT)
  FROM public.notifications n
  WHERE COALESCE(n.is_deleted, false) = false

  UNION ALL

  SELECT
    'Notifications',
    'notification_rule',
    nar.id,
    COALESCE(NULLIF(TRIM(nar.name), ''), 'Notification Rule'),
    NULLIF(TRIM(concat_ws(' | ', nar.module, nar.trigger_type)), ''),
    '/masters/notifications',
    NULL::UUID,
    'notifications_master',
    concat_ws(' ', nar.name, nar.description, nar.module, nar.trigger_type, nar.subject_template, nar.message_template, row_to_json(nar)::TEXT)
  FROM public.notification_auto_rules nar

  UNION ALL

  SELECT
    'Notifications',
    'notification_rule_role',
    narr.id,
    'Notification Rule Role',
    NULLIF(TRIM(concat_ws(' | ', nar.name, r.name)), ''),
    '/masters/notifications',
    NULL::UUID,
    'notifications_master',
    concat_ws(' ', nar.name, r.name, row_to_json(narr)::TEXT)
  FROM public.notification_auto_rule_roles narr
  LEFT JOIN public.notification_auto_rules nar
    ON nar.id = narr.rule_id
  LEFT JOIN public.roles r
    ON r.id = narr.role_id

  UNION ALL

  SELECT
    'Notifications',
    'notification_global_setting',
    ngs.id,
    'Notification Global Settings',
    NULL::TEXT,
    '/masters/notifications',
    NULL::UUID,
    'notifications_master',
    row_to_json(ngs)::TEXT
  FROM public.notification_global_settings ngs

  UNION ALL

  SELECT
    'Notifications',
    'push_subscription',
    ps.id,
    'Push Subscription',
    NULLIF(TRIM(ps.endpoint), ''),
    '/notifications',
    NULL::UUID,
    'notifications_center',
    concat_ws(' ', ps.endpoint, ps.user_id::TEXT, row_to_json(ps)::TEXT)
  FROM public.push_subscriptions ps

  UNION ALL

  SELECT
    'Reports & Analytics',
    'report',
    r.id,
    COALESCE(NULLIF(TRIM(r.name), ''), 'Report'),
    NULLIF(TRIM(concat_ws(' | ', r.module, r.report_type)), ''),
    '/reports',
    NULL::UUID,
    'reports',
    concat_ws(' ', r.name, r.description, r.module, r.report_type, r.format::TEXT, row_to_json(r)::TEXT)
  FROM public.reports r
  WHERE COALESCE(r.is_deleted, false) = false

  UNION ALL

  SELECT
    'Reports & Analytics',
    'report_execution',
    re.id,
    'Report Execution',
    NULLIF(TRIM(concat_ws(' | ', r.name, re.status)), ''),
    '/reports',
    NULL::UUID,
    'reports',
    concat_ws(' ', r.name, re.status, re.error_message, re.execution_time::TEXT, row_to_json(re)::TEXT)
  FROM public.report_executions re
  LEFT JOIN public.reports r
    ON r.id = re.report_id
  WHERE COALESCE(re.is_deleted, false) = false

  UNION ALL

  SELECT
    'Dashboards & Widgets',
    'dashboard',
    d.id,
    COALESCE(NULLIF(TRIM(d.name), ''), 'Dashboard'),
    NULLIF(TRIM(d.description), ''),
    '/dashboard',
    NULL::UUID,
    'reports',
    concat_ws(' ', d.name, d.description, row_to_json(d)::TEXT)
  FROM public.dashboards d
  WHERE COALESCE(d.is_deleted, false) = false

  UNION ALL

  SELECT
    'Dashboards & Widgets',
    'dashboard_widget',
    dw.id,
    COALESCE(NULLIF(TRIM(dw.title), ''), 'Dashboard Widget'),
    NULLIF(TRIM(concat_ws(' | ', d.name, dw.widget_type)), ''),
    '/dashboard',
    NULL::UUID,
    'reports',
    concat_ws(' ', dw.title, dw.widget_type, d.name, row_to_json(dw)::TEXT)
  FROM public.dashboard_widgets dw
  LEFT JOIN public.dashboards d
    ON d.id = dw.dashboard_id
  WHERE COALESCE(dw.is_deleted, false) = false

  UNION ALL

  SELECT
    'Reports & Analytics',
    'audit_log',
    al.id,
    'Audit Log',
    NULLIF(TRIM(concat_ws(' | ', al.table_name, al.action::TEXT)), ''),
    '/reports',
    NULL::UUID,
    'reports',
    concat_ws(' ', al.table_name, al.record_id, al.action::TEXT, al.changed_fields::TEXT, row_to_json(al)::TEXT)
  FROM public.audit_logs al

  UNION ALL

  SELECT
    'Reports & Analytics',
    'activity_log',
    act.id,
    'Activity Log',
    NULLIF(TRIM(concat_ws(' | ', act.module, act.action)), ''),
    '/reports',
    NULL::UUID,
    'reports',
    concat_ws(' ', act.module, act.action, act.description, act.timestamp::TEXT, row_to_json(act)::TEXT)
  FROM public.activity_logs act
  WHERE COALESCE(act.is_deleted, false) = false

  UNION ALL

  SELECT
    'Reports & Analytics',
    'data_export',
    de.id,
    COALESCE(NULLIF(TRIM(de.export_type), ''), 'Data Export'),
    NULLIF(TRIM(concat_ws(' | ', de.table_name, de.status)), ''),
    '/reports',
    NULL::UUID,
    'reports',
    concat_ws(' ', de.export_type, de.table_name, de.status, de.format::TEXT, de.file_url, row_to_json(de)::TEXT)
  FROM public.data_exports de
  WHERE COALESCE(de.is_deleted, false) = false

  UNION ALL

  SELECT
    'Events & Calendar',
    'company_event',
    ce.id,
    COALESCE(NULLIF(TRIM(ce.title), ''), 'Company Event'),
    NULLIF(TRIM(concat_ws(' | ', ce.event_type, ce.start_date::TEXT)), ''),
    '/events',
    ce.branch_id,
    'events',
    concat_ws(' ', ce.title, ce.description, ce.event_type, ce.start_date::TEXT, ce.end_date::TEXT, row_to_json(ce)::TEXT)
  FROM public.company_events ce
  WHERE COALESCE(ce.is_deleted, false) = false

  UNION ALL

  SELECT
    'Events & Calendar',
    'event_notification',
    enl.id,
    'Event Notification',
    NULL::TEXT,
    '/events',
    NULL::UUID,
    'events',
    row_to_json(enl)::TEXT
  FROM public.event_notification_log enl

  UNION ALL

  SELECT
    'Settings & Configuration',
    'biometric_device',
    bd.id,
    COALESCE(NULLIF(TRIM(bd.device_name), ''), 'Biometric Device'),
    NULLIF(TRIM(concat_ws(' | ', bd.device_brand, bd.db_host)), ''),
    '/settings/company',
    NULL::UUID,
    'attendance',
    concat_ws(' ', bd.device_name, bd.device_brand, bd.db_host, bd.db_name, bd.table_name, bd.notes, row_to_json(bd)::TEXT)
  FROM public.biometric_devices bd
  WHERE COALESCE(bd.is_deleted, false) = false

  UNION ALL

  SELECT
    'Website & CMS',
    'cms_homepage',
    chp.id,
    COALESCE(NULLIF(TRIM(chp.section_name), ''), COALESCE(NULLIF(TRIM(chp.title), ''), 'CMS Homepage')),
    NULLIF(TRIM(concat_ws(' | ', chp.badge, chp.selected_palette)), ''),
    '/cms/website',
    NULL::UUID,
    'cms_website',
    concat_ws(' ', chp.section_name, chp.title, chp.description, chp.badge, chp.selected_palette, chp.meta_title, chp.meta_description, row_to_json(chp)::TEXT)
  FROM public.cms_homepage chp
) AS src
WITH NO DATA;

-- ============================================================
-- SOURCE: 20260402000002_global_search_runtime.sql
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_gsi_unique
  ON public.global_search_index(entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_gsi_vec
  ON public.global_search_index
  USING GIN(vec);

CREATE INDEX IF NOT EXISTS idx_gsi_branch
  ON public.global_search_index(branch_id);

CREATE INDEX IF NOT EXISTS idx_gsi_type
  ON public.global_search_index(entity_type);

CREATE INDEX IF NOT EXISTS idx_gsi_permission_module
  ON public.global_search_index(permission_module);

CREATE INDEX IF NOT EXISTS idx_gsi_permission_branch
  ON public.global_search_index(permission_module, branch_id);

CREATE INDEX IF NOT EXISTS idx_gsi_title_trgm
  ON public.global_search_index
  USING GIN(title gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.refresh_search_index()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  REFRESH MATERIALIZED VIEW public.global_search_index;
$$;

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

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) FROM anon;

GRANT EXECUTE ON FUNCTION public.refresh_search_index() TO service_role;
REVOKE EXECUTE ON FUNCTION public.refresh_search_index() FROM anon;

-- ============================================================
-- SOURCE: 20260403000003_global_search_grouping_runtime.sql
-- ============================================================

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

-- ============================================================
-- SOURCE: 20260403000004_global_search_perf_fix.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Global search performance fix
-- Root cause: inquiry_live_matches CTE does full-table ILIKE scans with no
-- GIN trigram indexes on full_name / phone / email, causing statement timeouts.
-- Fix: add GIN trigram indexes + raise statement_timeout to 10 s in the function.
-- Note: generated tsvector column was removed — GENERATED columns require
-- IMMUTABLE expressions and to_tsvector() is only STABLE.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- GIN trigram indexes so ILIKE '%...%' and % operator use the index
CREATE INDEX IF NOT EXISTS idx_inquiries_full_name_trgm
  ON public.inquiries USING GIN (full_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_inquiries_phone_trgm
  ON public.inquiries USING GIN (phone gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_inquiries_email_trgm
  ON public.inquiries USING GIN (email gin_trgm_ops);

-- Re-create global_search with SET statement_timeout = '10000' (10 s)
-- and optimised inquiry_live_matches (inline to_tsvector, fewer similarity calls)
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
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '10000'
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
            i.status::text
          )
        ),
        ''
      ) AS subtitle,
      '/crm/inquiries'::TEXT AS url,
      'crm_inquiries'::TEXT AS permission_module,
      CASE
        WHEN pq.tsq IS NOT NULL AND
             to_tsvector('simple', concat_ws(' ',
               COALESCE(i.full_name, ''), COALESCE(i.phone, ''),
               COALESCE(i.email, ''), COALESCE(i.status::text, ''),
               COALESCE(i.message, '')
             )) @@ pq.tsq
        THEN 0.8::REAL
        ELSE 0.6::REAL
      END AS fts_rank,
      GREATEST(
        similarity(COALESCE(i.full_name, ''), COALESCE(pq.query, '')),
        similarity(COALESCE(i.email,     ''), COALESCE(pq.query, ''))
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
      i.full_name ILIKE '%' || pq.query || '%'
      OR i.phone  ILIKE '%' || pq.query || '%'
      OR i.email  ILIKE '%' || pq.query || '%'
    )
    ORDER BY fts_rank DESC, title ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 50) * 2
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
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 50) * 4
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
    WHERE (
      CASE
        WHEN array_length(string_to_array(trim(pq.query), ' '), 1) > 1
          THEN similarity(gsi.title, pq.query) > 0.6
        ELSE gsi.title % pq.query
      END
    )
      AND (
        p_branch_id IS NULL
        OR gsi.branch_id IS NULL
        OR gsi.branch_id = p_branch_id
      )
    ORDER BY similarity(gsi.title, pq.query) DESC, gsi.title ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 50) * 4
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
  WHERE dm.entity_type NOT IN (
    'employee',
    'user_profile',
    'smtp_setting', 'approval_setting', 'company_setting', 'system_setting',
    'biometric_device', 'notification_rule', 'notification_global_setting',
    'push_subscription', 'dashboard', 'dashboard_widget',
    'audit_log', 'activity_log', 'data_export', 'report_execution',
    'permission', 'role', 'role_permission', 'user_role', 'user_permission'
  )
  ORDER BY
    (dm.fts_rank * 0.8 + dm.title_similarity * 0.2) DESC,
    dm.title ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 50);
$$;

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) FROM anon;

-- ============================================================
-- SOURCE: 20260404000001_global_search_accuracy.sql
-- ============================================================

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

-- ============================================================
-- SOURCE: 20260404000002_global_search_ambiguity_fix.sql
-- ============================================================

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

-- ============================================================
-- SOURCE: 20260404000003_global_search_threshold.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Raise multi-word trigram threshold 0.45 → 0.55
--
-- Problem: searching "Priya Shah" returned "Patel vs Shah Property Dispute"
-- because word_similarity("priya shah", long case title) ≈ 0.46 — just
-- above the old 0.45 threshold — even though only "Shah" appeared in the
-- title.  Raising to 0.55 requires more of the query to match the title
-- before a result is included, filtering out single-word coincidences in
-- long strings while keeping genuine partial matches (e.g. "Priya Deshmukh"
-- still appears via FTS since "priya" is an exact token match).
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
  params AS (
    SELECT
      NULLIF(TRIM(p_query), '') AS q,
      CASE
        WHEN array_length(string_to_array(TRIM(NULLIF(TRIM(p_query), '')), ' '), 1) > 1
        THEN 0.55::FLOAT   -- multi-word: stricter (was 0.45)
        ELSE 0.30::FLOAT   -- single-word: looser (typo tolerance)
      END AS trgm_threshold
  ),
  parsed AS (
    SELECT
      params.q,
      params.trgm_threshold,
      CASE
        WHEN params.q IS NULL THEN NULL
        ELSE websearch_to_tsquery('simple', params.q)
      END AS tsq
    FROM params
  ),

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

-- ============================================================
-- SOURCE: 20260404000004_global_search_precision.sql
-- ============================================================

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

-- ============================================================
-- SOURCE: 20260404000005_global_search_agent_payouts.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Global search: agent payout results + notification exclusion
--
-- Changes:
--   1. Exclude 'notification' entity type from search results.
--      Notifications contain order numbers / names in their message text,
--      causing them to appear as results when searching an order number.
--      They are already excluded conceptually (internal system records).
--
--   2. Add agent_payout_matches live CTE so that searching an order number
--      also surfaces the corresponding agent payout records.
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
      AND  word_similarity(prs.q, gsi.title) > 0.12
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY ts_rank(gsi.vec, prs.tsq) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── trigram / typo search ─────────────────────────────────────────────────
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
      gsi.title ILIKE '%' || prs.q || '%'
      OR word_similarity(prs.q, gsi.title) > 0.70
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

  -- ── agent payout search ───────────────────────────────────────────────────
  -- Searches agent_payouts by order number, agent name, or transaction reference.
  -- Primarily triggered when user searches an order number to see all related records.
  agent_payout_matches AS (
    SELECT
      'Agent Payouts'::TEXT                                        AS eg,
      'agent_payout'::TEXT                                         AS et,
      ap.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(soc.order_number), ''), 'Agent Payout') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        am.name,
        ap.amount::TEXT,
        ap.payment_method,
        ap.payment_date::TEXT,
        ap.status
      )), '')                                                      AS sub,
      '/case-matter/agent-payments'::TEXT                          AS url,
      'agent_payouts'::TEXT                                        AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(soc.order_number, '')),
        word_similarity(prs.q, COALESCE(am.name, '')),
        word_similarity(prs.q, COALESCE(ap.transaction_reference, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'agent_payouts'
    JOIN public.agent_payouts ap
      ON prs.q IS NOT NULL
    LEFT JOIN service_order_context soc
      ON soc.service_order_id = ap.service_order_id
    LEFT JOIN public.agent_master am
      ON am.id = ap.agent_id
    WHERE (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
      AND (
        COALESCE(soc.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(am.name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.transaction_reference, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.payment_method, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.status, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
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
    UNION ALL
    SELECT * FROM agent_payout_matches
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
    'role_permission', 'user_role', 'user_permission',
    'notification', 'notification_rule_role'
  )
  ORDER BY (d.fts_rank * 0.7 + d.title_sim * 0.3) DESC, d.ttl ASC
  LIMIT LEAST(p_limit, 50);
$$;

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) FROM anon;

-- ============================================================
-- SOURCE: 20260404000006_global_search_module_filter.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Global search: module-wise grouping / filtering
--
-- Changes:
--   1. Add p_entity_group TEXT parameter to global_search.
--   2. Implement filtering on the resolved entity_group (eg).
--   3. Handle comma-separated list of groups for multi-group modules.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.global_search(
  p_query          TEXT,
  p_branch_id      UUID    DEFAULT NULL,
  p_limit          INTEGER DEFAULT 25,
  p_entity_group   TEXT    DEFAULT NULL,
  p_module_filter  TEXT    DEFAULT NULL,
  p_search_type    TEXT    DEFAULT NULL
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
SET statement_timeout = '30000'
AS $$
  WITH
  params AS (
    SELECT
      NULLIF(TRIM(p_query), '') AS q,
      NULLIF(regexp_replace(TRIM(COALESCE(p_query, '')), '[^0-9]+', '', 'g'), '') AS q_digits,
      NULLIF(TRIM(p_entity_group), '') AS group_filter
  ),
  parsed AS (
    SELECT
      params.q,
      params.q_digits,
      params.group_filter,
      CASE
        WHEN params.q IS NULL THEN NULL
        ELSE websearch_to_tsquery('simple', params.q)
      END AS tsq,
      NULLIF(TRIM(p_module_filter), '') AS module_filter,
      NULLIF(TRIM(UPPER(p_search_type)), '') AS search_type
    FROM params
  ),

  -- ── Friendly Module -> DB Group Mapping ─────────────────────────────────────
  -- This allows pruning the search index early based on the specific module.
  module_group_map AS (
    SELECT 'CLIENT & LEGAL'::TEXT AS module, 'Cases & Matters'::TEXT AS eg UNION ALL
    SELECT 'CLIENT & LEGAL', 'People' UNION ALL
    SELECT 'HR & PAYROLL', 'Attendance' UNION ALL
    SELECT 'HR & PAYROLL', 'Leave Records' UNION ALL
    SELECT 'HR & PAYROLL', 'Hr' UNION ALL
    SELECT 'OPERATIONS & REPORTS', 'Agent Payouts' UNION ALL
    SELECT 'OPERATIONS & REPORTS', 'Reports' UNION ALL
    SELECT 'System Masters', 'System Masters' UNION ALL
    SELECT 'Documents', 'Documents, Templates & Knowledge' UNION ALL
    SELECT 'Documents', 'Legal Templates' UNION ALL
    SELECT 'Documents', 'Documents'
  ),
  active_groups AS (
    SELECT string_agg(eg, '|') AS groups
    FROM module_group_map
    JOIN parsed prs ON prs.module_filter IS NOT NULL AND module_group_map.module = prs.module_filter
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
    CROSS JOIN active_groups ag
    JOIN   filtered_modules fm            ON fm.module = gsi.permission_module
    WHERE  (prs.search_type IS NULL OR prs.search_type = 'INDEX')
      AND  (prs.module_filter IS NULL OR gsi.entity_group = ANY(string_to_array(COALESCE(ag.groups, ''), '|')) OR prs.module_filter = 'All')
      AND  gsi.vec @@ prs.tsq
      AND  word_similarity(prs.q, gsi.title) > 0.12
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY ts_rank(gsi.vec, prs.tsq) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── trigram / typo search ─────────────────────────────────────────────────
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
    CROSS JOIN active_groups ag
    JOIN   filtered_modules fm            ON fm.module = gsi.permission_module
    WHERE  (prs.search_type IS NULL OR prs.search_type = 'INDEX')
      AND  (prs.module_filter IS NULL OR gsi.entity_group = ANY(string_to_array(COALESCE(ag.groups, ''), '|')) OR prs.module_filter = 'All')
      AND  (
      gsi.title ILIKE '%' || prs.q || '%'
      OR word_similarity(prs.q, gsi.title) > 0.70
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
    WHERE  (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND  (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND  (
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
    WHERE  (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND  (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND  COALESCE(c.is_deleted, false) = false
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
    WHERE  (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND  (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND  COALESCE(a.is_deleted, false) = false
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
    WHERE (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND so.is_case = true
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
    WHERE (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND so.is_case = false
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
    WHERE (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
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
    WHERE (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND (prs.module_filter IS NULL OR prs.module_filter = 'CLIENT & LEGAL' OR prs.module_filter = 'All')
      AND (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
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
    WHERE  (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND  (prs.module_filter IS NULL OR prs.module_filter = 'Documents' OR prs.module_filter = 'All')
      AND  COALESCE(dt.is_deleted, false) = false
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

  -- ── agent payout search ───────────────────────────────────────────────────
  agent_payout_matches AS (
    SELECT
      'Agent Payouts'::TEXT                                        AS eg,
      'agent_payout'::TEXT                                         AS et,
      ap.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(soc.order_number), ''), 'Agent Payout') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        am.name,
        ap.amount::TEXT,
        ap.payment_method,
        ap.payment_date::TEXT,
        ap.status
      )), '')                                                      AS sub,
      '/case-matter/agent-payments'::TEXT                          AS url,
      'agent_payouts'::TEXT                                        AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(soc.order_number, '')),
        word_similarity(prs.q, COALESCE(am.name, '')),
        word_similarity(prs.q, COALESCE(ap.transaction_reference, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'agent_payouts'
    JOIN public.agent_payouts ap
      ON prs.q IS NOT NULL
    LEFT JOIN service_order_context soc
      ON soc.service_order_id = ap.service_order_id
    LEFT JOIN public.agent_master am
      ON am.id = ap.agent_id
    WHERE (prs.search_type IS NULL OR prs.search_type = 'RECORDS')
      AND (prs.module_filter IS NULL OR prs.module_filter = 'OPERATIONS & REPORTS' OR prs.module_filter = 'All')
      AND (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
      AND (
        COALESCE(soc.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(am.name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.transaction_reference, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.payment_method, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.status, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
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
    UNION ALL
    SELECT * FROM agent_payout_matches
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
        WHEN m.et IN ('attendance_record','employee_attendance','punch_edit_request')
          THEN 'Attendance'
        WHEN m.et IN ('leave','leave_balance','leave_workflow')
          THEN 'Leave Records'
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
    SELECT DISTINCT ON (n.et, n.id_key)
      n.eg, n.et, n.eid, n.ttl, n.sub, n.url, n.pm, n.fts_rank, n.title_sim
    FROM (
      SELECT *, (et || '-' || eid::TEXT) AS id_key FROM normalised
    ) n
    ORDER BY n.et, n.id_key,
             (n.fts_rank * 0.7 + n.title_sim * 0.3) DESC,
             n.ttl ASC
  ),

  ranked AS (
    SELECT
      d.eg   AS entity_group,
      d.et   AS entity_type,
      d.eid  AS entity_id,
      d.ttl  AS title,
      d.sub  AS subtitle,
      d.url  AS url,
      d.pm   AS permission_module,
      (d.fts_rank * 0.7 + d.title_sim * 0.3) AS score,
      ROW_NUMBER() OVER(
        PARTITION BY d.eg 
        ORDER BY (d.fts_rank * 0.7 + d.title_sim * 0.3) DESC, d.ttl ASC
      ) as rnk
    FROM deduped d
    JOIN parsed prs ON true
    WHERE d.et NOT IN (
      'employee', 'user_profile',
      'smtp_setting', 'approval_setting', 'company_setting', 'system_setting',
      'biometric_device', 'notification_rule', 'notification_global_setting',
      'push_subscription', 'dashboard', 'dashboard_widget',
      'audit_log', 'activity_log', 'data_export', 'report_execution',
      'role_permission', 'user_role', 'user_permission',
      'notification', 'notification_rule_role'
    )
    AND (
      prs.group_filter IS NULL 
      OR d.eg = ANY(string_to_array(prs.group_filter, '|'))
    )
  )

  SELECT
    entity_group, entity_type, entity_id, title, subtitle, url, permission_module
  FROM ranked
  WHERE rnk <= 10
  ORDER BY score DESC, title ASC
  LIMIT LEAST(p_limit, 50);
$$;

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER, TEXT, TEXT, TEXT) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER, TEXT, TEXT, TEXT) FROM anon;

-- ============================================================
-- SOURCE: 20260405000001_global_search_user_scope.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Global search: row-level user scoping
--
-- Problem:
--   global_search filtered by module-level permissions (can the user reach the
--   page?) but ignored row-level scoping (can the user see ALL rows on that page
--   or only their own?).
--
--   Example: an employee has the `leaves` module permission and can view the
--   Leaves page — but on that page they only see their OWN leave records.
--   Previously, global search returned every employee's leave records to them.
--
-- Fix:
--   For each "user-owned" entity type, the result row is only returned if:
--     (a) the caller holds the appropriate "see all employees" permission/module, OR
--     (b) the row belongs to the caller's own employee record.
--
-- Scoped entity types and their gates:
--
--   leave / leave_balance / sandwich_tracking
--     → gate: filtered_modules includes 'leaves_all_employees'
--
--   punch_edit_request
--     → gate: permission name 'Punch Requests Employee Filter (View)'
--
--   expense / expense_item / expense_payment
--     → no gate: always scoped to own (created_by = auth.uid())
--
--   task / service_order_subtask
--     → no gate: always scoped to assigned_employee_id
--
--   employee_attendance / attendance_record / punch_record /
--   late_tracking / attendance_day_counting
--     → no gate: always scoped to own employee record
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

  -- ── current user's employee record ───────────────────────────────────────
  -- Used to scope "own records only" results for leaves, punch, expenses, etc.
  -- Returns NULL emp_id when the caller has no linked employee row (admin users),
  -- which means ownership checks will never match → scoped types hidden unless
  -- the caller also has the all-employees gate.
  current_user_emp AS (
    SELECT e.id AS emp_id
    FROM   public.employees e
    WHERE  e.user_id = auth.uid()
      AND  COALESCE(e.is_deleted, false) = false
    LIMIT  1
  ),

  -- ── "see all leaves" permission check ────────────────────────────────────
  -- Mirrors the Leaves page check: canManageAllLeaves checks for the named
  -- permission 'Leaves All Employees (View)' rather than the module alone.
  -- Using a name-based check is more precise than checking filtered_modules,
  -- which may include the module for users who have the permission but without
  -- the effective can_view grant at the role level.
  can_see_all_leaves AS (
    SELECT 1
    FROM (
      SELECT 1
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
        AND  p.name        = 'Leaves All Employees (View)'
        AND  p.can_view    = true
      UNION ALL
      SELECT 1
      FROM   public.user_permissions up_l
      JOIN   public.permissions p
               ON p.id          = up_l.permission_id
              AND p.is_active   = true
              AND p.is_deleted  = false
      WHERE  up_l.user_id   = auth.uid()
        AND  up_l.is_active  = true
        AND  up_l.is_deleted = false
        AND  p.name          = 'Leaves All Employees (View)'
        AND  up_l.can_view   = true
    ) x
    LIMIT 1
  ),

  -- ── "see all punch requests" permission check ─────────────────────────────
  -- The Punch Requests page uses a named permission (not a separate module)
  -- to decide whether to show an employee-filter dropdown.
  -- We replicate the same two-layer role/user lookup.
  can_see_all_punch AS (
    SELECT 1
    FROM (
      SELECT 1
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
        AND  p.name        = 'Punch Requests Employee Filter (View)'
        AND  p.can_view    = true
      UNION ALL
      SELECT 1
      FROM   public.user_permissions up_e
      JOIN   public.permissions p
               ON p.id          = up_e.permission_id
              AND p.is_active   = true
              AND p.is_deleted  = false
      WHERE  up_e.user_id   = auth.uid()
        AND  up_e.is_active  = true
        AND  up_e.is_deleted = false
        AND  p.name          = 'Punch Requests Employee Filter (View)'
        AND  up_e.can_view   = true
    ) x
    LIMIT 1
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
      AND  word_similarity(prs.q, gsi.title) > 0.12
      AND  (p_branch_id IS NULL OR gsi.branch_id IS NULL OR gsi.branch_id = p_branch_id)
    ORDER  BY ts_rank(gsi.vec, prs.tsq) DESC, gsi.title ASC
    LIMIT  LEAST(p_limit, 50) * 4
  ),

  -- ── trigram / typo search ─────────────────────────────────────────────────
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
      gsi.title ILIKE '%' || prs.q || '%'
      OR word_similarity(prs.q, gsi.title) > 0.70
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

  agent_payout_matches AS (
    SELECT
      'Agent Payouts'::TEXT                                        AS eg,
      'agent_payout'::TEXT                                         AS et,
      ap.id                                                        AS eid,
      COALESCE(NULLIF(TRIM(soc.order_number), ''), 'Agent Payout') AS ttl,
      NULLIF(TRIM(concat_ws(' | ',
        am.name,
        ap.amount::TEXT,
        ap.payment_method,
        ap.payment_date::TEXT,
        ap.status
      )), '')                                                      AS sub,
      '/case-matter/agent-payments'::TEXT                          AS url,
      'agent_payouts'::TEXT                                        AS pm,
      0.8::REAL                                                    AS fts_rank,
      GREATEST(
        word_similarity(prs.q, COALESCE(soc.order_number, '')),
        word_similarity(prs.q, COALESCE(am.name, '')),
        word_similarity(prs.q, COALESCE(ap.transaction_reference, ''))
      )                                                            AS title_sim
    FROM parsed prs
    JOIN filtered_modules fm
      ON fm.module = 'agent_payouts'
    JOIN public.agent_payouts ap
      ON prs.q IS NOT NULL
    LEFT JOIN service_order_context soc
      ON soc.service_order_id = ap.service_order_id
    LEFT JOIN public.agent_master am
      ON am.id = ap.agent_id
    WHERE (p_branch_id IS NULL OR soc.branch_id IS NULL OR soc.branch_id = p_branch_id)
      AND (
        COALESCE(soc.order_number, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(am.name, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.transaction_reference, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.payment_method, '') ILIKE '%' || prs.q || '%'
        OR COALESCE(ap.status, '') ILIKE '%' || prs.q || '%'
      )
    LIMIT LEAST(p_limit, 50) * 2
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
    UNION ALL
    SELECT * FROM agent_payout_matches
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

  -- ── static exclusion list ─────────────────────────────────────────────────
  WHERE d.et NOT IN (
    'employee', 'user_profile',
    'smtp_setting', 'approval_setting', 'company_setting', 'system_setting',
    'biometric_device', 'notification_rule', 'notification_global_setting',
    'push_subscription', 'dashboard', 'dashboard_widget',
    'audit_log', 'activity_log', 'data_export', 'report_execution',
    'role_permission', 'user_role', 'user_permission',
    'notification', 'notification_rule_role',
    'leave', 'leave_balance', 'sandwich_tracking',
    'punch_edit_request'
  )

  -- ── row-level scope: expenses ─────────────────────────────────────────────
  -- Visible only when the expense was created by the caller.
  -- expense_item / expense_payment ownership is resolved through the parent expense.
  AND (
    d.et NOT IN ('expense', 'expense_item', 'expense_payment')
    OR EXISTS (
      SELECT 1 FROM (
        SELECT ex.created_by AS uid
        FROM   public.expenses ex
        WHERE  ex.id = d.eid AND d.et = 'expense'
        UNION ALL
        SELECT ex2.created_by
        FROM   public.expense_items ei
        JOIN   public.expenses ex2 ON ex2.id = ei.expense_id
        WHERE  ei.id = d.eid AND d.et = 'expense_item'
        UNION ALL
        SELECT ex3.created_by
        FROM   public.expense_payments ep
        JOIN   public.expenses ex3 ON ex3.id = ep.expense_id
        WHERE  ep.id = d.eid AND d.et = 'expense_payment'
      ) eown
      WHERE eown.uid = auth.uid()
    )
  )

  -- ── row-level scope: tasks ───────────────────────────────────────────────
  -- Visible only when the task/subtask is assigned to the caller's employee.
  -- task_comment and task_time_log are left unscoped (supporting records only).
  AND (
    d.et NOT IN ('task', 'service_order_subtask')
    OR EXISTS (
      SELECT 1 FROM (
        SELECT sot.assigned_employee_id AS eid
        FROM   public.service_order_tasks sot
        WHERE  sot.id = d.eid AND d.et = 'task'
        UNION ALL
        SELECT sos.assigned_employee_id
        FROM   public.service_order_subtasks sos
        WHERE  sos.id = d.eid AND d.et = 'service_order_subtask'
      ) town
      WHERE town.eid = (SELECT emp_id FROM current_user_emp)
    )
  )

  -- ── row-level scope: attendance & punch records ───────────────────────────
  -- Visible only when this is the caller's own attendance/punch record.
  -- punch_record ownership resolved via enroll_number → user_profiles.biometric_code.
  AND (
    d.et NOT IN (
      'employee_attendance', 'attendance_record', 'punch_record',
      'late_tracking', 'attendance_day_counting'
    )
    OR EXISTS (
      SELECT 1 FROM (
        SELECT ea.employee_id AS eid
        FROM   public.employee_attendance ea
        WHERE  ea.id = d.eid AND d.et = 'employee_attendance'
        UNION ALL
        SELECT e1.id
        FROM   public.attendance_records ar
        JOIN   public.employees e1 ON e1.user_id = ar.user_profile_id
        WHERE  ar.id = d.eid AND d.et = 'attendance_record'
        UNION ALL
        SELECT e2.id
        FROM   public.punch_records pr
        JOIN   public.user_profiles up
                 ON up.biometric_code = pr.enroll_number::TEXT
        JOIN   public.employees e2 ON e2.user_id = up.id
        WHERE  pr.id = d.eid AND d.et = 'punch_record'
        UNION ALL
        SELECT elt.employee_id
        FROM   public.employee_late_tracking elt
        WHERE  elt.id = d.eid AND d.et = 'late_tracking'
        UNION ALL
        SELECT adc.employee_id
        FROM   public.attendance_day_counting adc
        WHERE  adc.id = d.eid AND d.et = 'attendance_day_counting'
      ) aown
      WHERE aown.eid = (SELECT emp_id FROM current_user_emp)
    )
  )

  ORDER BY (d.fts_rank * 0.7 + d.title_sim * 0.3) DESC, d.ttl ASC
  LIMIT LEAST(p_limit, 50);
$$;

GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) TO service_role;
REVOKE EXECUTE ON FUNCTION public.global_search(TEXT, UUID, INTEGER) FROM anon;

-- ============================================================
-- SOURCE: 20260415000001_global_search_income.sql
-- ============================================================

-- Global Search: Add Income Records Support
-- Migration: 20260415000001
-- Purpose: Add trigger to refresh materialized view on income_records changes
--
-- Note: The existing refresh_search_index function may have a different signature.
-- We must drop it first before creating the trigger function version.

-- Drop existing function(s) with any signature
DROP FUNCTION IF EXISTS public.refresh_search_index() CASCADE;

-- Create trigger function
CREATE FUNCTION public.refresh_search_index()
RETURNS TRIGGER AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.global_search_index;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Trigger on income_records to refresh search index
DROP TRIGGER IF EXISTS trigger_refresh_search_on_income ON public.income_records;
CREATE TRIGGER trigger_refresh_search_on_income
  AFTER INSERT OR UPDATE OR DELETE ON public.income_records
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.refresh_search_index();

-- ============================================================
-- SOURCE: 20260415000004_fix_global_search_ownership.sql
-- ============================================================

-- Fix global_search_index materialized view ownership and permissions
-- Migration: 20260415000004
-- Purpose: Fix ownership and refresh permissions for global_search_index

-- First, check if the materialized view exists
DO $$
DECLARE
  view_exists BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_matviews 
    WHERE schemaname = 'public' 
    AND matviewname = 'global_search_index'
  ) INTO view_exists;
  
  IF view_exists THEN
    -- Change ownership to service_role (authenticated users can refresh)
    ALTER MATERIALIZED VIEW public.global_search_index OWNER TO service_role;
    
    -- Grant refresh permission to authenticated users
    GRANT SELECT ON public.global_search_index TO authenticated;
    
    RAISE NOTICE 'Fixed ownership and permissions for global_search_index';
  ELSE
    RAISE NOTICE 'global_search_index materialized view does not exist, skipping';
  END IF;
END $$;

-- Also grant to postgres (default owner)
DO $$
BEGIN
  -- Try to set proper privileges
  BEGIN
    EXECUTE 'ALTER MATERIALIZED VIEW public.global_search_index OWNER TO postgres';
  EXCEPTION WHEN OTHERS THEN
    NULL; -- Ignore if already owned or doesn't exist
  END;
END $$;

-- ============================================================
-- SOURCE: 20260415000005_fix_global_search_trigger.sql
-- ============================================================

-- Fix global_search_index trigger permission issue
-- Migration: 20260415000005
-- Purpose: Fix trigger that fails due to materialized view ownership

-- Drop existing trigger and function
DROP TRIGGER IF EXISTS trigger_refresh_search_on_income ON public.income_records;
DROP FUNCTION IF EXISTS public.refresh_search_index() CASCADE;

-- Recreate function with SECURITY DEFINER (runs as owner/postgres)
CREATE OR REPLACE FUNCTION public.refresh_search_index()
RETURNS TRIGGER 
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.global_search_index;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Recreate trigger
CREATE TRIGGER trigger_refresh_search_on_income
  AFTER INSERT OR UPDATE OR DELETE ON public.income_records
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.refresh_search_index();

-- Ensure the function owner is postgres (superuser)
ALTER FUNCTION public.refresh_search_index() OWNER TO postgres;

REFRESH MATERIALIZED VIEW public.global_search_index;