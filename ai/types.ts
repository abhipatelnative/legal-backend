import type { SupabaseClient } from "@supabase/supabase-js";

export type AiProviderKey = "openai" | "anthropic" | "gemini" | "ollama";
export type AiFeatureKey =
  | "template_drafting"
  | "document_summarizer"
  | "service_order_summary"
  | "stage_task_suggestions"
  | "service_master_suggestions"
  | "legal_research"
  | "seo_suggestions"
  | "general_chat";

export type JsonRecord = Record<string, unknown>;

export type ProviderConfigRow = {
  id: string;
  provider_key: AiProviderKey;
  display_name: string;
  base_url: string | null;
  encrypted_api_key: string | null;
  default_model: string | null;
  default_embedding_model: string | null;
  is_enabled: boolean;
  supports_chat: boolean;
  supports_embeddings: boolean;
  supports_grounding: boolean;
  supports_files: boolean;
  supports_offline: boolean;
  timeout_ms: number | null;
  keep_alive: string | null;
  priority_order: number | null;
  is_primary: boolean;
  metadata: JsonRecord | null;
  created_at: string;
  updated_at: string;
};

export type FeatureSettingRow = {
  id: string;
  feature_key: AiFeatureKey;
  is_enabled: boolean;
  prompt_version: string;
  max_input_tokens: number | null;
  temperature: number | null;
  json_mode: boolean;
  metadata: JsonRecord | null;
  created_at: string;
  updated_at: string;
};

export type GlobalSettingsRow = {
  id: number;
  embedding_provider_key: AiProviderKey | null;
  embedding_model: string | null;
  updated_at: string;
};

export type ProviderConfig = ProviderConfigRow & {
  apiKey: string | null;
};

export type PromptDefinition = {
  version: string;
  system: string;
  instructions: string;
  responseSchema?: JsonRecord;
};

export type AiAttachmentInput = {
  kind: "text" | "pdf" | "docx" | "image";
  fileName: string;
  mimeType: string;
  text?: string;
  base64?: string;
};

export type AiGenerationRequest = {
  prompt: string;
  system?: string;
  model: string;
  apiKey?: string | null;
  baseUrl?: string | null;
  temperature?: number | null;
  maxTokens?: number | null;
  jsonMode?: boolean;
  grounding?: boolean;
  metadata?: JsonRecord;
  attachments?: AiAttachmentInput[];
  signal?: AbortSignal;
};

export type AiGenerationResponse = {
  provider: AiProviderKey;
  model: string;
  content: string;
  raw?: unknown;
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
  };
};

export type ProviderAdapter = {
  key: AiProviderKey;
  generate(request: AiGenerationRequest): Promise<AiGenerationResponse>;
  test(config: ProviderConfig): Promise<{ ok: boolean; message: string; details?: JsonRecord }>;
};

export type RequestContext = {
  supabase: SupabaseClient;
  supabaseService: SupabaseClient;
  userId?: string | null;
};

export type AiExecutionContext = {
  feature: AiFeatureKey;
  recordType: string;
  recordId?: string | null;
  userId?: string | null;
  providerOverride?: AiProviderKey | null;
};

export type AiExecutionResult = {
  content: string;
  provider: AiProviderKey;
  model: string;
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
  };
  fallbackUsed?: boolean;
};
