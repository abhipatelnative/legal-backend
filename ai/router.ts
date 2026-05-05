import { Router } from "express";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const multer = require("multer");
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "crypto";

import { SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "../config/credentials";
import { buildFeatureContext } from "./context-builders";
import { reindexServiceOrderDocuments } from "./document-ingestion";
import { detectKind, parseAttachment } from "./attachment-parser";
import { getPromptDefinition } from "./prompt-loader";
import {
  encryptProviderApiKey,
  executeWithRouting,
  getAdapter,
  getFeatureSettings,
  getGlobalSettings,
  getProviderRows,
  materializeProviderConfig,
  serializeProviderConfigForClient,
} from "./provider-registry";
import { buildResponsePreview, stripMarkdownCodeFence, tryParseJson } from "./response-normalizers";
import { getDocumentChunksForServiceOrder } from "./retrieval";
import { buildSourceFingerprint } from "./source-fingerprint";
import type { AiAttachmentInput, AiFeatureKey, FeatureSettingRow, ProviderConfigRow } from "./types";
import { validateFeatureOutput } from "./validators";

const VISION_CAPABLE_PROVIDERS = new Set(["openai", "anthropic", "gemini"]);
const ATTACHMENTS_BUCKET = "ai-chat-attachments";
const ATTACHMENT_TEXT_BUDGET = 6000;
const MAX_CHAT_HISTORY_TURNS = 32;
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
const uploadAttachment = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_ATTACHMENT_BYTES, files: 1 },
});

function sanitizeFileName(name: string) {
  return (name || "file").replace(/[^\w.\-() ]+/g, "_").slice(0, 120);
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function asUuidOrNull(value: unknown): string | null {
  return typeof value === "string" && UUID_REGEX.test(value) ? value : null;
}

async function loadAttachmentsForPrompt(
  attachmentIds: string[],
  ownerUserId: string,
): Promise<{
  rows: Array<{
    id: string;
    file_name: string;
    mime_type: string;
    kind: string;
    parsed_text: string | null;
    parse_status: string;
    storage_path: string;
    byte_size: number;
  }>;
  textBlock: string;
  imagePayload: AiAttachmentInput[];
  totalBytes: number;
}> {
  if (attachmentIds.length === 0) {
    return { rows: [], textBlock: "", imagePayload: [], totalBytes: 0 };
  }

  const { data: rows, error } = await supabaseService
    .from("ai_chat_attachments")
    .select("id, file_name, mime_type, kind, parsed_text, parse_status, storage_path, byte_size, created_by")
    .in("id", attachmentIds);

  if (error) {
    throw new Error(`Failed to load attachments: ${error.message}`);
  }

  const owned = (rows || []).filter((r: any) => r.created_by === ownerUserId);
  if (owned.length !== attachmentIds.length) {
    throw new Error("One or more attachments are not owned by the requesting user.");
  }

  const blocks: string[] = [];
  const imagePayload: AiAttachmentInput[] = [];
  let totalBytes = 0;

  owned.forEach((row: any, index: number) => {
    totalBytes += row.byte_size || 0;
    if (row.kind === "image") return;
    const text = (row.parsed_text || "").trim();
    if (!text) {
      blocks.push(`[${index + 1}] ${row.file_name} (${row.kind}) — no text could be extracted.`);
      return;
    }
    const truncated = text.length > ATTACHMENT_TEXT_BUDGET
      ? `${text.slice(0, ATTACHMENT_TEXT_BUDGET)}\n…[truncated ${text.length - ATTACHMENT_TEXT_BUDGET} chars]`
      : text;
    blocks.push(`[${index + 1}] ${row.file_name} (${row.kind})\n${truncated}`);
  });

  for (const row of owned) {
    if (row.kind !== "image") continue;
    const { data: blob, error: dlErr } = await supabaseService.storage
      .from(ATTACHMENTS_BUCKET)
      .download(row.storage_path);
    if (dlErr || !blob) continue;
    const ab = await (blob as any).arrayBuffer();
    const base64 = Buffer.from(ab).toString("base64");
    imagePayload.push({
      kind: "image",
      fileName: row.file_name,
      mimeType: row.mime_type,
      base64,
    });
  }

  const textBlock = blocks.length > 0
    ? `\n\n=== Attached files ===\n${blocks.join("\n\n")}\n=== end attachments ===\n`
    : "";

  return { rows: owned, textBlock, imagePayload, totalBytes };
}

async function ensureSessionOwned(sessionId: string, userId: string) {
  const { data, error } = await supabaseService
    .from("ai_chat_sessions")
    .select("id, created_by, title")
    .eq("id", sessionId)
    .maybeSingle();
  if (error) throw error;
  if (!data || data.created_by !== userId) {
    return null;
  }
  return data as { id: string; created_by: string; title: string };
}

function deriveSessionTitle(message: string) {
  const trimmed = (message || "").trim().replace(/\s+/g, " ");
  return trimmed.length <= 60 ? trimmed : `${trimmed.slice(0, 57)}…`;
}

const router = Router();
const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function getUserId(req: any) {
  return req.body?.userId || req.query?.userId || null;
}

function bulletList(items: unknown): string[] {
  if (!Array.isArray(items)) return [];
  return items
    .map((item) => {
      if (typeof item === "string") return item.trim();
      if (item && typeof item === "object") {
        const obj = item as Record<string, unknown>;
        return String(obj.text || obj.title || obj.name || JSON.stringify(obj));
      }
      return String(item ?? "").trim();
    })
    .filter((entry) => entry.length > 0);
}

function buildServiceOrderSummaryText(parsed: Record<string, unknown>): string {
  const sections: string[] = [];

  const overview = typeof parsed.overview === "string" ? parsed.overview.trim() : "";
  if (overview) {
    sections.push(overview);
  }

  const currentStage = typeof parsed.current_stage === "string" ? parsed.current_stage.trim() : "";
  if (currentStage && currentStage.toLowerCase() !== "not specified") {
    sections.push(`Current stage: ${currentStage}`);
  }

  const renderList = (label: string, items: string[]) => {
    if (items.length === 0) return;
    sections.push(`${label}:\n${items.map((item) => `- ${item}`).join("\n")}`);
  };

  renderList("Completed", bulletList(parsed.completed_items));
  renderList("Pending", bulletList(parsed.pending_items));
  renderList("Hearings", bulletList(parsed.hearings));
  renderList("Documents", bulletList(parsed.documents_status));
  renderList("Risks / gaps", bulletList(parsed.risks_or_gaps));
  renderList("Recommended next steps", bulletList(parsed.recommended_next_steps));

  if (sections.length === 0) {
    return "Summary generated, but no details were captured.";
  }

  return sections.join("\n\n");
}

async function loadConfigs() {
  const [providerRows, featureRows] = await Promise.all([
    getProviderRows(supabaseService),
    getFeatureSettings(supabaseService),
  ]);

  return { providerRows, featureRows };
}

async function logSuccess(
  feature: AiFeatureKey,
  recordType: string,
  recordId: string | null,
  result: { provider: string; model: string; content: string; usage?: { inputTokens?: number; outputTokens?: number } },
  promptVersion: string,
  userId?: string | null,
  metadata: Record<string, unknown> = {}
) {
  await supabaseService.from("ai_activity_logs").insert({
    feature_key: feature,
    record_type: recordType,
    record_id: recordId,
    provider: result.provider,
    model: result.model,
    status: "completed",
    prompt_version: promptVersion,
    input_token_count: result.usage?.inputTokens || null,
    output_token_count: result.usage?.outputTokens || null,
    response_preview: buildResponsePreview(result.content),
    created_by: userId || null,
    request_metadata: metadata,
  });
}

async function runFeature(
  feature: AiFeatureKey,
  payload: Record<string, any>,
  recordType: string,
  recordId?: string | null
) {
  const { providerRows, featureRows } = await loadConfigs();
  const promptDefinition = getPromptDefinition(feature);
  const context = await buildFeatureContext(supabaseService, feature, payload);

  const rawOverride = payload.providerOverride ?? payload.provider_key ?? null;
  const allowedKeys = ["openai", "anthropic", "gemini", "ollama"] as const;
  const providerOverride =
    typeof rawOverride === "string" &&
    (allowedKeys as readonly string[]).includes(rawOverride.toLowerCase())
      ? (rawOverride.toLowerCase() as (typeof allowedKeys)[number])
      : null;

  const result = await executeWithRouting(
    supabaseService,
    featureRows,
    providerRows,
    feature,
    async (config, model) => ({
      prompt: `${promptDefinition.instructions}\n\nContext:\n${JSON.stringify(context, null, 2)}`,
      system: promptDefinition.system,
      temperature: payload.temperature ?? null,
      maxTokens: payload.maxTokens ?? null,
      jsonMode: true,
      grounding: feature === "legal_research" && !!config.supports_grounding,
      metadata: {
        keepAlive: config.keep_alive,
      },
    }),
    {
      feature,
      recordType,
      recordId,
      userId: payload.userId,
      providerOverride,
    }
  );

  const validation = validateFeatureOutput(feature, result.content);
  if (!validation.valid) {
    throw new Error(validation.message || "Invalid AI output");
  }

  await logSuccess(feature, recordType, recordId || null, result, promptDefinition.version, payload.userId, {
    fallbackUsed: !!result.fallbackUsed,
  });

  return {
    promptVersion: promptDefinition.version,
    result,
  };
}

router.get("/api/ai/providers", async (_req, res) => {
  try {
    const rows = await getProviderRows(supabaseService);
    res.status(200).json({
      success: true,
      providers: rows.map(serializeProviderConfigForClient),
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch AI providers." });
  }
});

router.post("/api/ai/providers", async (req, res) => {
  try {
    const providerKey = String(req.body?.provider_key || req.body?.providerKey || "").toLowerCase();
    if (!providerKey) {
      return res.status(400).json({ success: false, message: "provider_key is required." });
    }

    const wantsPrimary = req.body?.is_primary === true;

    const payload: Record<string, unknown> = {
      provider_key: providerKey,
      display_name: req.body?.display_name || req.body?.displayName || providerKey,
      base_url: req.body?.base_url ?? req.body?.baseUrl ?? null,
      encrypted_api_key: req.body?.api_key ? encryptProviderApiKey(req.body.api_key) : undefined,
      default_model: req.body?.default_model ?? req.body?.defaultModel ?? null,
      default_embedding_model: req.body?.default_embedding_model ?? req.body?.defaultEmbeddingModel ?? null,
      is_enabled: !!req.body?.is_enabled,
      supports_embeddings: !!req.body?.supports_embeddings,
      supports_grounding: !!req.body?.supports_grounding,
      supports_files: !!req.body?.supports_files,
      supports_offline: !!req.body?.supports_offline,
      timeout_ms: req.body?.timeout_ms ?? 60000,
      keep_alive: req.body?.keep_alive ?? req.body?.keepAlive ?? null,
      priority_order: req.body?.priority_order ?? 100,
      updated_at: new Date().toISOString(),
    };

    if (req.body?.is_primary !== undefined) {
      payload.is_primary = wantsPrimary;
    }

    const updatePayload = Object.fromEntries(
      Object.entries(payload).filter(([, value]) => value !== undefined)
    );

    // Enforce single-primary invariant: clear is_primary on every other row
    // before upserting this one as primary. The partial unique index would
    // reject the upsert otherwise.
    if (wantsPrimary) {
      const { error: clearError } = await (supabaseService as any)
        .from("ai_provider_configs")
        .update({ is_primary: false, updated_at: new Date().toISOString() })
        .neq("provider_key", providerKey);
      if (clearError) {
        throw clearError;
      }
    }

    const { data, error } = await (supabaseService as any)
      .from("ai_provider_configs")
      .upsert(updatePayload, { onConflict: "provider_key" })
      .select("*")
      .single();

    if (error) {
      throw error;
    }

    res.status(200).json({
      success: true,
      provider: serializeProviderConfigForClient(data as ProviderConfigRow),
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to save AI provider." });
  }
});

router.post("/api/ai/providers/test", async (req, res) => {
  try {
    const providerKey = String(req.body?.provider_key || req.body?.providerKey || "").toLowerCase();
    if (!providerKey) {
      return res.status(400).json({ success: false, message: "provider_key is required." });
    }

    const rows = await getProviderRows(supabaseService);
    const row = rows.find((item) => item.provider_key === providerKey);
    if (!row) {
      return res.status(404).json({ success: false, message: "AI provider not found." });
    }

    const adapter = getAdapter(providerKey);
    const result = await adapter.test(materializeProviderConfig(row));
    res.status(result.ok ? 200 : 400).json({ success: result.ok, ...result });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "AI provider test failed." });
  }
});

router.get("/api/ai/features", async (_req, res) => {
  try {
    const rows = await getFeatureSettings(supabaseService);
    res.status(200).json({ success: true, features: rows });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch AI features." });
  }
});

router.post("/api/ai/features", async (req, res) => {
  try {
    const featureKey = req.body?.feature_key || req.body?.featureKey;
    if (!featureKey) {
      return res.status(400).json({ success: false, message: "feature_key is required." });
    }

    const payload = {
      feature_key: featureKey,
      is_enabled: req.body?.is_enabled ?? true,
      prompt_version: req.body?.prompt_version ?? "v1",
      max_input_tokens: req.body?.max_input_tokens ?? null,
      temperature: req.body?.temperature ?? 0.2,
      json_mode: req.body?.json_mode ?? false,
      updated_at: new Date().toISOString(),
    };

    const { data, error } = await (supabaseService as any)
      .from("ai_feature_settings")
      .upsert(payload, { onConflict: "feature_key" })
      .select("*")
      .single();

    if (error) {
      throw error;
    }

    res.status(200).json({ success: true, feature: data });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to save AI feature setting." });
  }
});

router.get("/api/ai/global-settings", async (_req, res) => {
  try {
    const row = await getGlobalSettings(supabaseService);
    res.status(200).json({
      success: true,
      settings: row || {
        id: 1,
        embedding_provider_key: null,
        embedding_model: null,
        updated_at: null,
      },
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch AI global settings." });
  }
});

router.post("/api/ai/global-settings", async (req, res) => {
  try {
    const payload = {
      id: 1,
      embedding_provider_key: req.body?.embedding_provider_key ?? null,
      embedding_model: req.body?.embedding_model ?? null,
      updated_at: new Date().toISOString(),
    };

    const { data, error } = await (supabaseService as any)
      .from("ai_global_settings")
      .upsert(payload, { onConflict: "id" })
      .select("*")
      .single();

    if (error) {
      throw error;
    }

    res.status(200).json({ success: true, settings: data });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to save AI global settings." });
  }
});

router.post("/api/ai/service-order-summarize", async (req, res) => {
  try {
    const serviceOrderId = req.body?.serviceOrderId;
    if (!serviceOrderId) {
      return res.status(400).json({ success: false, message: "serviceOrderId is required." });
    }

    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "service_order_summary",
      { ...req.body, userId },
      "service_order",
      serviceOrderId
    );

    const parsed = tryParseJson<Record<string, unknown>>(result.content) || {};
    const summaryText = buildServiceOrderSummaryText(parsed);

    const context = await buildFeatureContext(supabaseService, "service_order_summary", { serviceOrderId });
    const fingerprint = buildSourceFingerprint(context as Record<string, unknown>);

    const { data: latestSummary } = await (supabaseService as any)
      .from("service_order_summaries")
      .select("version_number")
      .eq("service_order_id", serviceOrderId)
      .order("version_number", { ascending: false })
      .limit(1)
      .maybeSingle();

    const nextVersion = (latestSummary?.version_number || 0) + 1;

    await (supabaseService as any)
      .from("service_order_summaries")
      .update({ status: "superseded" })
      .eq("service_order_id", serviceOrderId)
      .eq("status", "current");

    const { data: inserted, error } = await (supabaseService as any)
      .from("service_order_summaries")
      .insert({
        service_order_id: serviceOrderId,
        version_number: nextVersion,
        summary_text: summaryText || "Summary generated.",
        summary_json: parsed,
        status: "current",
        source_snapshot_json: fingerprint,
        provider: result.provider,
        model: result.model,
        prompt_version: promptVersion,
        generated_by: userId,
      })
      .select("*")
      .single();

    if (error) {
      throw error;
    }

    res.status(200).json({
      success: true,
      summary: inserted,
      parsed,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to summarize service order." });
  }
});

router.get("/api/ai/service-order-summaries/:serviceOrderId", async (req, res) => {
  try {
    const { data, error } = await (supabaseService as any)
      .from("service_order_summaries")
      .select("*")
      .eq("service_order_id", req.params.serviceOrderId)
      .order("version_number", { ascending: false });

    if (error) {
      throw error;
    }

    res.status(200).json({ success: true, summaries: data || [] });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch summaries." });
  }
});

router.get("/api/ai/service-order-summaries/:serviceOrderId/:summaryId", async (req, res) => {
  try {
    const { data, error } = await (supabaseService as any)
      .from("service_order_summaries")
      .select("*")
      .eq("service_order_id", req.params.serviceOrderId)
      .eq("id", req.params.summaryId)
      .single();

    if (error) {
      throw error;
    }

    res.status(200).json({ success: true, summary: data });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch summary." });
  }
});

router.post("/api/ai/document-summarizer", async (req, res) => {
  try {
    const serviceOrderId = req.body?.serviceOrderId;
    const userId = getUserId(req);

    const { promptVersion, result } = await runFeature(
      "document_summarizer",
      { ...req.body, userId },
      "service_order_document",
      req.body?.documentId || null
    );

    const parsed = tryParseJson<Record<string, any>>(result.content) || {};

    if (serviceOrderId && req.body?.documentId) {
      await (supabaseService as any).from("service_order_document_summaries").insert({
        service_order_id: serviceOrderId,
        document_id: req.body.documentId,
        summary_type: req.body.summaryType || "document",
        short_summary: parsed.short_summary || stripMarkdownCodeFence(result.content),
        key_facts: parsed.key_facts || [],
        timeline: parsed.timeline || [],
        risks: parsed.risks || [],
        action_items: parsed.action_items || [],
        citations: parsed.citations || [],
        provider: result.provider,
        model: result.model,
        prompt_version: promptVersion,
        created_by: userId,
      });
    }

    res.status(200).json({
      success: true,
      summary: parsed,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to summarize document." });
  }
});

router.post("/api/ai/stage-task-suggestions", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "stage_task_suggestions",
      { ...req.body, userId },
      "service_order",
      req.body?.serviceOrderId || null
    );

    res.status(200).json({
      success: true,
      suggestions: tryParseJson(result.content) || result.content,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to generate stage/task suggestions." });
  }
});

router.post("/api/ai/service-master-suggestions", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "service_master_suggestions",
      { ...req.body, userId },
      "service_master",
      req.body?.serviceMasterId || null
    );

    res.status(200).json({
      success: true,
      suggestions: tryParseJson(result.content) || result.content,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to generate service master suggestions." });
  }
});

router.post("/api/ai/template-drafting", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "template_drafting",
      {
        ...req.body,
        userId,
        description: req.body?.instruction || req.body?.description || "Draft a new legal template.",
        toLanguage: undefined,
      },
      "document_template",
      req.body?.templateId || null
    );

    res.status(200).json({
      success: true,
      draft: tryParseJson(result.content) || result.content,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to draft template." });
  }
});

router.post("/api/ai/template-rewrite", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "template_drafting",
      {
        ...req.body,
        userId,
        templateContent: req.body?.selectedHtml || req.body?.templateContent,
        description: req.body?.instruction || "Rewrite the selected template section while preserving placeholders.",
        toLanguage: undefined,
      },
      "document_template",
      req.body?.templateId || null
    );

    res.status(200).json({
      success: true,
      draft: tryParseJson(result.content) || result.content,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to rewrite template." });
  }
});

router.post("/api/ai/template-translate", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "template_drafting",
      {
        ...req.body,
        userId,
        description: `Translate this legal template from ${req.body?.fromLanguage || "the source language"} to ${req.body?.toLanguage || "the target language"} while preserving placeholders and HTML structure.`,
      },
      "document_template",
      req.body?.templateId || null
    );

    res.status(200).json({
      success: true,
      draft: tryParseJson(result.content) || result.content,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to translate template." });
  }
});

router.post("/api/ai/general-chat", async (req, res) => {
  const userId = getUserId(req);
  const promptDefinition = getPromptDefinition("general_chat");
  const userQuestion: string = (req.body?.userQuestion || req.body?.question || "").trim();
  const incomingMessages: Array<{ role: "user" | "assistant"; content: string }> =
    Array.isArray(req.body?.messages) ? req.body.messages : [];
  const attachmentIds: string[] = Array.isArray(req.body?.attachmentIds)
    ? req.body.attachmentIds.filter((id: any) => typeof id === "string" && id.length > 0)
    : [];
  const branchId: string | null = asUuidOrNull(req.body?.branchId);
  const requestedSessionId: string | null = asUuidOrNull(req.body?.sessionId);

  if (!userId) {
    return res.status(401).json({ success: false, message: "User authentication is required." });
  }
  if (!userQuestion) {
    return res.status(400).json({ success: false, message: "userQuestion is required." });
  }

  const rawOverride = req.body?.providerOverride ?? req.body?.provider_key ?? null;
  const allowedKeys = ["openai", "anthropic", "gemini", "ollama"] as const;
  const providerOverride =
    typeof rawOverride === "string" &&
    (allowedKeys as readonly string[]).includes(rawOverride.toLowerCase())
      ? (rawOverride.toLowerCase() as (typeof allowedKeys)[number])
      : null;

  const abortController = new AbortController();
  let aborted = false;
  // NOTE: server-side abort detection via req.on('close') is currently disabled.
  // In our setup it false-fires even with writableEnded/writableFinished/headersSent
  // guards, marking normal turns as "Generation stopped." If the client truly
  // aborts on the frontend, the in-flight fetch to the provider will eventually
  // resolve and its tokens are simply discarded — no user-visible damage.
  // Re-enable cautiously once we can prove the close event represents a real
  // client disconnect in this environment.
  const onClose = () => {
    // eslint-disable-next-line no-console
    console.log(
      "[general-chat] req.close",
      "writableEnded=", res.writableEnded,
      "writableFinished=", res.writableFinished,
      "headersSent=", res.headersSent,
      "destroyed=", res.destroyed,
    );
  };
  req.on("close", onClose);

  let sessionId: string | null = requestedSessionId;
  let userMessageId: string | null = null;

  try {
    const { providerRows, featureRows } = await loadConfigs();

    // 1. Resolve / create session
    let sessionTitle = "New chat";
    if (sessionId) {
      const owned = await ensureSessionOwned(sessionId, userId);
      if (!owned) {
        return res.status(404).json({ success: false, message: "Session not found." });
      }
      sessionTitle = owned.title;
    } else {
      const newTitle = deriveSessionTitle(userQuestion);
      const { data: created, error: createErr } = await supabaseService
        .from("ai_chat_sessions")
        .insert({ created_by: userId, branch_id: branchId, title: newTitle })
        .select("id, title")
        .single();
      if (createErr) throw createErr;
      sessionId = created.id;
      sessionTitle = created.title;
    }

    // 2. Load attachments and verify ownership
    const { rows: attachmentRows, textBlock: attachmentBlock, imagePayload, totalBytes } =
      await loadAttachmentsForPrompt(attachmentIds, userId);
    const hasImages = imagePayload.length > 0;

    // 3. If images present, gate provider override to vision-capable
    if (hasImages && providerOverride && !VISION_CAPABLE_PROVIDERS.has(providerOverride)) {
      return res.status(400).json({
        success: false,
        message: `The selected provider "${providerOverride}" cannot process images. Switch to OpenAI, Anthropic, or Gemini, or remove the image.`,
      });
    }
    let effectiveOverride = providerOverride;
    if (hasImages && !effectiveOverride) {
      const visionFirst = providerRows.find((p) => p.is_enabled && VISION_CAPABLE_PROVIDERS.has(p.provider_key));
      if (visionFirst) {
        effectiveOverride = visionFirst.provider_key;
      }
    }

    // 4. Persist the user message (we have the id so attachments can be linked)
    const { data: userRow, error: userInsertErr } = await supabaseService
      .from("ai_chat_messages")
      .insert({ session_id: sessionId, role: "user", content: userQuestion, status: "completed" })
      .select("id")
      .single();
    if (userInsertErr) throw userInsertErr;
    userMessageId = userRow.id;

    if (attachmentIds.length > 0) {
      await supabaseService
        .from("ai_chat_attachments")
        .update({ message_id: userMessageId, session_id: sessionId })
        .in("id", attachmentIds);
    }

    // 5. Build conversation context. Prefer DB history (canonical) for established sessions.
    let priorMessages: Array<{ role: string; content: string }> = [];
    if (requestedSessionId) {
      const { data: dbHistory } = await supabaseService
        .from("ai_chat_messages")
        .select("role, content, status, id")
        .eq("session_id", sessionId)
        .order("created_at", { ascending: true });
      priorMessages = (dbHistory || [])
        .filter((m: any) => m.id !== userMessageId && m.status !== "aborted" && (m.content || "").trim())
        .map((m: any) => ({ role: m.role, content: m.content }));
    } else {
      // Fresh session — use what client supplied (e.g. for a one-shot migration).
      priorMessages = incomingMessages.filter((m) => m && m.content);
    }
    if (priorMessages.length > MAX_CHAT_HISTORY_TURNS * 2) {
      priorMessages = priorMessages.slice(-MAX_CHAT_HISTORY_TURNS * 2);
    }

    // 6. Workspace search context (preserved from original handler)
    const authHeader = String(req.headers.authorization || "");
    const jwt = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : null;
    let workspaceContext = "";
    let searchHits = 0;
    if (jwt && userQuestion.length >= 2 && !hasImages) {
      try {
        const userScopedSupabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
          global: { headers: { Authorization: `Bearer ${jwt}` } },
          auth: { persistSession: false, autoRefreshToken: false },
        });
        const truncatedQuery = userQuestion.length > 500 ? userQuestion.slice(0, 500) : userQuestion;
        const { data: rows, error: searchError } = await (userScopedSupabase as any).rpc("global_search", {
          p_query: truncatedQuery,
          p_branch_id: branchId,
          p_limit: 15,
        });
        if (!searchError && Array.isArray(rows) && rows.length > 0) {
          searchHits = rows.length;
          const formatted = rows
            .slice(0, 15)
            .map((r: any, i: number) => {
              const group = r.entity_group || r.entity_type || "Record";
              const title = r.title || "Untitled";
              const subtitle = r.subtitle ? ` — ${r.subtitle}` : "";
              return `${i + 1}. [${group}] ${title}${subtitle}`;
            })
            .join("\n");
          workspaceContext = `\n\n=== Workspace search results (top ${rows.length} matches for "${truncatedQuery}") ===\n${formatted}\n=== end results ===\n`;
        }
      } catch {
        // Workspace search failure never blocks chat.
      }
    }

    const conversationLines: string[] = [];
    for (const msg of priorMessages) {
      if (!msg?.content) continue;
      conversationLines.push(`${msg.role === "assistant" ? "Assistant" : "User"}: ${msg.content}`);
    }
    conversationLines.push(`User: ${userQuestion}`);
    conversationLines.push("Assistant:");
    const conversation = conversationLines.join("\n\n");

    // 7. Run AI with abort signal
    const result = await executeWithRouting(
      supabaseService,
      featureRows,
      providerRows,
      "general_chat",
      async () => ({
        prompt: `${promptDefinition.instructions}${workspaceContext}${attachmentBlock}\n\n${conversation}`,
        system: promptDefinition.system,
        temperature: req.body?.temperature ?? null,
        maxTokens: req.body?.maxTokens ?? null,
        jsonMode: false,
        grounding: false,
        metadata: {},
        attachments: imagePayload,
        signal: abortController.signal,
      }),
      {
        feature: "general_chat",
        recordType: "global_chat",
        recordId: null,
        userId,
        providerOverride: effectiveOverride,
      },
    );

    const cleaned = result.content.replace(/^\s*Assistant:\s*/i, "").trim();

    // 8. Persist assistant message
    const { data: assistantRow } = await supabaseService
      .from("ai_chat_messages")
      .insert({
        session_id: sessionId,
        role: "assistant",
        content: cleaned || "(No response returned)",
        provider: result.provider,
        model: result.model,
        status: "completed",
      })
      .select("id")
      .single();

    await supabaseService.from("ai_activity_logs").insert({
      feature_key: "general_chat",
      record_type: "global_chat",
      record_id: null,
      provider: result.provider,
      model: result.model,
      status: "completed",
      prompt_version: promptDefinition.version,
      response_preview: buildResponsePreview(cleaned),
      created_by: userId || null,
      request_metadata: {
        fallbackUsed: !!result.fallbackUsed,
        searchHits,
        sessionId,
        attachmentCount: attachmentRows.length,
        attachmentBytes: totalBytes,
        hasImages,
      },
    });

    return res.status(200).json({
      success: true,
      sessionId,
      sessionTitle,
      messageId: assistantRow?.id || null,
      answer: cleaned,
      provider: result.provider,
      model: result.model,
      promptVersion: promptDefinition.version,
    });
  } catch (error: any) {
    // Only trust our own close-handler flag — third-party AbortError-shaped
    // errors (Ollama socket resets, fetch network errors) are NOT user aborts.
    const wasAborted = aborted;
    if (!wasAborted) {
      // eslint-disable-next-line no-console
      console.error("[general-chat] failed:", error?.name, error?.type, error?.message);
    }
    if (wasAborted && sessionId) {
      try {
        await supabaseService.from("ai_chat_messages").insert({
          session_id: sessionId,
          role: "assistant",
          content: "Generation stopped.",
          status: "aborted",
        });
        await supabaseService.from("ai_activity_logs").insert({
          feature_key: "general_chat",
          record_type: "global_chat",
          record_id: null,
          status: "failed",
          prompt_version: promptDefinition.version,
          error_message: "aborted_by_client",
          created_by: userId || null,
          request_metadata: { sessionId, aborted: true },
        });
      } catch {
        // best-effort
      }
      if (!res.writableEnded) {
        return res.status(200).json({ success: false, aborted: true, sessionId });
      }
      return;
    }
    if (!res.writableEnded) {
      return res.status(500).json({ success: false, message: error?.message || "Chat failed." });
    }
  } finally {
    req.off("close", onClose);
  }
});

// ===== Global chat session management =====

router.get("/api/ai/chat/sessions", async (req, res) => {
  try {
    const userId = getUserId(req);
    if (!userId) return res.status(401).json({ success: false, message: "User authentication is required." });
    const { data, error } = await supabaseService
      .from("ai_chat_sessions")
      .select("id, title, is_archived, last_message_at, created_at, updated_at")
      .eq("created_by", userId)
      .order("last_message_at", { ascending: false, nullsFirst: false })
      .order("created_at", { ascending: false });
    if (error) throw error;
    res.status(200).json({ success: true, sessions: data || [] });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to load sessions." });
  }
});

router.get("/api/ai/chat/sessions/:id", async (req, res) => {
  try {
    const userId = getUserId(req);
    const sessionId = req.params.id;
    if (!userId) return res.status(401).json({ success: false, message: "User authentication is required." });

    const owned = await ensureSessionOwned(sessionId, userId);
    if (!owned) return res.status(404).json({ success: false, message: "Session not found." });

    const [{ data: session }, { data: messages }, { data: attachments }] = await Promise.all([
      supabaseService.from("ai_chat_sessions").select("*").eq("id", sessionId).single(),
      supabaseService
        .from("ai_chat_messages")
        .select("*")
        .eq("session_id", sessionId)
        .order("created_at", { ascending: true }),
      supabaseService
        .from("ai_chat_attachments")
        .select("id, message_id, file_name, mime_type, kind, parse_status, byte_size, storage_path")
        .eq("session_id", sessionId),
    ]);

    const previewByAttachmentId = new Map<string, string>();
    for (const att of attachments || []) {
      if (att.kind === "image") {
        try {
          const { data: signed } = await supabaseService.storage
            .from(ATTACHMENTS_BUCKET)
            .createSignedUrl(att.storage_path, 60 * 60);
          previewByAttachmentId.set(att.id, signed?.signedUrl || "");
        } catch {
          // ignore
        }
      }
    }

    const decoratedAttachments = (attachments || []).map((att: any) => ({
      id: att.id,
      messageId: att.message_id,
      fileName: att.file_name,
      mimeType: att.mime_type,
      kind: att.kind,
      parseStatus: att.parse_status,
      byteSize: att.byte_size,
      previewUrl: previewByAttachmentId.get(att.id) || null,
    }));

    res.status(200).json({
      success: true,
      session,
      messages: messages || [],
      attachments: decoratedAttachments,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to load session." });
  }
});

router.patch("/api/ai/chat/sessions/:id", async (req, res) => {
  try {
    const userId = getUserId(req);
    const sessionId = req.params.id;
    if (!userId) return res.status(401).json({ success: false, message: "User authentication is required." });

    const owned = await ensureSessionOwned(sessionId, userId);
    if (!owned) return res.status(404).json({ success: false, message: "Session not found." });

    const updates: Record<string, unknown> = {};
    if (typeof req.body?.title === "string") {
      updates.title = req.body.title.trim().slice(0, 120) || "Untitled";
    }
    if (typeof req.body?.is_archived === "boolean") {
      updates.is_archived = req.body.is_archived;
    }
    if (Object.keys(updates).length === 0) {
      return res.status(400).json({ success: false, message: "Nothing to update." });
    }
    updates.updated_at = new Date().toISOString();

    const { data, error } = await supabaseService
      .from("ai_chat_sessions")
      .update(updates)
      .eq("id", sessionId)
      .select("*")
      .single();
    if (error) throw error;
    res.status(200).json({ success: true, session: data });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to update session." });
  }
});

router.delete("/api/ai/chat/sessions/:id", async (req, res) => {
  try {
    const userId = getUserId(req);
    const sessionId = req.params.id;
    if (!userId) return res.status(401).json({ success: false, message: "User authentication is required." });

    const owned = await ensureSessionOwned(sessionId, userId);
    if (!owned) return res.status(404).json({ success: false, message: "Session not found." });

    const { data: atts } = await supabaseService
      .from("ai_chat_attachments")
      .select("storage_path")
      .eq("session_id", sessionId);
    const paths = (atts || []).map((a: any) => a.storage_path).filter(Boolean);
    if (paths.length > 0) {
      try {
        await supabaseService.storage.from(ATTACHMENTS_BUCKET).remove(paths);
      } catch {
        // best-effort
      }
    }
    const { error } = await supabaseService.from("ai_chat_sessions").delete().eq("id", sessionId);
    if (error) throw error;
    res.status(200).json({ success: true });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to delete session." });
  }
});

router.post("/api/ai/chat/attachments", uploadAttachment.single("file"), async (req: any, res) => {
  try {
    const userId = req.body?.userId || req.query?.userId;
    if (!userId) return res.status(401).json({ success: false, message: "User authentication is required." });
    if (!req.file) return res.status(400).json({ success: false, message: "No file uploaded." });
    const file = req.file;

    const kind = detectKind(file.mimetype);
    if (kind === "other") {
      return res.status(400).json({
        success: false,
        message: `Unsupported file type: ${file.mimetype}. Allowed: text, PDF, DOCX, images.`,
      });
    }

    const safeName = sanitizeFileName(file.originalname || "file");
    const storagePath = `${userId}/${randomUUID()}-${safeName}`;

    const { error: uploadErr } = await supabaseService.storage
      .from(ATTACHMENTS_BUCKET)
      .upload(storagePath, file.buffer, {
        contentType: file.mimetype,
        upsert: false,
      });
    if (uploadErr) throw uploadErr;

    const parsed = await parseAttachment(file.buffer, file.mimetype);

    const { data: row, error: insertErr } = await supabaseService
      .from("ai_chat_attachments")
      .insert({
        message_id: null,
        session_id: null,
        created_by: userId,
        file_name: safeName,
        mime_type: file.mimetype,
        byte_size: file.size,
        storage_path: storagePath,
        kind: parsed.kind,
        parsed_text: parsed.text || null,
        parse_status: parsed.status,
        parse_error: parsed.error || null,
      })
      .select("id, file_name, mime_type, byte_size, kind, parse_status, parse_error")
      .single();
    if (insertErr) throw insertErr;

    res.status(200).json({
      success: true,
      attachment: {
        id: row.id,
        fileName: row.file_name,
        mimeType: row.mime_type,
        byteSize: row.byte_size,
        kind: row.kind,
        parseStatus: row.parse_status,
        parseError: row.parse_error,
      },
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Attachment upload failed." });
  }
});

router.delete("/api/ai/chat/attachments/:id", async (req, res) => {
  try {
    const userId = getUserId(req);
    const id = req.params.id;
    if (!userId) return res.status(401).json({ success: false, message: "User authentication is required." });

    const { data: row } = await supabaseService
      .from("ai_chat_attachments")
      .select("id, storage_path, created_by, message_id")
      .eq("id", id)
      .maybeSingle();
    if (!row || row.created_by !== userId) {
      return res.status(404).json({ success: false, message: "Attachment not found." });
    }
    if (row.message_id) {
      return res.status(400).json({ success: false, message: "Attachment is already linked to a message." });
    }

    try {
      await supabaseService.storage.from(ATTACHMENTS_BUCKET).remove([row.storage_path]);
    } catch {
      // best-effort
    }
    await supabaseService.from("ai_chat_attachments").delete().eq("id", id);
    res.status(200).json({ success: true });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to delete attachment." });
  }
});

router.post("/api/ai/seo-suggestions", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "seo_suggestions",
      { ...req.body, userId },
      "cms_website",
      req.body?.templateId || "homepage",
    );

    res.status(200).json({
      success: true,
      suggestions: tryParseJson(result.content) || result.content,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to generate SEO suggestions." });
  }
});

router.post("/api/ai/legal-research/chat", async (req, res) => {
  try {
    const userId = getUserId(req);
    const { promptVersion, result } = await runFeature(
      "legal_research",
      { ...req.body, userId },
      "ai_research_session",
      req.body?.sessionId || null
    );

    const parsed = tryParseJson<Record<string, any>>(result.content) || {};
    let sessionId = req.body?.sessionId || null;

    if (!sessionId) {
      const { data: session } = await (supabaseService as any)
        .from("ai_research_sessions")
        .insert({
          service_order_id: req.body?.serviceOrderId || null,
          title: req.body?.sessionTitle || req.body?.question?.slice(0, 100) || "Legal Research",
          created_by: userId,
        })
        .select("*")
        .single();
      sessionId = session?.id;
    }

    if (sessionId) {
      await (supabaseService as any).from("ai_research_messages").insert({
        session_id: sessionId,
        role: "user",
        message_text: req.body?.question || "",
        answer_text: parsed.answer || stripMarkdownCodeFence(result.content),
        internal_sources: parsed.internal_sources || [],
        external_sources: parsed.external_sources || [],
        provider: result.provider,
        model: result.model,
        prompt_version: promptVersion,
      });
    }

    res.status(200).json({
      success: true,
      sessionId,
      answer: parsed,
      raw: result.content,
      provider: result.provider,
      model: result.model,
      promptVersion,
    });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to answer legal research question." });
  }
});

router.get("/api/ai/legal-research/sessions/:serviceOrderId", async (req, res) => {
  try {
    const { data, error } = await (supabaseService as any)
      .from("ai_research_sessions")
      .select("*, ai_research_messages(*)")
      .eq("service_order_id", req.params.serviceOrderId)
      .order("created_at", { ascending: false });

    if (error) {
      throw error;
    }

    res.status(200).json({ success: true, sessions: data || [] });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch research sessions." });
  }
});

router.post("/api/ai/documents/reindex", async (req, res) => {
  try {
    const serviceOrderId = req.body?.serviceOrderId;
    if (!serviceOrderId) {
      return res.status(400).json({ success: false, message: "serviceOrderId is required." });
    }

    const jobs = await reindexServiceOrderDocuments(supabaseService, serviceOrderId);
    res.status(200).json({ success: true, jobs });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to reindex documents." });
  }
});

router.post("/api/ai/documents/reindex/:serviceOrderId", async (req, res) => {
  try {
    const jobs = await reindexServiceOrderDocuments(supabaseService, req.params.serviceOrderId);
    res.status(200).json({ success: true, jobs });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to reindex documents." });
  }
});

router.get("/api/ai/documents/chunks/:serviceOrderId", async (req, res) => {
  try {
    const chunks = await getDocumentChunksForServiceOrder(supabaseService, req.params.serviceOrderId);
    res.status(200).json({ success: true, chunks });
  } catch (error: any) {
    res.status(500).json({ success: false, message: error.message || "Failed to fetch document chunks." });
  }
});

export const aiRouter = router;
