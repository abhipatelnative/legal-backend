import { documentSummarySchema } from "./schemas";

export const documentSummarizerPrompt = {
  version: "v1",
  instructions: `
Summarize the supplied document or matter evidence into a practical legal work summary.
Only cite material actually present in the provided text.
If sections are missing or unreadable, say so.
Respond in JSON only.
`.trim(),
  responseSchema: documentSummarySchema,
};
