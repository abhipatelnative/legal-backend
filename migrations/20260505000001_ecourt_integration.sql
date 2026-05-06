-- eCourtsIndia integration: import real court cases by CNR + nightly auto-sync.
--
-- Adds origin tracking columns to existing order_cases / case_hearings tables so
-- imported rows live alongside manually-created ones, and creates two small
-- support tables: court_api_configs (encrypted Bearer token) and court_sync_runs
-- (audit log for the 2 AM cron).

-- ── 1. order_cases: track origin + enable re-sync ───────────────────────────
ALTER TABLE public.order_cases
  ADD COLUMN IF NOT EXISTS cnr_number          TEXT,
  ADD COLUMN IF NOT EXISTS source              TEXT NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS source_external_id  TEXT,
  ADD COLUMN IF NOT EXISTS last_synced_at      TIMESTAMPTZ;

ALTER TABLE public.order_cases
  DROP CONSTRAINT IF EXISTS order_cases_source_check;
ALTER TABLE public.order_cases
  ADD CONSTRAINT order_cases_source_check
  CHECK (source IN ('manual', 'ecourtsindia'));

CREATE UNIQUE INDEX IF NOT EXISTS order_cases_cnr_unique
  ON public.order_cases (cnr_number) WHERE cnr_number IS NOT NULL;

CREATE INDEX IF NOT EXISTS order_cases_source_synced_idx
  ON public.order_cases (source, last_synced_at) WHERE source = 'ecourtsindia';

-- ── 2. case_hearings: track origin + idempotency key for diff-on-resync ────
ALTER TABLE public.case_hearings
  ADD COLUMN IF NOT EXISTS judge_name           TEXT,
  ADD COLUMN IF NOT EXISTS source               TEXT NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS source_external_id   TEXT;

ALTER TABLE public.case_hearings
  DROP CONSTRAINT IF EXISTS case_hearings_source_check;
ALTER TABLE public.case_hearings
  ADD CONSTRAINT case_hearings_source_check
  CHECK (source IN ('manual', 'ecourtsindia'));

CREATE UNIQUE INDEX IF NOT EXISTS case_hearings_source_ext_unique
  ON public.case_hearings (source_external_id) WHERE source_external_id IS NOT NULL;

-- ── 3. court_api_configs: encrypted Bearer token + base URL ────────────────
CREATE TABLE IF NOT EXISTS public.court_api_configs (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider            TEXT NOT NULL UNIQUE,
  api_key             TEXT NOT NULL,
  base_url            TEXT NOT NULL DEFAULT 'https://webapi.ecourtsindia.com/api/partner',
  is_active           BOOLEAN NOT NULL DEFAULT true,
  rate_limit_per_min  INT NOT NULL DEFAULT 30,
  credit_balance_inr  NUMERIC,
  last_test_at        TIMESTAMPTZ,
  last_test_status    TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Rename if a prior version of this migration already created the column as encrypted_api_key.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'court_api_configs'
       AND column_name  = 'encrypted_api_key'
  ) THEN
    ALTER TABLE public.court_api_configs RENAME COLUMN encrypted_api_key TO api_key;
  END IF;
END $$;

-- Heal rows that were saved with the old (wrong) base URL pointing at the
-- public website (which is behind Cloudflare). The real API host is
-- webapi.ecourtsindia.com/api/partner.
UPDATE public.court_api_configs
   SET base_url = 'https://webapi.ecourtsindia.com/api/partner',
       updated_at = now()
 WHERE provider = 'ecourtsindia'
   AND base_url IN (
     'https://ecourtsindia.com/api',
     'https://ecourtsindia.com/api/',
     'https://ecourtsindia.com',
     'https://ecourtsindia.com/'
   );

-- Strip any leading "Bearer " from saved api_key values (some users paste the
-- entire Authorization header value rather than just the token).
UPDATE public.court_api_configs
   SET api_key = regexp_replace(api_key, '^[Bb]earer\s+', ''),
       updated_at = now()
 WHERE provider = 'ecourtsindia'
   AND api_key ~* '^bearer\s+';

ALTER TABLE public.court_api_configs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins manage court api configs" ON public.court_api_configs;
CREATE POLICY "admins manage court api configs" ON public.court_api_configs
  FOR ALL USING (
    EXISTS (
      SELECT 1
        FROM public.user_roles ur
        JOIN public.roles r ON r.id = ur.role_id
       WHERE ur.user_id = auth.uid()
         AND ur.is_active = true
         AND ur.is_deleted = false
         AND r.is_deleted = false
         AND r.name IN ('Admin', 'Super Admin')
    )
  );

-- ── 4. court_sync_runs: audit log for cron + manual re-syncs ───────────────
CREATE TABLE IF NOT EXISTS public.court_sync_runs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_case_id     UUID REFERENCES public.order_cases(id) ON DELETE SET NULL,
  trigger           TEXT NOT NULL,                                -- cron | manual | import
  started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at     TIMESTAMPTZ,
  status            TEXT,                                         -- success | partial | failed
  hearings_added    INT NOT NULL DEFAULT 0,
  error             TEXT
);

CREATE INDEX IF NOT EXISTS court_sync_runs_order_case_idx
  ON public.court_sync_runs (order_case_id, started_at DESC);

CREATE INDEX IF NOT EXISTS court_sync_runs_started_idx
  ON public.court_sync_runs (started_at DESC);

ALTER TABLE public.court_sync_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins read court sync runs" ON public.court_sync_runs;
CREATE POLICY "admins read court sync runs" ON public.court_sync_runs
  FOR SELECT USING (
    EXISTS (
      SELECT 1
        FROM public.user_roles ur
        JOIN public.roles r ON r.id = ur.role_id
       WHERE ur.user_id = auth.uid()
         AND ur.is_active = true
         AND ur.is_deleted = false
         AND r.is_deleted = false
         AND r.name IN ('Admin', 'Super Admin')
    )
  );

DROP POLICY IF EXISTS "service role writes court sync runs" ON public.court_sync_runs;
CREATE POLICY "service role writes court sync runs" ON public.court_sync_runs
  FOR INSERT WITH CHECK (true);
