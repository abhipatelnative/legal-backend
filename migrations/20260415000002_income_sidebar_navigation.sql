-- Income Module - Sidebar Navigation & Permissions
-- Migration: 20260415000002
-- Purpose: Add Income module to sidebar navigation with proper permissions

DO $$
DECLARE
  v_income_module_group_id UUID;
  v_income_module_id UUID;
  v_income_page_id UUID;
  v_admin_role_id UUID;
  v_permission_id UUID;
BEGIN

  -- ============================================================
  -- 1. Get or Create Module Group: "Income"
  -- ============================================================
  SELECT id INTO v_income_module_group_id
  FROM public.app_module_groups
  WHERE slug = 'income'
  LIMIT 1;

  IF v_income_module_group_id IS NULL THEN
    INSERT INTO public.app_module_groups (name, slug, display_order, is_active)
    VALUES ('Income', 'income', 9000, true)
    RETURNING id INTO v_income_module_group_id;
  END IF;

  -- ============================================================
  -- 2. Get or Create Module: "Income Records"
  -- ============================================================
  SELECT id INTO v_income_module_id
  FROM public.app_modules
  WHERE slug = 'income_records'
  LIMIT 1;

  IF v_income_module_id IS NULL THEN
    INSERT INTO public.app_modules (
      name, slug, icon_name, icon_color,
      module_group_id, display_order, is_active
    ) VALUES (
      'Income Records', 'income_records',
      'Wallet', 'text-green-500',
      v_income_module_group_id, 9001, true
    )
    RETURNING id INTO v_income_module_id;
  ELSE
    UPDATE public.app_modules
    SET
      module_group_id = v_income_module_group_id,
      icon_name = 'Wallet',
      icon_color = 'text-green-500',
      is_active = true
    WHERE id = v_income_module_id;
  END IF;

  -- ============================================================
  -- 3. Get or Create Page: "Income List"
  -- ============================================================
  SELECT id INTO v_income_page_id
  FROM public.app_pages
  WHERE url = '/income/income'
  LIMIT 1;

  IF v_income_page_id IS NULL THEN
    INSERT INTO public.app_pages (
      title, url, module_id, module_group_id,
      display_order, is_active
    ) VALUES (
      'Income Records', '/income/income',
      v_income_module_id, v_income_module_group_id,
      9002, true
    )
    RETURNING id INTO v_income_page_id;
  ELSE
    UPDATE public.app_pages
    SET
      module_id = v_income_module_id,
      module_group_id = v_income_module_group_id,
      is_active = true
    WHERE id = v_income_page_id;
  END IF;

  -- ============================================================
  -- 4. Create Permissions for Income Module
  -- ============================================================

  -- View Permission
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE name = 'Income Records (View)') THEN
    INSERT INTO public.permissions (name, module, can_view, is_active)
    VALUES ('Income Records (View)', 'income_records', true, true);
  END IF;

  -- Add Permission
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE name = 'Income Records (Add)') THEN
    INSERT INTO public.permissions (name, module, can_add, is_active)
    VALUES ('Income Records (Add)', 'income_records', true, true);
  END IF;

  -- Edit Permission
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE name = 'Income Records (Edit)') THEN
    INSERT INTO public.permissions (name, module, can_edit, is_active)
    VALUES ('Income Records (Edit)', 'income_records', true, true);
  END IF;

  -- Delete Permission
  IF NOT EXISTS (SELECT 1 FROM public.permissions WHERE name = 'Income Records (Delete)') THEN
    INSERT INTO public.permissions (name, module, can_delete, is_active)
    VALUES ('Income Records (Delete)', 'income_records', true, true);
  END IF;

  -- ============================================================
  -- 5. Assign Permissions to Admin Role
  -- ============================================================
  SELECT id INTO v_admin_role_id
  FROM public.roles
  WHERE name = 'Admin'
  LIMIT 1;

  IF v_admin_role_id IS NOT NULL THEN
    FOR v_permission_id IN
      SELECT p.id FROM public.permissions p
      WHERE p.module = 'income_records'
    LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.role_permissions rp
        WHERE rp.role_id = v_admin_role_id AND rp.permission_id = v_permission_id
      ) THEN
        INSERT INTO public.role_permissions (role_id, permission_id, is_active)
        VALUES (v_admin_role_id, v_permission_id, true);
      END IF;
    END LOOP;
  END IF;

END $$;
