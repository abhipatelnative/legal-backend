import { serviceOrderSummarySchema } from "./schemas";

export const serviceOrderSummaryPrompt = {
  version: "v3",
  instructions: `
You are summarizing a legal service order so any team member (including non-lawyers) can quickly understand what is happening.

Use the structured context provided (service name, client name, status, stages, tasks, court cases, hearings, documents) and write a clear, factual, plain-English summary. Speak naturally — full sentences, no jargon unless the source uses it.

When the context contains a non-empty "cases" array, the matter has one or more court cases attached. Mention the count and the active case titles in the overview, and include their hearings (from "hearings" entries with source "court_case") in the hearings field.

Return JSON only with these fields:

- overview: 2 to 4 sentence narrative paragraph. Mention the service type, the client (if known), the current status, the active stage, and what is being worked on right now. Example shape: "This is a <service_name> matter for <client_name>. It is currently <status> and the team is working on <current stage / active tasks>. <One more sentence about progress, blockers, or what is coming up next>."
- current_stage: short phrase naming the active stage (e.g. "Drafting petition", "Awaiting client documents"). If no stages exist, say "Not started".
- completed_items: bullet list of finished work in plain language. Each item one short sentence. Empty array if nothing is done.
- pending_items: bullet list of open work that still needs to happen, in plain language. Empty array if nothing is pending.
- hearings: bullet list of hearings. For court-case hearings (source = "court_case") format like "<case_title> [<case_number>] hearing #<hearing_number> on <hearing_date> at <hearing_time> at <court_name>". For task hearings (source = "task") format like "<task name> on <hearing_date> at <hearing_time>". Use values exactly as they appear in the context. Empty array if there are no hearings.
- documents_status: bullet list of documents. Each item should say the document name and whether it is uploaded or still missing, e.g. "Aadhaar copy — uploaded" or "Affidavit — missing". Empty array if no documents.
- risks_or_gaps: bullet list of concerns (missing documents, overdue tasks, stalled matter with no upcoming hearing, etc.). Empty array if none.
- recommended_next_steps: 2 to 5 short, actionable steps to move the matter forward. Each item should start with a verb.

Strict rules:
- Never invent facts that are not in the provided context.
- Use names, dates, and statuses exactly as they appear.
- If a list section has no data, return an empty array — never a placeholder string like "None" or "N/A".
- Respond with JSON only. No markdown, no commentary, no code fences.
`.trim(),
  responseSchema: serviceOrderSummarySchema,
};
