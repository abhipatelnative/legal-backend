-- Add a dedicated is_primary flag to AI providers so admins can pick the
-- primary provider explicitly (instead of inferring it from priority_order).
-- priority_order continues to control fallback order among non-primary
-- providers.

ALTER TABLE public.ai_provider_configs
  ADD COLUMN IF NOT EXISTS is_primary boolean NOT NULL DEFAULT false;

-- Only one provider may be primary at a time.
CREATE UNIQUE INDEX IF NOT EXISTS ai_provider_configs_one_primary_idx
  ON public.ai_provider_configs (is_primary)
  WHERE is_primary = true;

-- Backfill: mark whichever enabled provider currently has the lowest
-- priority_order as the initial primary, so existing behavior is preserved.
WITH first_provider AS (
  SELECT id
  FROM public.ai_provider_configs
  WHERE is_enabled = true
  ORDER BY priority_order NULLS LAST, created_at
  LIMIT 1
)
UPDATE public.ai_provider_configs
SET is_primary = true
WHERE id IN (SELECT id FROM first_provider)
  AND NOT EXISTS (
    SELECT 1 FROM public.ai_provider_configs WHERE is_primary = true
  );
