import fetch from "node-fetch";

import type { AiAttachmentInput, AiGenerationRequest, AiGenerationResponse, ProviderAdapter, ProviderConfig } from "../types";

function buildUserContent(prompt: string, attachments?: AiAttachmentInput[]) {
  const images = (attachments || []).filter((a) => a.kind === "image" && a.base64);
  if (images.length === 0) {
    return [{ type: "input_text", text: prompt }];
  }
  return [
    { type: "input_text", text: prompt },
    ...images.map((img) => ({
      type: "input_image",
      image_url: `data:${img.mimeType};base64,${img.base64}`,
    })),
  ];
}

async function generate(request: AiGenerationRequest): Promise<AiGenerationResponse> {
  const response = await fetch(`${(request.baseUrl || "https://api.openai.com/v1").replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${request.apiKey || ""}`,
    },
    body: JSON.stringify({
      model: request.model,
      temperature: request.temperature ?? 0.2,
      max_output_tokens: request.maxTokens ?? 4096,
      input: [
        { role: "system", content: [{ type: "input_text", text: request.system || "" }] },
        { role: "user", content: buildUserContent(request.prompt, request.attachments) },
      ],
      text: request.jsonMode ? { format: { type: "json_object" } } : undefined,
    }),
    signal: request.signal as any,
  });

  const body: any = await response.json();
  if (!response.ok) {
    throw new Error(body?.error?.message || "OpenAI request failed.");
  }

  const outputText = Array.isArray(body.output)
    ? body.output
        .flatMap((item: any) => item.content || [])
        .map((item: any) => item.text)
        .filter(Boolean)
        .join("\n")
    : body.output_text || "";

  return {
    provider: "openai",
    model: body.model || request.model,
    content: outputText || body.output_text || "",
    raw: body,
    usage: {
      inputTokens: body.usage?.input_tokens,
      outputTokens: body.usage?.output_tokens,
    },
  };
}

async function test(config: ProviderConfig) {
  if (!config.apiKey) {
    return { ok: false, message: "OpenAI API key is missing." };
  }

  try {
    await generate({
      prompt: "Return JSON {\"ok\":true}.",
      system: "You are a connection test.",
      model: config.default_model || "gpt-5.2",
      apiKey: config.apiKey,
      baseUrl: config.base_url,
      jsonMode: true,
      maxTokens: 100,
    });
    return { ok: true, message: "OpenAI connection verified." };
  } catch (error: any) {
    return { ok: false, message: error.message || "OpenAI connection failed." };
  }
}

export const openAiAdapter: ProviderAdapter = {
  key: "openai",
  generate,
  test,
};
