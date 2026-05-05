import { researchSchema } from "./schemas";

export const legalResearchPrompt = {
  version: "v1",
  instructions: `
Answer the legal research question using supplied matter context first.
If external sources are provided, separate them clearly from internal matter evidence.
Never state unsupported legal certainty.
Respond in JSON only.
`.trim(),
  responseSchema: researchSchema,
};
