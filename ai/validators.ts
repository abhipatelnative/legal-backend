import type { AiFeatureKey } from "./types";

import { tryParseJson } from "./response-normalizers";

export function validateFeatureOutput(feature: AiFeatureKey, content: string): { valid: boolean; message?: string } {
  const jsonFeatures: AiFeatureKey[] = [
    "template_drafting",
    "document_summarizer",
    "service_order_summary",
    "stage_task_suggestions",
    "service_master_suggestions",
    "legal_research",
    "seo_suggestions",
  ];

  if (!jsonFeatures.includes(feature)) {
    return { valid: true };
  }

  const parsed = tryParseJson(content);
  if (!parsed || typeof parsed !== "object") {
    return { valid: false, message: "Provider did not return valid JSON." };
  }

  return { valid: true };
}
