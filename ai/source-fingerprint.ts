export function buildSourceFingerprint(summaryContext: Record<string, unknown>): Record<string, unknown> {
  const stages = Array.isArray(summaryContext.stages) ? summaryContext.stages.length : 0;
  const tasks = Array.isArray(summaryContext.tasks) ? summaryContext.tasks.length : 0;
  const documents = Array.isArray(summaryContext.documents) ? summaryContext.documents.length : 0;
  const hearings = Array.isArray(summaryContext.hearings) ? summaryContext.hearings.length : 0;

  return {
    stages,
    tasks,
    documents,
    hearings,
    last_updated_at: summaryContext.updated_at ?? null,
  };
}
