import fetch from "node-fetch";

import type { AiGenerationRequest, AiGenerationResponse, ProviderAdapter, ProviderConfig } from "../types";

async function generate(request: AiGenerationRequest): Promise<AiGenerationResponse> {
  const images = (request.attachments || [])
    .filter((a) => a.kind === "image" && a.base64)
    .map((a) => a.base64 as string);

  const userMessage: Record<string, unknown> = { role: "user", content: request.prompt };
  if (images.length > 0) {
    userMessage.images = images;
  }

  const response = await fetch(`${(request.baseUrl || "http://localhost:11434").replace(/\/$/, "")}/api/chat`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: request.model,
      stream: false,
      keep_alive: request.metadata?.keepAlive || "30m",
      options: {
        temperature: request.temperature ?? 0.2,
        num_predict: request.maxTokens ?? 2048,
      },
      messages: [
        request.system ? { role: "system", content: request.system } : null,
        userMessage,
      ].filter(Boolean),
      format: request.jsonMode ? "json" : undefined,
    }),
    signal: request.signal as any,
  });

  const body: any = await response.json();
  if (!response.ok) {
    throw new Error(body?.error || "Ollama request failed.");
  }

  return {
    provider: "ollama",
    model: body.model || request.model,
    content: body?.message?.content || "",
    raw: body,
    usage: {
      inputTokens: body?.prompt_eval_count,
      outputTokens: body?.eval_count,
    },
  };
}

async function test(config: ProviderConfig) {
  try {
    const response = await fetch(`${(config.base_url || "http://localhost:11434").replace(/\/$/, "")}/api/tags`);
    const body: any = await response.json();
    if (!response.ok) {
      throw new Error(body?.error || "Could not reach Ollama.");
    }

    const hasModel = Array.isArray(body?.models)
      ? body.models.some((model: any) => model.name === (config.default_model || "gemma2:2b"))
      : false;

    return {
      ok: true,
      message: hasModel
        ? "Ollama is reachable and the configured model is available."
        : "Ollama is reachable. Pull the configured model on the server if needed.",
      details: {
        model_present: hasModel,
      },
    };
  } catch (error: any) {
    return { ok: false, message: error.message || "Ollama connection failed." };
  }
}

export const ollamaAdapter: ProviderAdapter = {
  key: "ollama",
  generate,
  test,
};
