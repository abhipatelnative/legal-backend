-- Global Search - Stop Synchronous Refresh on Income Writes
-- Migration: 20260430000004
-- Purpose: Drop the AFTER INSERT/UPDATE/DELETE trigger on income_records that
--          synchronously refreshes the entire global_search_index materialized
--          view. As the matview grew, each refresh exceeded statement_timeout
--          and broke the POST /api/incomes endpoint.
--
-- Trade-off accepted: global_search_index becomes stale for income changes
-- until something else refreshes it. Re-architecting the global search
-- refresh strategy is deferred to a separate task.

DROP TRIGGER IF EXISTS trigger_refresh_search_on_income ON public.income_records;
