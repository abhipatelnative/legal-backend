import { createClient } from "@supabase/supabase-js";

import { SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "../../config/credentials";
import { EcourtsIndiaClient } from "./ecourtsindia-client";
import type { CourtApiAdapter, CourtApiConfigRow } from "./types";

const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

export async function loadActiveConfig(): Promise<CourtApiConfigRow | null> {
  const { data, error } = await supabaseService
    .from("court_api_configs")
    .select("*")
    .eq("is_active", true)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    console.error("[court-api] Failed to load active config:", error.message);
    return null;
  }
  return (data as CourtApiConfigRow | null) ?? null;
}

export async function getActiveAdapter(): Promise<CourtApiAdapter | null> {
  const config = await loadActiveConfig();
  if (!config) return null;
  if (config.provider === "ecourtsindia") {
    return new EcourtsIndiaClient(config);
  }
  console.warn(`[court-api] Unsupported provider: ${config.provider}`);
  return null;
}
