import fetch from "node-fetch";

import type { AiAttachmentInput, AiGenerationRequest, AiGenerationResponse, ProviderAdapter, ProviderConfig } from "../types";

function buildUserContent(prompt: string, attachments?: AiAttachmentInput[]) {
  const images = (attachments || []).filter((a) => a.kind === "image" && a.base64);
  if (images.length === 0) {
    return prompt;
  }
  return [
    { type: "text", text: prompt },
    ...images.map((img) => ({
      type: "image",
      source: {
        type: "base64",
        media_type: img.mimeType,
        data: img.base64,
      },
    })),
  ];
}

async function generate(request: AiGenerationRequest): Promise<AiGenerationResponse> {
  const response = await fetch(`${(request.baseUrl || "https://api.anthropic.com/v1").replace(/\/$/, "")}/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": request.apiKey || "",
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: request.model,
      system: request.system,
      max_tokens: request.maxTokens ?? 4096,
      temperature: request.temperature ?? 0.2,
      messages: [{ role: "user", content: buildUserContent(request.prompt, request.attachments) }],
    }),
    signal: request.signal as any,
  });

  const body: any = await response.json();
  if (!response.ok) {
    throw new Error(body?.error?.message || "Anthropic request failed.");
  }

  const content = Array.isArray(body.content)
    ? body.content.map((item: any) => item.text).filter(Boolean).join("\n")
    : "";

  return {
    provider: "anthropic",
    model: body.model || request.model,
    content,
    raw: body,
    usage: {
      inputTokens: body.usage?.input_tokens,
      outputTokens: body.usage?.output_tokens,
    },
  };
}

async function test(config: ProviderConfig) {
  if (!config.apiKey) {
    return { ok: false, message: "Anthropic API key is missing." };
  }

  try {
    await generate({
      prompt: "Return JSON {\"ok\":true}.",
      system: "You are a connection test.",
      model: config.default_model || "claude-sonnet-4-20250514",
      apiKey: config.apiKey,
      baseUrl: config.base_url,
      jsonMode: true,
      maxTokens: 100,
    });
    return { ok: true, message: "Anthropic connection verified." };
  } catch (error: any) {
    return { ok: false, message: error.message || "Anthropic connection failed." };
  }
}

export const anthropicAdapter: ProviderAdapter = {
  key: "anthropic",
  generate,
  test,
};
