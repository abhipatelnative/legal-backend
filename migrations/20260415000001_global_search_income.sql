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
