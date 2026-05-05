import { suggestionSchema } from "./schemas";

export const stageTaskSuggestionsPrompt = {
  version: "v4",
  instructions: `
You are designing a legal workflow for a service. From the provided context, generate a realistic, end-to-end set of stages and tasks tailored to the service name, category, description, and any userInstruction.

Inputs in the context:
- serviceName, categoryName, description: what the service is about
- legalTemplates, requiredDocuments: artifacts already attached
- existingStages: stages the user has already added (avoid duplicating them)
- availableWorkTypes: list of work-type names already configured in the system. Each task MUST be tagged with the single best matching name from this list when one fits; otherwise use null.
- availableDocuments: list of objects { name, category } already configured in the system. Each stage's required_documents MUST come from this list; do NOT invent new document names. Pick only documents that are genuinely needed for that stage. Match by exact spelling (case-insensitive).
- userInstruction: optional free-form guidance from the user — follow it when present

Rules:
- Always produce 3 to 7 stages, each with 2 to 6 concrete tasks.
- Each stage MUST cover a distinct phase of the work (e.g., intake, drafting, filing, follow-up). Do not invent facts, parties, or dates.
- Skip stages that already exist in existingStages by name (case-insensitive).
- If the service is too vague to plan, still return at least 3 generic but useful stages for that category.
- For each task, pick a work_type from availableWorkTypes (exact spelling, case-insensitive match) when one fits the task. Do NOT invent new work-type names. Use null only when nothing in the list is a reasonable fit.
- For each stage, populate required_documents only with names taken verbatim from availableDocuments. Use [] when no document from the list applies. Never invent document names.

Respond in JSON only with this exact shape:
{
  "suggested_stages": [
    {
      "name": "string",
      "description": "string",
      "rationale": "string",
      "tasks": [
        { "name": "string", "work_type": "string or null" }
      ],
      "required_documents": ["string"]
    }
  ]
}

Do not wrap in code fences. Do not include any text outside the JSON. The top-level key MUST be "suggested_stages". Each task MUST be an object with "name" and "work_type" — never a bare string.
`.trim(),
  responseSchema: suggestionSchema,
};
