import fetch from "node-fetch";

import type { AiAttachmentInput, AiGenerationRequest, AiGenerationResponse, ProviderAdapter, ProviderConfig } from "../types";

function buildUserParts(prompt: string, attachments?: AiAttachmentInput[]) {
  const images = (attachments || []).filter((a) => a.kind === "image" && a.base64);
  const parts: any[] = [{ text: prompt }];
  for (const img of images) {
    parts.push({ inlineData: { mimeType: img.mimeType, data: img.base64 } });
  }
  return parts;
}

async function generate(request: AiGenerationRequest): Promise<AiGenerationResponse> {
  const base = (request.baseUrl || "https://generativelanguage.googleapis.com/v1beta").replace(/\/$/, "");
  const response = await fetch(`${base}/models/${request.model}:generateContent?key=${encodeURIComponent(request.apiKey || "")}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      system_instruction: request.system
        ? { parts: [{ text: request.system }] }
        : undefined,
      contents: [{ role: "user", parts: buildUserParts(request.prompt, request.attachments) }],
      generationConfig: {
        temperature: request.temperature ?? 0.2,
        maxOutputTokens: request.maxTokens ?? 4096,
        responseMimeType: request.jsonMode ? "application/json" : "text/plain",
      },
      tools: request.grounding ? [{ googleSearch: {} }] : undefined,
    }),
    signal: request.signal as any,
  });

  const body: any = await response.json();
  if (!response.ok) {
    throw new Error(body?.error?.message || "Gemini request failed.");
  }

  const content =
    body?.candidates?.[0]?.content?.parts?.map((part: any) => part.text).filter(Boolean).join("\n") || "";

  return {
    provider: "gemini",
    model: request.model,
    content,
    raw: body,
    usage: {
      inputTokens: body?.usageMetadata?.promptTokenCount,
      outputTokens: body?.usageMetadata?.candidatesTokenCount,
    },
  };
}

async function test(config: ProviderConfig) {
  if (!config.apiKey) {
    return { ok: false, message: "Gemini API key is missing." };
  }

  try {
    await generate({
      prompt: "Return JSON {\"ok\":true}.",
      system: "You are a connection test.",
      model: config.default_model || "gemini-2.0-flash",
      apiKey: config.apiKey,
      baseUrl: config.base_url,
      jsonMode: true,
      maxTokens: 100,
    });
    return { ok: true, message: "Gemini connection verified." };
  } catch (error: any) {
    return { ok: false, message: error.message || "Gemini connection failed." };
  }
}

export const geminiAdapter: ProviderAdapter = {
  key: "gemini",
  generate,
  test,
};
