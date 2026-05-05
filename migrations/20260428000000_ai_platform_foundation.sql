-- AI platform foundation for LegalPrime
-- Creates provider config, feature routing, activity logs, summaries, research sessions,
-- and document ingestion tables used by backend-owned AI workflows.

CREATE TABLE IF NOT EXISTS public.ai_provider_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_key text NOT NULL UNIQUE,
  display_name text NOT NULL,
  base_url text,
  encrypted_api_key text,
  default_model text,
  default_embedding_model text,
  is_enabled boolean NOT NULL DEFAULT false,
  supports_chat boolean NOT NULL DEFAULT true,
  supports_embeddings boolean NOT NULL DEFAULT false,
  supports_grounding boolean NOT NULL DEFAULT false,
  supports_files boolean NOT NULL DEFAULT false,
  supports_offline boolean NOT NULL DEFAULT false,
  timeout_ms integer NOT NULL DEFAULT 60000,
  keep_alive text,
  priority_order integer NOT NULL DEFAULT 100,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_feature_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key text NOT NULL UNIQUE,
  is_enabled boolean NOT NULL DEFAULT true,
  primary_provider text,
  primary_model text,
  fallback_provider text,
  fallback_model text,
  embedding_provider text,
  embedding_model text,
  prompt_version text NOT NULL DEFAULT 'v1',
  max_input_tokens integer,
  temperature numeric(5,2) NOT NULL DEFAULT 0.20,
  json_mode boolean NOT NULL DEFAULT false,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_activity_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key text NOT NULL,
  record_type text,
  record_id uuid,
  provider text,
  model text,
  status text NOT NULL DEFAULT 'pending',
  prompt_version text,
  latency_ms integer,
  input_token_count integer,
  output_token_count integer,
  error_message text,
  response_preview text,
  source_count integer,
  request_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_document_ingestion_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type text NOT NULL,
  source_id uuid,
  service_order_id uuid REFERENCES public.service_orders(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending',
  error_message text,
  chunk_count integer NOT NULL DEFAULT 0,
  embedding_provider text,
  embedding_model text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_document_chunks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type text NOT NULL,
  source_id uuid,
  service_order_id uuid REFERENCES public.service_orders(id) ON DELETE CASCADE,
  chunk_index integer NOT NULL DEFAULT 0,
  content text NOT NULL,
  embedding jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.service_order_document_summaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_order_id uuid NOT NULL REFERENCES public.service_orders(id) ON DELETE CASCADE,
  document_id uuid REFERENCES public.service_order_task_documents(id) ON DELETE CASCADE,
  summary_type text NOT NULL DEFAULT 'document',
  short_summary text NOT NULL,
  key_facts jsonb NOT NULL DEFAULT '[]'::jsonb,
  timeline jsonb NOT NULL DEFAULT '[]'::jsonb,
  risks jsonb NOT NULL DEFAULT '[]'::jsonb,
  action_items jsonb NOT NULL DEFAULT '[]'::jsonb,
  citations jsonb NOT NULL DEFAULT '[]'::jsonb,
  provider text,
  model text,
  prompt_version text NOT NULL DEFAULT 'v1',
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.service_order_summaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_order_id uuid NOT NULL REFERENCES public.service_orders(id) ON DELETE CASCADE,
  version_number integer NOT NULL,
  summary_text text NOT NULL,
  summary_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'current',
  source_snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  provider text,
  model text,
  prompt_version text NOT NULL DEFAULT 'v1',
  generated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(service_order_id, version_number)
);

CREATE TABLE IF NOT EXISTS public.ai_research_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_order_id uuid REFERENCES public.service_orders(id) ON DELETE CASCADE,
  title text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ai_research_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.ai_research_sessions(id) ON DELETE CASCADE,
  role text NOT NULL,
  message_text text,
  answer_text text,
  internal_sources jsonb NOT NULL DEFAULT '[]'::jsonb,
  external_sources jsonb NOT NULL DEFAULT '[]'::jsonb,
  provider text,
  model text,
  prompt_version text NOT NULL DEFAULT 'v1',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_activity_logs_feature_record
  ON public.ai_activity_logs(feature_key, record_type, record_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_document_ingestion_jobs_service_order
  ON public.ai_document_ingestion_jobs(service_order_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_document_chunks_service_order
  ON public.ai_document_chunks(service_order_id, source_type, source_id, chunk_index);

CREATE INDEX IF NOT EXISTS idx_service_order_document_summaries_order_doc
  ON public.service_order_document_summaries(service_order_id, document_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_service_order_summaries_order_status
  ON public.service_order_summaries(service_order_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_research_sessions_service_order
  ON public.ai_research_sessions(service_order_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_research_messages_session
  ON public.ai_research_messages(session_id, created_at ASC);

INSERT INTO public.ai_provider_configs (
  provider_key,
  display_name,
  base_url,
  default_model,
  default_embedding_model,
  supports_chat,
  supports_embeddings,
  supports_grounding,
  supports_files,
  supports_offline,
  timeout_ms,
  keep_alive,
  priority_order
)
VALUES
  ('openai', 'OpenAI', 'https://api.openai.com/v1', 'gpt-5.2', 'text-embedding-3-large', true, true, false, true, false, 60000, null, 10),
  ('anthropic', 'Anthropic', 'https://api.anthropic.com/v1', 'claude-sonnet-4-20250514', null, true, false, false, true, false, 60000, null, 20),
  ('gemini', 'Google Gemini', 'https://generativelanguage.googleapis.com/v1beta', 'gemini-2.0-flash', 'text-embedding-004', true, true, true, true, false, 60000, null, 30),
  ('ollama', 'Ollama', 'http://localhost:11434', 'gemma2:2b', 'embeddinggemma', true, true, false, false, true, 120000, '30m', 40)
ON CONFLICT (provider_key) DO UPDATE
SET
  display_name = EXCLUDED.display_name,
  base_url = COALESCE(public.ai_provider_configs.base_url, EXCLUDED.base_url),
  default_model = COALESCE(public.ai_provider_configs.default_model, EXCLUDED.default_model),
  default_embedding_model = COALESCE(public.ai_provider_configs.default_embedding_model, EXCLUDED.default_embedding_model),
  supports_chat = EXCLUDED.supports_chat,
  supports_embeddings = EXCLUDED.supports_embeddings,
  supports_grounding = EXCLUDED.supports_grounding,
  supports_files = EXCLUDED.supports_files,
  supports_offline = EXCLUDED.supports_offline,
  timeout_ms = COALESCE(public.ai_provider_configs.timeout_ms, EXCLUDED.timeout_ms),
  keep_alive = COALESCE(public.ai_provider_configs.keep_alive, EXCLUDED.keep_alive),
  priority_order = EXCLUDED.priority_order;

INSERT INTO public.ai_feature_settings (
  feature_key,
  is_enabled,
  primary_provider,
  primary_model,
  fallback_provider,
  fallback_model,
  embedding_provider,
  embedding_model,
  prompt_version,
  max_input_tokens,
  temperature,
  json_mode
)
VALUES
  ('template_drafting', true, 'openai', 'gpt-5.2', 'anthropic', 'claude-sonnet-4-20250514', 'openai', 'text-embedding-3-large', 'v1', 24000, 0.20, true),
  ('document_summarizer', true, 'anthropic', 'claude-sonnet-4-20250514', 'ollama', 'gemma2:2b', 'openai', 'text-embedding-3-large', 'v1', 28000, 0.10, true),
  ('service_order_summary', true, 'ollama', 'gemma2:2b', 'anthropic', 'claude-sonnet-4-20250514', 'ollama', 'embeddinggemma', 'v1', 20000, 0.10, true),
  ('stage_task_suggestions', true, 'openai', 'gpt-5.2', 'ollama', 'gemma2:2b', null, null, 'v1', 16000, 0.20, true),
  ('service_master_suggestions', true, 'openai', 'gpt-5.2', 'ollama', 'gemma2:2b', null, null, 'v1', 16000, 0.20, true),
  ('legal_research', true, 'gemini', 'gemini-2.0-flash', 'anthropic', 'claude-sonnet-4-20250514', 'openai', 'text-embedding-3-large', 'v1', 24000, 0.10, true)
ON CONFLICT (feature_key) DO NOTHING;

GRANT ALL ON TABLE public.ai_provider_configs TO service_role;
GRANT ALL ON TABLE public.ai_feature_settings TO service_role;
GRANT ALL ON TABLE public.ai_activity_logs TO service_role;
GRANT ALL ON TABLE public.ai_document_ingestion_jobs TO service_role;
GRANT ALL ON TABLE public.ai_document_chunks TO service_role;
GRANT ALL ON TABLE public.service_order_document_summaries TO service_role;
GRANT ALL ON TABLE public.service_order_summaries TO service_role;
GRANT ALL ON TABLE public.ai_research_sessions TO service_role;
GRANT ALL ON TABLE public.ai_research_messages TO service_role;
