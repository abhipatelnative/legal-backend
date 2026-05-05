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
