import type { SupabaseClient } from "@supabase/supabase-js";

export async function getDocumentChunksForServiceOrder(
  supabaseService: SupabaseClient,
  serviceOrderId: string,
  limit = 25
) {
  const { data, error } = await (supabaseService as any)
    .from("ai_document_chunks")
    .select("id, source_type, source_id, chunk_index, content, metadata")
    .eq("service_order_id", serviceOrderId)
    .order("created_at", { ascending: false })
    .limit(limit);

  if (error) {
    throw error;
  }

  return data || [];
}
