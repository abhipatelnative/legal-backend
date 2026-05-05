/**
 * BRIDGE FUNCTION FOR MIGRATIONS
 * This allows the migration script to run raw SQL via the Service Role Key.
 */
CREATE OR REPLACE FUNCTION exec_sql(query text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  EXECUTE query;
END;
$$;

-- Security: Ensure only the service_role can use this
REVOKE ALL ON FUNCTION exec_sql(text) FROM public;
REVOKE ALL ON FUNCTION exec_sql(text) FROM anon;
REVOKE ALL ON FUNCTION exec_sql(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION exec_sql(text) TO service_role;



CREATE OR REPLACE FUNCTION exec_sql(query text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN EXECUTE query; END; $$;
GRANT EXECUTE ON FUNCTION exec_sql(text) TO service_role;
