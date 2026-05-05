-- Module-to-database-table mapping for "Module-wise Data Size" Admin Dashboard widget.
-- Enables admins to associate functional modules (app_modules) with the underlying
-- Postgres tables whose sizes should be aggregated for that module.

-- ============================================
-- 1. Mapping table
-- ============================================
CREATE TABLE IF NOT EXISTS public.app_module_tables (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    module_id uuid NOT NULL REFERENCES public.app_modules(id) ON DELETE CASCADE,
    table_name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (module_id, table_name)
);

CREATE INDEX IF NOT EXISTS idx_app_module_tables_module_id
    ON public.app_module_tables(module_id);

-- ============================================
-- 2. RPC: total size (bytes) for a list of public-schema tables
-- ============================================
CREATE OR REPLACE FUNCTION public.get_table_sizes(tables text[])
RETURNS TABLE(table_name text, total_bytes bigint)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT t AS table_name,
           pg_total_relation_size(format('public.%I', t)::regclass) AS total_bytes
    FROM unnest(tables) AS t
    WHERE to_regclass(format('public.%I', t)) IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION public.get_table_sizes(text[]) TO authenticated, service_role;

-- List of public-schema base tables (for the "add mapping" dropdown in the admin UI).
CREATE OR REPLACE FUNCTION public.get_public_tables()
RETURNS TABLE(table_name text)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT t.table_name::text
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
    ORDER BY t.table_name;
$$;

GRANT EXECUTE ON FUNCTION public.get_public_tables() TO authenticated, service_role;

-- ============================================
-- 3. Seed mappings — EXACT slug match, manually reviewed.
--    Module slugs from app_modules:
--      planner, legal_services, crm, employee_mgmt, attendance,
--      payroll_benefits, expense_accounting, reports, notifications,
--      legal_masters, org_masters, hr_masters, location_masters,
--      user_access, settings, income_records
-- ============================================
DO $$
DECLARE
    seed RECORD;
    v_module_id uuid;
BEGIN
    FOR seed IN
        SELECT * FROM (VALUES
            -- ══════════════════════════════════════════════
            -- planner  (My Planner — todos, diary, calendar)
            -- ══════════════════════════════════════════════
            ('planner',            'employee_todos'),
            ('planner',            'diary_master'),
            ('planner',            'company_events'),

            -- ══════════════════════════════════════════════
            -- legal_services  (Legal Services — service orders, cases, hearings)
            -- ══════════════════════════════════════════════
            ('legal_services',     'service_orders'),
            ('legal_services',     'service_order_stages'),
            ('legal_services',     'service_order_subtasks'),
            ('legal_services',     'service_order_tasks'),
            ('legal_services',     'service_order_task_documents'),
            ('legal_services',     'service_order_task_employees'),
            ('legal_services',     'service_order_stage_employees'),
            ('legal_services',     'service_order_stage_document_fields'),
            ('legal_services',     'service_order_witnesses'),
            ('legal_services',     'service_order_witness_documents'),
            ('legal_services',     'service_order_witness_ids'),
            ('legal_services',     'service_order_folders'),
            ('legal_services',     'service_order_expenses'),
            ('legal_services',     'service_order_payments'),
            ('legal_services',     'service_payments'),
            ('legal_services',     'order_cases'),
            ('legal_services',     'case_hearings'),
            ('legal_services',     'case_assigned_employees'),
            ('legal_services',     'hearing_assigned_employees'),
            ('legal_services',     'hearing_participants'),
            ('legal_services',     'clients'),
            ('legal_services',     'documents'),

            -- ══════════════════════════════════════════════
            -- crm  (CRM — leads, inquiries, agents, quotations)
            -- ══════════════════════════════════════════════
            ('crm',                'leads'),
            ('crm',                'inquiries'),
            ('crm',                'inquiry_notes'),
            ('crm',                'inquiry_tasks'),
            ('crm',                'agent_master'),
            ('crm',                'agent_payouts'),
            ('crm',                'quotations'),
            ('crm',                'quotation_payments'),
            ('crm',                'quotation_versions'),
            ('crm',                'quotation_settings'),

            -- ══════════════════════════════════════════════
            -- employee_mgmt  (Employee Management)
            -- ══════════════════════════════════════════════
            ('employee_mgmt',      'employees'),
            ('employee_mgmt',      'user_profiles'),
            ('employee_mgmt',      'employee_bank_details'),
            ('employee_mgmt',      'employee_documents'),
            ('employee_mgmt',      'employee_referrals'),
            ('employee_mgmt',      'employee_shifts'),
            ('employee_mgmt',      'notice_penalties'),
            ('employee_mgmt',      'contracts'),
            ('employee_mgmt',      'contract_revisions'),
            ('employee_mgmt',      'user_contract_acceptance'),

            -- ══════════════════════════════════════════════
            -- attendance  (Attendance & Punch Records)
            -- ══════════════════════════════════════════════
            ('attendance',         'punch_records'),
            ('attendance',         'attendance_records'),
            ('attendance',         'punch_edit_requests'),
            ('attendance',         'employee_late_tracking'),
            ('attendance',         'sandwich_rule_tracking'),
            ('attendance',         'attendance_day_counting'),
            ('attendance',         'employee_attendance'),
            ('attendance',         'punch_metadata'),
            ('attendance',         'punch_images'),
            ('attendance',         'biometric_devices'),
            ('attendance',         'biometric_sync_requests'),

            -- ══════════════════════════════════════════════
            -- payroll_benefits  (Payroll & Benefits — salary, loans, PF, etc.)
            -- ══════════════════════════════════════════════
            ('payroll_benefits',   'payroll'),
            ('payroll_benefits',   'payroll_periods'),
            ('payroll_benefits',   'payroll_components'),
            ('payroll_benefits',   'payroll_adjustments'),
            ('payroll_benefits',   'payroll_deduction_adjustments'),
            ('payroll_benefits',   'salary_components'),
            ('payroll_benefits',   'employee_salary_components'),
            ('payroll_benefits',   'employee_advances'),
            ('payroll_benefits',   'advance_recovery_transactions'),
            ('payroll_benefits',   'employee_loans'),
            ('payroll_benefits',   'loan_transactions'),
            ('payroll_benefits',   'employee_pf_accounts'),
            ('payroll_benefits',   'pf_transactions'),
            ('payroll_benefits',   'employee_security_deposits'),
            ('payroll_benefits',   'security_deposit_transactions'),
            ('payroll_benefits',   'security_deposit_configs'),
            ('payroll_benefits',   'security_deposits'),

            -- ══════════════════════════════════════════════
            -- expense_accounting  (Expense & Accounting + Cash & Bank)
            -- ══════════════════════════════════════════════
            ('expense_accounting', 'expenses'),
            ('expense_accounting', 'expense_categories'),
            ('expense_accounting', 'expense_items'),
            ('expense_accounting', 'expense_payments'),
            ('expense_accounting', 'bank_accounts'),
            ('expense_accounting', 'payment_transactions_registry'),
            ('expense_accounting', 'payment_transaction_details'),
            ('expense_accounting', 'payment_transactions'),
            ('expense_accounting', 'payment_transactions_service_orders'),
            ('expense_accounting', 'account_transfers'),
            ('expense_accounting', 'inventory_items'),
            ('expense_accounting', 'inventory_units'),
            ('expense_accounting', 'inventory_transactions'),
            ('expense_accounting', 'purchase_orders'),
            ('expense_accounting', 'purchase_order_items'),
            ('expense_accounting', 'employee_inventory_issues'),
            ('expense_accounting', 'employee_inventory_issue_items'),
            ('expense_accounting', 'employee_inventory_summary'),
            ('expense_accounting', 'suppliers'),
            ('expense_accounting', 'invoice_templates'),

            -- ══════════════════════════════════════════════
            -- income_records  (Income Records)
            -- ══════════════════════════════════════════════
            ('income_records',     'income_records'),

            -- ══════════════════════════════════════════════
            -- reports  (Reports & Audit)
            -- ══════════════════════════════════════════════
            ('reports',            'reports'),
            ('reports',            'report_executions'),
            ('reports',            'data_exports'),
            ('reports',            'dashboards'),
            ('reports',            'dashboard_widgets'),
            ('reports',            'audit_logs'),
            ('reports',            'activity_logs'),

            -- ══════════════════════════════════════════════
            -- notifications  (Notifications & Communication)
            -- ══════════════════════════════════════════════
            ('notifications',      'notifications'),
            ('notifications',      'push_subscriptions'),
            ('notifications',      'notification_auto_rules'),
            ('notifications',      'notification_auto_rule_roles'),
            ('notifications',      'recurring_notification_schedules'),
            ('notifications',      'event_notification_log'),
            ('notifications',      'email_templates'),
            ('notifications',      'notification_channel_settings'),
            ('notifications',      'notification_global_settings'),

            -- ══════════════════════════════════════════════
            -- legal_masters  (Legal Masters — service templates, courts, doc templates)
            -- ══════════════════════════════════════════════
            ('legal_masters',      'service_master'),
            ('legal_masters',      'service_stages'),
            ('legal_masters',      'service_tasks'),
            ('legal_masters',      'service_task_documents'),
            ('legal_masters',      'service_task_employees'),
            ('legal_masters',      'service_stage_employees'),
            ('legal_masters',      'service_category_master'),
            ('legal_masters',      'courts'),
            ('legal_masters',      'document_templates'),
            ('legal_masters',      'document_template_translations'),
            ('legal_masters',      'document_category_master'),
            ('legal_masters',      'required_documents_master'),
            ('legal_masters',      'fields_master'),
            ('legal_masters',      'company_terms'),

            -- ══════════════════════════════════════════════
            -- org_masters  (Organization Masters — departments, designations, branches)
            -- ══════════════════════════════════════════════
            ('org_masters',        'departments'),
            ('org_masters',        'designations'),
            ('org_masters',        'branches'),
            ('org_masters',        'work_types'),

            -- ══════════════════════════════════════════════
            -- hr_masters  (HR Masters — shifts, leaves, contracts, holidays)
            -- ══════════════════════════════════════════════
            ('hr_masters',         'shifts'),
            ('hr_masters',         'work_weeks'),
            ('hr_masters',         'leave_types'),
            ('hr_masters',         'leave_accrual_rules'),
            ('hr_masters',         'leave_accrual_tracking'),
            ('hr_masters',         'leave_approval_workflow'),
            ('hr_masters',         'leave_reason_master'),
            ('hr_masters',         'leave_requests'),
            ('hr_masters',         'leave_balances'),
            ('hr_masters',         'employee_leave_balances'),
            ('hr_masters',         'employee_leaves'),
            ('hr_masters',         'leave_applications'),
            ('hr_masters',         'leaves'),
            ('hr_masters',         'contract_leaves'),
            ('hr_masters',         'contract_holidays'),
            ('hr_masters',         'contract_groups'),
            ('hr_masters',         'contract_types'),
            ('hr_masters',         'contract_type_required_documents'),
            ('hr_masters',         'contract_templates'),
            ('hr_masters',         'holiday_masters'),
            ('hr_masters',         'holidays'),
            ('hr_masters',         'approval_settings'),
            ('hr_masters',         'hr_approvals'),
            ('hr_masters',         'policies'),

            -- ══════════════════════════════════════════════
            -- location_masters  (Location Masters — geo data)
            -- ══════════════════════════════════════════════
            ('location_masters',   'countries'),
            ('location_masters',   'states'),
            ('location_masters',   'districts'),
            ('location_masters',   'cities'),
            ('location_masters',   'talukas'),
            ('location_masters',   'villages'),
            ('location_masters',   'pincodes'),

            -- ══════════════════════════════════════════════
            -- user_access  (User & Access Management)
            -- ══════════════════════════════════════════════
            ('user_access',        'roles'),
            ('user_access',        'permissions'),
            ('user_access',        'role_permissions'),
            ('user_access',        'user_roles'),
            ('user_access',        'user_permissions'),
            ('user_access',        'user_two_factor_preferences'),
            ('user_access',        'user_two_factor_email_challenges'),
            ('user_access',        'user_two_factor_recovery_codes'),
            ('user_access',        'security_audit_log'),

            -- ══════════════════════════════════════════════
            -- settings  (Settings — company, system, SMTP, CMS, nav)
            -- ══════════════════════════════════════════════
            ('settings',           'company_settings'),
            ('settings',           'system_settings'),
            ('settings',           'smtp_settings'),
            ('settings',           'app_modules'),
            ('settings',           'app_module_groups'),
            ('settings',           'app_module_tables'),
            ('settings',           'app_pages'),
            ('settings',           'module_groups'),
            ('settings',           'module_pages'),
            ('settings',           'cms_knowledge_items'),
            ('settings',           'cms_external_reviews'),
            ('settings',           'cms_review_sources'),
            ('settings',           'cms_homepage'),

            -- ══════════════════════════════════════════════
            -- ADDITIONAL TABLES (previously unmapped)
            -- ══════════════════════════════════════════════

            -- attendance: base attendance table
            ('attendance',         'attendance'),

            -- payroll_benefits: advance transactions, salary breakdown
            ('payroll_benefits',   'employee_advance_transactions'),
            ('payroll_benefits',   'payroll_salary_breakdown'),

            -- legal_services: additional service order sub-tables
            ('legal_services',     'service_order_cases'),
            ('legal_services',     'service_order_hearings'),
            ('legal_services',     'service_order_hearing_participants'),
            ('legal_services',     'service_order_payment_employees'),
            ('legal_services',     'service_order_task_witnesses'),
            ('legal_services',     'service_payment_employees'),

            -- legal_masters: additional service template tables, company terms
            ('legal_masters',      'service_stage_documents'),
            ('legal_masters',      'service_subtasks'),
            ('legal_masters',      'company_term_acknowledgments'),
            ('legal_masters',      'company_term_revisions'),

            -- hr_masters: leave accrual groups & transactions
            ('hr_masters',         'leave_accrual_groups'),
            ('hr_masters',         'leave_accrual_transactions'),

            -- expense_accounting: inventory notifications
            ('expense_accounting', 'inventory_notifications'),

            -- notifications: additional notification infrastructure tables
            ('notifications',      'notification_categories'),
            ('notifications',      'notification_channel_templates'),
            ('notifications',      'notification_configurations'),
            ('notifications',      'notification_delivery_log'),
            ('notifications',      'notification_preferences'),
            ('notifications',      'notification_queue'),
            ('notifications',      'notification_templates'),
            ('notifications',      'notification_types'),
            ('notifications',      'user_notification_preferences'),

            -- planner: task comments & time tracking
            ('planner',            'task_comments'),
            ('planner',            'task_time_logs')

        ) AS s(module_slug, table_name)
    LOOP
        -- Skip if the table doesn't exist in this DB.
        IF to_regclass(format('public.%I', seed.table_name)) IS NULL THEN
            CONTINUE;
        END IF;

        -- Look up module by exact slug.
        SELECT id INTO v_module_id
        FROM public.app_modules
        WHERE slug = seed.module_slug
        LIMIT 1;

        IF v_module_id IS NULL THEN
            CONTINUE;
        END IF;

        INSERT INTO public.app_module_tables (module_id, table_name)
        VALUES (v_module_id, seed.table_name)
        ON CONFLICT (module_id, table_name) DO NOTHING;
    END LOOP;
END $$;
