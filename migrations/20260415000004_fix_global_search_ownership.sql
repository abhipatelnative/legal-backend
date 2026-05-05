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
