import { createClient } from "@supabase/supabase-js";

import { SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "../../config/credentials";
import { mapCaseStatus } from "./field-mappers";
import { insertHearings } from "./import-service";
import { getActiveAdapter } from "./registry";
import type { CourtApiAdapter } from "./types";

const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

export interface SyncResult {
  order_case_id: string;
  status: "success" | "partial" | "failed";
  hearings_added: number;
  error?: string;
}

// Re-fetches one imported case and inserts NEW hearings only. Never overwrites
// admin-edited fields (notes, outcome, purpose, participants, assignments).
export async function syncImportedCase(
  orderCaseId: string,
  trigger: "cron" | "manual",
  adapterOverride?: CourtApiAdapter
): Promise<SyncResult> {
  const startedAt = new Date().toISOString();
  const adapter = adapterOverride ?? (await getActiveAdapter());
  if (!adapter) {
    return await recordFailure(orderCaseId, trigger, startedAt, "No active eCourts API config");
  }

  const { data: orderCase, error: fetchError } = await supabaseService
    .from("order_cases")
    .select("id, cnr_number, source, status, last_synced_at")
    .eq("id", orderCaseId)
    .maybeSingle();
  if (fetchError || !orderCase) {
    return await recordFailure(orderCaseId, trigger, startedAt, fetchError?.message || "Order case not found");
  }
  if (orderCase.source !== "ecourtsindia" || !orderCase.cnr_number) {
    return await recordFailure(orderCaseId, trigger, startedAt, "Case is not an imported eCourt case");
  }

  try {
    const bundle = await adapter.fetchCaseByCnr(orderCase.cnr_number);

    const { count: existingHearingCount } = await supabaseService
      .from("case_hearings")
      .select("id", { count: "exact", head: true })
      .eq("order_case_id", orderCaseId);

    const hearingsAdded = await insertHearings(orderCaseId, bundle.hearings, existingHearingCount ?? 0);

    // Backfill hearing statuses based on date (past → Completed, future → Scheduled).
    await backfillHearingStatuses(orderCaseId);

    // Refresh all API-owned fields. LegalPrime-internal fields (notes, case_title,
    // assigned_employees, case_order) are never touched here.
    const c = bundle.case;
    const updates: Record<string, unknown> = { last_synced_at: new Date().toISOString() };
    if (c.status)                              updates.status                = mapCaseStatus(c.status);
    if (c.case_stage !== undefined)            updates.case_stage            = c.case_stage ?? null;
    if (c.next_hearing_date !== undefined)     updates.next_hearing_date     = c.next_hearing_date ?? null;
    if (c.first_hearing_date !== undefined)    updates.first_hearing_date    = c.first_hearing_date ?? null;
    if (c.court_number_and_judge !== undefined) updates.court_number_and_judge = c.court_number_and_judge ?? null;
    if (c.acts !== undefined)                  updates.acts                  = c.acts ?? null;
    if (c.sections !== undefined)              updates.sections              = c.sections ?? null;
    if (c.petitioners?.length)                 updates.petitioners           = c.petitioners;
    if (c.respondents?.length)                 updates.respondents           = c.respondents;
    if (c.judges?.length)                      updates.judges                = c.judges;
    if (c.processes?.length)                   updates.processes             = c.processes;
    if (c.fir_details !== undefined)           updates.fir_details           = c.fir_details ?? null;
    if (c.registration_number !== undefined)   updates.registration_number   = c.registration_number ?? null;
    if (c.registration_date !== undefined)     updates.registration_date     = c.registration_date ?? null;
    if (c.filing_number !== undefined)         updates.filing_number         = c.filing_number ?? null;
    await supabaseService.from("order_cases").update(updates).eq("id", orderCaseId);

    await supabaseService.from("court_sync_runs").insert({
      order_case_id: orderCaseId,
      trigger,
      started_at: startedAt,
      completed_at: new Date().toISOString(),
      status: "success",
      hearings_added: hearingsAdded,
    });

    return { order_case_id: orderCaseId, status: "success", hearings_added: hearingsAdded };
  } catch (error: any) {
    return await recordFailure(orderCaseId, trigger, startedAt, error?.message || "Unknown sync error");
  }
}

// Sets hearing status based on date: past hearings → Completed, future → Scheduled.
// Only touches eCourtsIndia-sourced hearings so manual ones are left alone.
export async function backfillHearingStatuses(orderCaseId: string): Promise<number> {
  const today = new Date().toISOString().slice(0, 10);

  const [pastResult, futureResult] = await Promise.all([
    supabaseService
      .from("case_hearings")
      .update({ status: "Completed" })
      .eq("order_case_id", orderCaseId)
      .eq("source", "ecourtsindia")
      .eq("status", "Scheduled")
      .lt("hearing_date", today),
    supabaseService
      .from("case_hearings")
      .update({ status: "Scheduled" })
      .eq("order_case_id", orderCaseId)
      .eq("source", "ecourtsindia")
      .eq("status", "Completed")
      .gte("hearing_date", today),
  ]);

  if (pastResult.error) console.error("[court-api] backfillHearingStatuses (past):", pastResult.error.message);
  if (futureResult.error) console.error("[court-api] backfillHearingStatuses (future):", futureResult.error.message);

  return 0;
}

async function recordFailure(
  orderCaseId: string,
  trigger: "cron" | "manual",
  startedAt: string,
  error: string
): Promise<SyncResult> {
  await supabaseService.from("court_sync_runs").insert({
    order_case_id: orderCaseId,
    trigger,
    started_at: startedAt,
    completed_at: new Date().toISOString(),
    status: "failed",
    hearings_added: 0,
    error,
  });
  return { order_case_id: orderCaseId, status: "failed", hearings_added: 0, error };
}

export async function syncAllImportedCases(): Promise<{ total: number; succeeded: number; failed: number }> {
  const adapter = await getActiveAdapter();
  if (!adapter) {
    console.warn("[court-api] Skipping nightly sync: no active config.");
    return { total: 0, succeeded: 0, failed: 0 };
  }

  const { data, error } = await supabaseService
    .from("order_cases")
    .select("id")
    .eq("source", "ecourtsindia")
    .neq("status", "Disposed")
    .order("last_synced_at", { ascending: true, nullsFirst: true });

  if (error) {
    console.error("[court-api] Failed to load imported cases:", error.message);
    return { total: 0, succeeded: 0, failed: 0 };
  }

  const cases = (data || []) as { id: string }[];
  let succeeded = 0;
  let failed = 0;

  // Sequential to respect provider rate limits; node-cron only fires once per
  // day so the throughput is fine even for hundreds of cases.
  for (const row of cases) {
    const result = await syncImportedCase(row.id, "cron", adapter);
    if (result.status === "success") succeeded += 1;
    else failed += 1;
  }

  return { total: cases.length, succeeded, failed };
}
