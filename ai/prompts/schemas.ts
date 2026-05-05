export const templateDraftingSchema = {
  title: "string",
  html: "string",
  placeholders_used: ["string"],
  missing_placeholders: ["string"],
  review_notes: ["string"],
};

export const documentSummarySchema = {
  short_summary: "string",
  key_facts: ["string"],
  timeline: ["string"],
  parties: ["string"],
  risks: ["string"],
  missing_information: ["string"],
  action_items: ["string"],
  citations: [{ source: "string", excerpt: "string" }],
};

export const suggestionSchema = {
  suggested_stages: [
    {
      name: "string",
      description: "string",
      rationale: "string",
      tasks: [{ name: "string", work_type: "string|null" }],
      required_documents: ["string"],
    },
  ],
};

export const researchSchema = {
  answer: "string",
  internal_sources: [{ source: "string", excerpt: "string" }],
  external_sources: [{ title: "string", url: "string" }],
  open_questions: ["string"],
  confidence_note: "string",
};

export const serviceOrderSummarySchema = {
  overview: "string",
  current_stage: "string",
  completed_items: ["string"],
  pending_items: ["string"],
  hearings: ["string"],
  documents_status: ["string"],
  risks_or_gaps: ["string"],
  recommended_next_steps: ["string"],
};

export const seoSuggestionsSchema = {
  meta_title: "string",
  meta_description: "string",
  meta_keywords: "string",
  og_title: "string",
  og_description: "string",
  twitter_title: "string",
  twitter_description: "string",
  twitter_card: "string",
  jsonld_override: "string",
  review_notes: ["string"],
};
