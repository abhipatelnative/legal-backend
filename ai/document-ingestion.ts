import fetch from "node-fetch";
import type { SupabaseClient } from "@supabase/supabase-js";

function chunkText(content: string, size = 1800, overlap = 200): string[] {
  const chunks: string[] = [];
  let index = 0;

  while (index < content.length) {
    const end = Math.min(content.length, index + size);
    chunks.push(content.slice(index, end));
    if (end >= content.length) {
      break;
    }
    index = Math.max(0, end - overlap);
  }

  return chunks;
}

async function loadStorageFileAsText(supabaseService: SupabaseClient, path: string): Promise<string | null> {
  const { data, error } = await (supabaseService.storage as any).from("documents").createSignedUrl(path, 60);
  if (error || !data?.signedUrl) {
    return null;
  }

  const response = await fetch(data.signedUrl);
  if (!response.ok) {
    return null;
  }

  const contentType = response.headers.get("content-type") || "";
  if (!contentType.includes("text") && !contentType.includes("json") && !contentType.includes("html") && !contentType.includes("xml")) {
    return null;
  }

  return response.text();
}

export async function reindexServiceOrderDocuments(supabaseService: SupabaseClient, serviceOrderId: string) {
  const { data: docs, error } = await (supabaseService as any)
    .from("service_order_task_documents")
    .select("id, file_path, document_name, file_type, uploaded_at")
    .eq("service_order_id", serviceOrderId);

  if (error) {
    throw error;
  }

  const jobRows = [];
  for (const doc of docs || []) {
    const text = doc.file_path ? await loadStorageFileAsText(supabaseService, doc.file_path) : null;
    const chunks = text ? chunkText(text) : [];

    const { data: job } = await (supabaseService as any)
      .from("ai_document_ingestion_jobs")
      .insert({
        source_type: "service_order_task_document",
        source_id: doc.id,
        service_order_id: serviceOrderId,
        status: chunks.length > 0 ? "completed" : "skipped",
        chunk_count: chunks.length,
        metadata: {
          document_name: doc.document_name,
          file_type: doc.file_type,
        },
      })
      .select("*")
      .single();

    await (supabaseService as any)
      .from("ai_document_chunks")
      .delete()
      .eq("source_type", "service_order_task_document")
      .eq("source_id", doc.id);

    if (chunks.length > 0) {
      await (supabaseService as any).from("ai_document_chunks").insert(
        chunks.map((chunk, chunkIndex) => ({
          source_type: "service_order_task_document",
          source_id: doc.id,
          service_order_id: serviceOrderId,
          chunk_index: chunkIndex,
          content: chunk,
          metadata: {
            document_name: doc.document_name,
            file_type: doc.file_type,
          },
        }))
      );
    }

    jobRows.push(job);
  }

  return jobRows;
}
