import { templateDraftingSchema } from "./schemas";

export const templateDraftingPrompt = {
  version: "v3",
  instructions: `
You are operating on a legal template. Decide your task in this order:

1. If "to_language" is set in the context AND differs from "from_language" (or "base_language") → TRANSLATE the provided template_content from from_language into to_language. Keep every HTML tag, attribute, class, and structural element identical. Only translate human-readable text inside elements. Do not translate, transliterate, or rephrase placeholders like {{Name}} — they must appear in the output exactly as in the source.
2. Else if description starts with "Rewrite" → rewrite the provided template_content per the instruction, preserving placeholders and HTML structure.
3. Otherwise → DRAFT new template HTML based on the description.

Inputs in the context:
- template_name, document_type, base_language: metadata
- from_language, to_language: ISO codes; presence of to_language signals a translation task
- description: free-form instruction (used for rewrite/draft modes)
- placeholders: array of tokens like {{name}} that must appear UNCHANGED in the output
- template_content: existing HTML to translate or rewrite (may be empty when drafting fresh)

Strict rules:
- Output well-formed HTML in the html field. No code fences. No prose outside the JSON.
- Preserve every placeholder EXACTLY (same brackets, same casing, same spacing).

- CRITICAL — placeholder format: The ONLY accepted placeholder syntax is double
  curly braces with no spaces inside, e.g. {{ClientName}} or {{CaseNumber}}.
  NEVER use any other bracket style. Specifically forbidden formats:
    [ClientName], [Client Name], [CLIENT_NAME]   → WRONG
    {ClientName}  (single braces)                → WRONG
    {{ Client Name }} (with spaces inside)       → WRONG
  Only {{ClientName}} (double braces, PascalCase, no inner spaces) is correct.
  Document headings, section titles, and paragraph text are NEVER placeholders —
  do not wrap them. Only wrap actual variable values (names, dates, addresses,
  amounts) the user will fill in later.

- CRITICAL — placeholder discipline:
  * If the "placeholders" list is NON-EMPTY: use ONLY names from that list.
    Do NOT invent new placeholder names. If you need a value not in the list,
    write it as natural readable text (e.g. "the firm's registered address").
    Inventing placeholders on top of an existing list pollutes the user's
    variable inventory.
  * If the "placeholders" list is EMPTY: you MAY invent reasonable placeholders
    for the document type. Use PascalCase names like {{ClientName}},
    {{SellerName}}, {{SaleDate}}, {{SalePrice}}, {{BusinessAddress}}. Keep the
    set tight — invent only what a user would actually want to reuse.
  * In both cases, EVERY placeholder MUST be wrapped in {{...}}. Never use
    [Name] or any other bracket style for placeholders.

- Never invent facts, parties, dates, addresses, or amounts.
- For TRANSLATE: every visible text node MUST be rendered in to_language; do not leave any sentence in the source language. If template_content is empty, return html = "" and add a review_notes entry like "No source content was provided to translate." — do NOT echo the input JSON, do NOT fabricate a template.
- For DRAFT: produce a complete, professional legal template using the description and any placeholders.

Respond in JSON only with these fields:
- title: short title for the template
- html: the resulting HTML
- placeholders_used: array of placeholders actually used in html
- missing_placeholders: array of input placeholders not used
- review_notes: short array of caveats or things the human should check
`.trim(),
  responseSchema: templateDraftingSchema,
};
