import { decryptSecret, encryptSecret } from "./crypto";
import { anthropicAdapter } from "./providers/anthropic";
import { geminiAdapter } from "./providers/gemini";
import { ollamaAdapter } from "./providers/ollama";
import { openAiAdapter } from "./providers/openai";
import type {
  AiAttachmentInput,
  AiExecutionContext,
  AiExecutionResult,
  AiFeatureKey,
  FeatureSettingRow,
  GlobalSettingsRow,
  ProviderAdapter,
  ProviderConfig,
  ProviderConfigRow,
} from "./types";

const adapters: Record<string, ProviderAdapter> = {
  openai: openAiAdapter,
  anthropic: anthropicAdapter,
  gemini: geminiAdapter,
  ollama: ollamaAdapter,
};

export function serializeProviderConfigForClient(row: ProviderConfigRow) {
  return {
    ...row,
    encrypted_api_key: row.encrypted_api_key ? "configured" : null,
    has_api_key: !!row.encrypted_api_key,
  };
}

export function materializeProviderConfig(row: ProviderConfigRow): ProviderConfig {
  return {
    ...row,
    apiKey: decryptSecret(row.encrypted_api_key),
  };
}

export function encryptProviderApiKey(apiKey?: string | null) {
  if (!apiKey?.trim()) {
    return null;
  }
  return encryptSecret(apiKey.trim());
}

export async function getProviderRows(supabaseService: any): Promise<ProviderConfigRow[]> {
  const { data, error } = await supabaseService
    .from("ai_provider_configs")
    .select("*")
    .order("priority_order", { ascending: true });

  if (error) {
    throw error;
  }

  return (data || []) as ProviderConfigRow[];
}

export async function getFeatureSettings(supabaseService: any): Promise<FeatureSettingRow[]> {
  const { data, error } = await supabaseService
    .from("ai_feature_settings")
    .select("*")
    .order("feature_key", { ascending: true });

  if (error) {
    throw error;
  }

  return (data || []) as FeatureSettingRow[];
}

export function getAdapter(provider: string): ProviderAdapter {
  const adapter = adapters[provider];
  if (!adapter) {
    throw new Error(`Unsupported AI provider: ${provider}`);
  }
  return adapter;
}

export function getFeatureSetting(featureRows: FeatureSettingRow[], feature: AiFeatureKey) {
  const setting = featureRows.find((row) => row.feature_key === feature);
  if (!setting) {
    throw new Error(`AI feature setting not found for ${feature}`);
  }
  return setting;
}

export async function getGlobalSettings(supabaseService: any): Promise<GlobalSettingsRow | null> {
  const { data, error } = await supabaseService
    .from("ai_global_settings")
    .select("*")
    .eq("id", 1)
    .maybeSingle();

  if (error) {
    throw error;
  }

  return (data || null) as GlobalSettingsRow | null;
}

export async function executeWithRouting(
  supabaseService: any,
  featureRows: FeatureSettingRow[],
  providerRows: ProviderConfigRow[],
  feature: AiFeatureKey,
  requestBuilder: (config: ProviderConfig, model: string) => Promise<{
    prompt: string;
    system: string;
    temperature?: number | null;
    maxTokens?: number | null;
    jsonMode?: boolean;
    grounding?: boolean;
    metadata?: Record<string, unknown>;
    attachments?: AiAttachmentInput[];
    signal?: AbortSignal;
  }>,
  execution: AiExecutionContext
): Promise<AiExecutionResult> {
  const featureSetting = getFeatureSetting(featureRows, feature);
  if (!featureSetting.is_enabled) {
    throw new Error(`${feature} is disabled.`);
  }

  const enabledProviders = providerRows
    .filter((row) => row.is_enabled)
    .sort((a, b) => {
      if (a.is_primary !== b.is_primary) return a.is_primary ? -1 : 1;
      return (a.priority_order ?? 100) - (b.priority_order ?? 100);
    });

  const candidateProviders = execution.providerOverride
    ? enabledProviders.filter((row) => row.provider_key === execution.providerOverride)
    : enabledProviders;

  if (candidateProviders.length === 0) {
    throw new Error(
      execution.providerOverride
        ? `Selected AI provider "${execution.providerOverride}" is not enabled or not configured.`
        : "No enabled AI provider could satisfy this request."
    );
  }

  let lastError: unknown = null;
  let attemptIndex = 0;

  for (const row of candidateProviders) {
    const config = materializeProviderConfig(row);
    const model = config.default_model;
    if (!model) {
      attemptIndex += 1;
      continue;
    }

    const adapter = getAdapter(config.provider_key);
    const built = await requestBuilder(config, model);

    try {
      const response = await adapter.generate({
        prompt: built.prompt,
        system: built.system,
        model,
        apiKey: config.apiKey,
        baseUrl: config.base_url,
        temperature: built.temperature ?? featureSetting.temperature,
        maxTokens: built.maxTokens ?? featureSetting.max_input_tokens,
        jsonMode: built.jsonMode ?? featureSetting.json_mode,
        grounding: built.grounding,
        metadata: built.metadata,
        attachments: built.attachments,
        signal: built.signal,
      });

      return {
        content: response.content,
        provider: config.provider_key,
        model: response.model,
        usage: response.usage,
        fallbackUsed: attemptIndex > 0,
      };
    } catch (error) {
      lastError = error;
      await supabaseService.from("ai_activity_logs").insert({
        feature_key: execution.feature,
        record_type: execution.recordType,
        record_id: execution.recordId || null,
        provider: config.provider_key,
        model,
        status: "failed",
        prompt_version: featureSetting.prompt_version,
        error_message: error instanceof Error ? error.message : "Unknown AI execution error",
        created_by: execution.userId || null,
      });
      attemptIndex += 1;
    }
  }

  throw lastError instanceof Error ? lastError : new Error("No enabled AI provider could satisfy this request.");
}
