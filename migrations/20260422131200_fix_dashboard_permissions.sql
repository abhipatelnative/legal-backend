-- ============================================================================
-- Navigation: Dashboard Permissions and Page Binding
-- Fixes visibility for Admin, HR, and Manager dashboards.
-- ============================================================================

-- BEGIN; (Removed as transaction management is handled by the execution bridge)

-- 1. Ensure Permissions exist with correct visibility flag
INSERT INTO public.permissions (name, module, can_view, description)
VALUES 
    ('Admin Dashboard', 'dashboard', true, 'Access to the Admin dashboard'),
    ('HR Dashboard', 'hr_dashboard', true, 'Access to the HR dashboard'),
    ('Manager Dashboard', 'manager_dashboard', true, 'Access to the Manager dashboard')
ON CONFLICT (name) DO UPDATE 
SET module = EXCLUDED.module, can_view = true;

-- 2. Ensure App Pages are active, correctly linked, and have resource keys
-- This ensures 'canAccess' in the frontend can find these pages.
UPDATE public.app_pages 
SET is_active = true, 
    resource_key = CASE 
        WHEN url = '/dashboard' THEN 'dashboard'
        WHEN url = '/hr-dashboard' THEN 'hr_dashboard'
        WHEN url = '/manager-dashboard' THEN 'manager_dashboard'
    END,
    permission_id = (SELECT id FROM public.permissions WHERE module = CASE 
        WHEN url = '/dashboard' THEN 'dashboard'
        WHEN url = '/hr-dashboard' THEN 'hr_dashboard'
        WHEN url = '/manager-dashboard' THEN 'manager_dashboard'
    END LIMIT 1)
WHERE url IN ('/dashboard', '/hr-dashboard', '/manager-dashboard');

-- 3. Assign Permissions to relevant Roles
DO $$
DECLARE
    v_admin_role_id UUID;
    v_hr_role_id UUID;
    v_perm_dashboard UUID;
    v_perm_hr UUID;
    v_perm_manager UUID;
BEGIN
    -- Get Role IDs
    SELECT id INTO v_admin_role_id FROM public.roles WHERE name = 'Admin';
    SELECT id INTO v_hr_role_id FROM public.roles WHERE name = 'HR Manager';

    -- Get Permission IDs
    SELECT id INTO v_perm_dashboard FROM public.permissions WHERE module = 'dashboard' LIMIT 1;
    SELECT id INTO v_perm_hr FROM public.permissions WHERE module = 'hr_dashboard' LIMIT 1;
    SELECT id INTO v_perm_manager FROM public.permissions WHERE module = 'manager_dashboard' LIMIT 1;

    -- Assign to Admin (all 3)
    IF v_admin_role_id IS NOT NULL THEN
        INSERT INTO public.role_permissions (role_id, permission_id, is_active)
        VALUES 
            (v_admin_role_id, v_perm_dashboard, true),
            (v_admin_role_id, v_perm_hr, true),
            (v_admin_role_id, v_perm_manager, true)
        ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = true;
    END IF;

    -- Assign to HR Manager (HR Dashboard only)
    IF v_hr_role_id IS NOT NULL THEN
        INSERT INTO public.role_permissions (role_id, permission_id, is_active)
        VALUES (v_hr_role_id, v_perm_hr, true)
        ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = true;
    END IF;
END $$;

-- 4. Additional Visibility Fixes (Found via diagnostics)
-- Fixes "Hearings" typo and adds missing Admin links for Attendance, Profile, and Invoice Templates.

-- Fix typo in app_pages before linking
UPDATE public.app_pages 
SET resource_key = 'case_matter_hearings' 
WHERE resource_key = 'case_matter_hearingss';

-- Create missing permissions
INSERT INTO public.permissions (name, module, can_view, description)
VALUES 
    ('Invoice Templates (View)', 'masters_invoice_templates', true, 'Access to Invoice Templates'),
    ('My Contract (View)',      'my_contract',               true, 'Access to personal contract'),
    ('Manual Attendance (View)', 'attendance',                true, 'Access to Manual Attendance'),
    ('My Profile (View)',        'my_profile',               true, 'Access to personal profile'),
    ('Hearings (View)',          'case_matter_hearings',      true, 'Access to Case Matter > Hearings')
ON CONFLICT (name) DO UPDATE SET can_view = true, module = EXCLUDED.module;

-- Link these to the Admin role
DO $$
DECLARE
    v_admin_role_id UUID;
BEGIN
    SELECT id INTO v_admin_role_id FROM public.roles WHERE name = 'Admin';

    IF v_admin_role_id IS NOT NULL THEN
        INSERT INTO public.role_permissions (role_id, permission_id, is_active)
        SELECT v_admin_role_id, id, true 
        FROM public.permissions 
        WHERE module IN (
            'masters_invoice_templates', 
            'my_contract', 
            'attendance', 
            'my_profile',
            'case_matter_hearings'
        )
        ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = true;
    END IF;
END $$;

-- COMMIT; (Removed as transaction management is handled by the execution bridge)
