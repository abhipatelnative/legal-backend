import { baseLegalSystemPrompt } from "./prompts/base-legal-system";
import { documentSummarizerPrompt } from "./prompts/document-summarizer";
import { generalChatPrompt } from "./prompts/general-chat";
import { legalResearchPrompt } from "./prompts/legal-research";
import { seoSuggestionsPrompt } from "./prompts/seo-suggestions";
import { serviceOrderSummaryPrompt } from "./prompts/service-order-summary";
import { stageTaskSuggestionsPrompt } from "./prompts/stage-task-suggestions";
import { templateDraftingPrompt } from "./prompts/template-drafting";
import type { AiFeatureKey, PromptDefinition } from "./types";

const promptByFeature: Record<AiFeatureKey, Omit<PromptDefinition, "system">> = {
  template_drafting: templateDraftingPrompt,
  document_summarizer: documentSummarizerPrompt,
  service_order_summary: serviceOrderSummaryPrompt,
  stage_task_suggestions: stageTaskSuggestionsPrompt,
  service_master_suggestions: stageTaskSuggestionsPrompt,
  legal_research: legalResearchPrompt,
  seo_suggestions: seoSuggestionsPrompt,
  general_chat: generalChatPrompt,
};

export function getPromptDefinition(feature: AiFeatureKey): PromptDefinition {
  const prompt = promptByFeature[feature];
  return {
    version: prompt.version,
    system: baseLegalSystemPrompt,
    instructions: prompt.instructions,
    responseSchema: prompt.responseSchema,
  };
}
