-- Seed the AI feature row for the new SEO Suggestions feature.
-- Routing follows the same global priority chain as every other AI feature:
-- the lowest-priority enabled provider in ai_provider_configs answers, with
-- automatic fallback unless the caller passes providerOverride.

INSERT INTO public.ai_feature_settings (
  feature_key,
  is_enabled,
  prompt_version,
  max_input_tokens,
  temperature,
  json_mode
)
VALUES (
  'seo_suggestions',
  true,
  'v1',
  8000,
  0.30,
  true
)
ON CONFLICT (feature_key) DO NOTHING;
