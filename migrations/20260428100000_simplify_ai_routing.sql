-- Simplify AI routing: remove per-feature primary/fallback/embedding columns.
-- Routing is now a single global priority chain over enabled providers in
-- ai_provider_configs (lowest priority_order wins, falls through on failure).
-- Embedding provider/model become a singleton row in ai_global_settings.

ALTER TABLE public.ai_feature_settings
  DROP COLUMN IF EXISTS primary_provider,
  DROP COLUMN IF EXISTS primary_model,
  DROP COLUMN IF EXISTS fallback_provider,
  DROP COLUMN IF EXISTS fallback_model,
  DROP COLUMN IF EXISTS embedding_provider,
  DROP COLUMN IF EXISTS embedding_model;

CREATE TABLE IF NOT EXISTS public.ai_global_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  embedding_provider_key text,
  embedding_model text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.ai_global_settings (id, embedding_provider_key, embedding_model)
VALUES (1, 'openai', 'text-embedding-3-large')
ON CONFLICT (id) DO NOTHING;

GRANT ALL ON TABLE public.ai_global_settings TO service_role;
