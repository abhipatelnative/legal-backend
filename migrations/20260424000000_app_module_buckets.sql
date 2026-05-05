-- Module-to-storage-bucket mapping for "Module-wise Data Size" Admin Dashboard widget.
-- Extends app_module_tables (DB tables) with a parallel mapping for Supabase Storage buckets.

-- ============================================
-- 1. Mapping table
-- ============================================
CREATE TABLE IF NOT EXISTS public.app_module_buckets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    module_id uuid NOT NULL REFERENCES public.app_modules(id) ON DELETE CASCADE,
    bucket_name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (module_id, bucket_name)
);

CREATE INDEX IF NOT EXISTS idx_app_module_buckets_module_id
    ON public.app_module_buckets(module_id);

-- ============================================
-- 2. RPC: total object size (bytes) grouped by bucket
-- ============================================
CREATE OR REPLACE FUNCTION public.get_bucket_sizes(buckets text[])
RETURNS TABLE(bucket_name text, total_bytes bigint)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT o.bucket_id::text AS bucket_name,
           COALESCE(SUM((o.metadata->>'size')::bigint), 0)::bigint AS total_bytes
    FROM storage.objects o
    WHERE o.bucket_id = ANY(buckets)
    GROUP BY o.bucket_id;
$$;

GRANT EXECUTE ON FUNCTION public.get_bucket_sizes(text[]) TO authenticated, service_role;

-- List of all storage buckets (for the admin UI).
CREATE OR REPLACE FUNCTION public.get_storage_buckets()
RETURNS TABLE(bucket_name text)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT b.id::text AS bucket_name
    FROM storage.buckets b
    ORDER BY b.id;
$$;

GRANT EXECUTE ON FUNCTION public.get_storage_buckets() TO authenticated, service_role;

-- ============================================
-- 3. Seed bucket → module mappings
-- ============================================
DO $$
DECLARE
    seed RECORD;
    v_module_id uuid;
BEGIN
    FOR seed IN
        SELECT * FROM (VALUES
            ('legal_services',     'documents'),
            ('expense_accounting', 'expense-attachments'),
            ('employee_mgmt',      'profile-pictures'),
            ('employee_mgmt',      'employee-documents'),
            ('attendance',         'punch_images'),
            ('hr_masters',         'leave-documents'),
            ('settings',           'company-logos'),
            ('settings',           'cms-knowledge-images')
        ) AS s(module_slug, bucket_name)
    LOOP
        SELECT id INTO v_module_id
        FROM public.app_modules
        WHERE slug = seed.module_slug
        LIMIT 1;

        IF v_module_id IS NULL THEN
            CONTINUE;
        END IF;

        INSERT INTO public.app_module_buckets (module_id, bucket_name)
        VALUES (v_module_id, seed.bucket_name)
        ON CONFLICT (module_id, bucket_name) DO NOTHING;
    END LOOP;
END $$;

-- ============================================
-- 4. Seed additional table → module mappings for previously unmapped tables
--    (complements 20260418000004_app_module_tables.sql)
-- ============================================
DO $$
DECLARE
    seed RECORD;
    v_module_id uuid;
BEGIN
    FOR seed IN
        SELECT * FROM (VALUES
            ('user_access',  'user_nav_preferences'),
            ('user_access',  'impersonation_logs'),
            ('settings',     'app_module_buckets'),
            ('attendance',   'punch_records_archive'),
            ('hr_masters',   'leave_type_roles'),
            ('settings',     'antidigital_djf')
        ) AS s(module_slug, table_name)
    LOOP
        IF to_regclass(format('public.%I', seed.table_name)) IS NULL THEN
            CONTINUE;
        END IF;

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
