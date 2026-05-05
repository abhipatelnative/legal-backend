-- Seed the AI feature row for the global chat assistant.
-- This feature is free-form (json_mode=false) and uses the same global priority
-- chain over enabled providers in ai_provider_configs as every other feature.

INSERT INTO public.ai_feature_settings (
  feature_key,
  is_enabled,
  prompt_version,
  max_input_tokens,
  temperature,
  json_mode
)
VALUES (
  'general_chat',
  true,
  'v1',
  16000,
  0.70,
  false
)
ON CONFLICT (feature_key) DO NOTHING;
