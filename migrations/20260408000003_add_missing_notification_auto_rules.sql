-- ============================================================================
-- Migration: Add missing notification auto-rules
-- ============================================================================
-- Fixes 5 triggers that are called from code but have no auto-rule in DB:
--   1) contract_accepted       — migration existed but was never run
--   2) onboarding_documents_submitted — same
--   3) deposit_approved        — template UPDATE existed but no INSERT
--   4) deposit_refunded        — same
--   5) witness_invited         — rule exists but has no recipient role mappings
-- ============================================================================

-- BEGIN; (removed: exec_sql cannot run tx control)

-- ────────────────────────────────────────────────────────────────────────────
-- 1) CONTRACT ACCEPTED
--    Notifies HR/Admin when employee accepts contract.
--    Variables: employee_name, employee_code, contract_type, date
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.notification_auto_rules (
    id, name, description, trigger_type, is_active, include_affected_user,
    channels, subject_template, message_template, created_at, updated_at
)
SELECT
    gen_random_uuid(),
    'Contract accepted',
    'Notifies HR/Admin when an employee accepts their contract.',
    'contract_accepted',
    true,
    true,
    '{"push": true, "email": true, "sms": false, "whatsapp": false}'::jsonb,
    'Contract accepted: {{employee_name}} ({{employee_code}})',
    '{{employee_name}} ({{employee_code}}) has accepted the contract ({{contract_type}}) on {{date}}. They can now proceed to document upload.',
    NOW(), NOW()
FROM (SELECT 1) AS _dummy
WHERE NOT EXISTS (SELECT 1 FROM public.notification_auto_rules WHERE trigger_type = 'contract_accepted');

INSERT INTO public.notification_auto_rule_roles (rule_id, role_id)
SELECT nar.id, r.id
FROM public.notification_auto_rules nar
CROSS JOIN public.roles r
WHERE nar.trigger_type = 'contract_accepted'
  AND LOWER(TRIM(r.name)) IN ('admin', 'hr manager')
  AND COALESCE(r.is_deleted, false) = false
ON CONFLICT (rule_id, role_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 2) ONBOARDING DOCUMENTS SUBMITTED
--    Notifies HR/Admin when employee completes document upload.
--    Variables: employee_name, employee_code, date, documents_count
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.notification_auto_rules (
    id, name, description, trigger_type, is_active, include_affected_user,
    channels, subject_template, message_template, created_at, updated_at
)
SELECT
    gen_random_uuid(),
    'Onboarding documents submitted',
    'Notifies HR/Admin when an employee completes document upload.',
    'onboarding_documents_submitted',
    true,
    true,
    '{"push": true, "email": true, "sms": false, "whatsapp": false}'::jsonb,
    'Onboarding documents submitted: {{employee_name}} ({{employee_code}})',
    '{{employee_name}} ({{employee_code}}) has completed document upload on {{date}}. Please review and approve in HR Approvals.',
    NOW(), NOW()
FROM (SELECT 1) AS _dummy
WHERE NOT EXISTS (SELECT 1 FROM public.notification_auto_rules WHERE trigger_type = 'onboarding_documents_submitted');

INSERT INTO public.notification_auto_rule_roles (rule_id, role_id)
SELECT nar.id, r.id
FROM public.notification_auto_rules nar
CROSS JOIN public.roles r
WHERE nar.trigger_type = 'onboarding_documents_submitted'
  AND LOWER(TRIM(r.name)) IN ('admin', 'hr manager')
  AND COALESCE(r.is_deleted, false) = false
ON CONFLICT (rule_id, role_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 3) DEPOSIT APPROVED
--    Notifies affected employee when security deposit is set up/approved.
--    Variables: employee_name, amount, date
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.notification_auto_rules (
    id, name, description, trigger_type, is_active, include_affected_user,
    channels, subject_template, message_template, created_at, updated_at
)
SELECT
    gen_random_uuid(),
    'Security deposit approved',
    'Notifies the employee when their security deposit is approved/set up.',
    'deposit_approved',
    true,
    true,
    '{"push": true, "email": true, "sms": false, "whatsapp": false}'::jsonb,
    'Security Deposit Approved: {{employee_name}}',
    'Security deposit (₹{{amount}}) for {{employee_name}} has been approved on {{date}}.',
    NOW(), NOW()
FROM (SELECT 1) AS _dummy
WHERE NOT EXISTS (SELECT 1 FROM public.notification_auto_rules WHERE trigger_type = 'deposit_approved');

INSERT INTO public.notification_auto_rule_roles (rule_id, role_id)
SELECT nar.id, r.id
FROM public.notification_auto_rules nar
CROSS JOIN public.roles r
WHERE nar.trigger_type = 'deposit_approved'
  AND LOWER(TRIM(r.name)) IN ('admin', 'hr manager')
  AND COALESCE(r.is_deleted, false) = false
ON CONFLICT (rule_id, role_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 4) DEPOSIT REFUNDED
--    Notifies affected employee when security deposit is refunded.
--    Variables: employee_name, refund_amount, date
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.notification_auto_rules (
    id, name, description, trigger_type, is_active, include_affected_user,
    channels, subject_template, message_template, created_at, updated_at
)
SELECT
    gen_random_uuid(),
    'Security deposit refunded',
    'Notifies the employee when their security deposit is refunded.',
    'deposit_refunded',
    true,
    true,
    '{"push": true, "email": true, "sms": false, "whatsapp": false}'::jsonb,
    'Security Deposit Refunded: {{employee_name}} – ₹{{refund_amount}}',
    'Security deposit for {{employee_name}} (₹{{refund_amount}}) has been refunded on {{date}}.',
    NOW(), NOW()
FROM (SELECT 1) AS _dummy
WHERE NOT EXISTS (SELECT 1 FROM public.notification_auto_rules WHERE trigger_type = 'deposit_refunded');

INSERT INTO public.notification_auto_rule_roles (rule_id, role_id)
SELECT nar.id, r.id
FROM public.notification_auto_rules nar
CROSS JOIN public.roles r
WHERE nar.trigger_type = 'deposit_refunded'
  AND LOWER(TRIM(r.name)) IN ('admin', 'hr manager')
  AND COALESCE(r.is_deleted, false) = false
ON CONFLICT (rule_id, role_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 5) WITNESS INVITED — rule exists but has no role mappings
--    Add Admin + HR Manager as recipients so notifications actually reach someone.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.notification_auto_rule_roles (rule_id, role_id)
SELECT nar.id, r.id
FROM public.notification_auto_rules nar
CROSS JOIN public.roles r
WHERE nar.trigger_type = 'witness_invited'
  AND LOWER(TRIM(r.name)) IN ('admin', 'hr manager')
  AND COALESCE(r.is_deleted, false) = false
ON CONFLICT (rule_id, role_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 6) Set default_action_url for new rules (if column exists)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'notification_auto_rules'
      AND column_name = 'default_action_url'
  ) THEN
    UPDATE public.notification_auto_rules
    SET default_action_url = '/hr/approvals', updated_at = NOW()
    WHERE trigger_type IN ('contract_accepted', 'onboarding_documents_submitted')
      AND (default_action_url IS NULL OR BTRIM(default_action_url) = '');

    UPDATE public.notification_auto_rules
    SET default_action_url = '/financial', updated_at = NOW()
    WHERE trigger_type IN ('deposit_approved', 'deposit_refunded')
      AND (default_action_url IS NULL OR BTRIM(default_action_url) = '');
  END IF;
END
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 7) Set template_variable_samples for new rules
-- ────────────────────────────────────────────────────────────────────────────
UPDATE public.notification_auto_rules SET
  template_variable_samples = '[{"key":"employee_name","sample":"Rahul Sharma"},{"key":"employee_code","sample":"EMP-042"},{"key":"contract_type","sample":"Employment Agreement"},{"key":"date","sample":"2026-04-08"}]'::jsonb,
  updated_at = NOW()
WHERE trigger_type = 'contract_accepted' AND template_variable_samples IS NULL;

UPDATE public.notification_auto_rules SET
  template_variable_samples = '[{"key":"employee_name","sample":"Rahul Sharma"},{"key":"employee_code","sample":"EMP-042"},{"key":"date","sample":"2026-04-08"},{"key":"documents_count","sample":"5"}]'::jsonb,
  updated_at = NOW()
WHERE trigger_type = 'onboarding_documents_submitted' AND template_variable_samples IS NULL;

UPDATE public.notification_auto_rules SET
  template_variable_samples = '[{"key":"employee_name","sample":"Rahul Sharma"},{"key":"amount","sample":"5000"},{"key":"date","sample":"2026-04-07"}]'::jsonb,
  updated_at = NOW()
WHERE trigger_type = 'deposit_approved' AND template_variable_samples IS NULL;

UPDATE public.notification_auto_rules SET
  template_variable_samples = '[{"key":"employee_name","sample":"Rahul Sharma"},{"key":"refund_amount","sample":"5000"},{"key":"date","sample":"2026-04-07"}]'::jsonb,
  updated_at = NOW()
WHERE trigger_type = 'deposit_refunded' AND template_variable_samples IS NULL;

-- COMMIT; (removed: exec_sql cannot run tx control)
