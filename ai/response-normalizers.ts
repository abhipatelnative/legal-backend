export function stripMarkdownCodeFence(value: string): string {
  const trimmed = value.trim();
  if (!trimmed.startsWith("```")) {
    return trimmed;
  }

  return trimmed
    .replace(/^```(?:json|html|markdown|text)?\s*/i, "")
    .replace(/\s*```$/, "")
    .trim();
}

export function tryParseJson<T = Record<string, unknown>>(value: string): T | null {
  const normalized = stripMarkdownCodeFence(value);
  try {
    return JSON.parse(normalized) as T;
  } catch {
    return null;
  }
}

export function buildResponsePreview(value: string): string {
  const text = stripMarkdownCodeFence(value).replace(/\s+/g, " ").trim();
  return text.length > 400 ? `${text.slice(0, 397)}...` : text;
}
