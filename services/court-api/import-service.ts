import { createClient } from "@supabase/supabase-js";

import { SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "../../config/credentials";
import { findOrCreateCourt, mapCaseStatus, mapHearingStatus } from "./field-mappers";
import { getActiveAdapter } from "./registry";
import type { EcourtCaseBundle, EcourtHearing } from "./types";

const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

export interface FetchByCnrResult {
  bundle: EcourtCaseBundle;
}

// Pure fetch (no DB writes). Used by the "Add Case" dialog to pre-fill the form.
export async function fetchByCnr(cnr: string): Promise<FetchByCnrResult> {
  const adapter = await getActiveAdapter();
  if (!adapter) {
    throw new Error("eCourts API is not configured. Add a Bearer token in Settings → Integrations.");
  }
  const bundle = await adapter.fetchCaseByCnr(cnr);
  return { bundle };
}

export interface ImportCaseInput {
  cnr: string;
  service_order_id: string;
  assigned_employee_ids: string[];
  selected_hearing_external_ids: string[];
  // Admin-overridable fields (UI values win over API values):
  case_title?: string;
  case_number?: string;
  case_type?: string;
  filing_date?: string;
  status?: string;
  notes?: string;
  filing_number?: string;
  registration_number?: string;
  registration_date?: string;
  e_filing_number?: string;
  e_filing_date?: string;
  first_hearing_date?: string;
  next_hearing_date?: string;
  case_stage?: string;
  court_number_and_judge?: string;
  acts?: string;
  sections?: string;
  petitioners?: { name: string; advocate?: string }[];
  respondents?: { name: string; advocate?: string }[];
  judges?: string[];
  processes?: { process_id?: string; title?: string; date?: string }[];
  fir_details?: { police_station?: string; fir_number?: string; year?: string | number } | null;
}

export interface ImportCaseResult {
  order_case_id: string;
  hearings_created: number;
  already_imported: boolean;
}

export async function importCaseFromCnr(input: ImportCaseInput): Promise<ImportCaseResult> {
  const cnr = input.cnr.trim();
  if (!cnr) throw new Error("CNR is required");
  if (!input.service_order_id) throw new Error("service_order_id is required");

  // Idempotency: if this CNR already exists, return the existing row.
  const { data: existing } = await supabaseService
    .from("order_cases")
    .select("id")
    .eq("cnr_number", cnr)
    .maybeSingle();
  if (existing?.id) {
    return { order_case_id: existing.id, hearings_created: 0, already_imported: true };
  }

  // Fetch fresh from API + apply mappers.
  const { bundle } = await fetchByCnr(cnr);
  const courtId = await findOrCreateCourt(bundle.case.court_name);

  // Determine the case_order for this service order.
  const { count: existingCaseCount } = await supabaseService
    .from("order_cases")
    .select("id", { count: "exact", head: true })
    .eq("service_order_id", input.service_order_id);

  const casePayload = {
    service_order_id: input.service_order_id,
    case_number: input.case_number ?? bundle.case.case_number ?? null,
    case_title: input.case_title ?? bundle.case.case_title,
    court_id: courtId,
    case_type: input.case_type ?? bundle.case.case_type ?? null,
    filing_date: input.filing_date ?? bundle.case.filing_date ?? null,
    status: input.status ?? mapCaseStatus(bundle.case.status),
    notes: input.notes ?? bundle.case.notes ?? null,
    case_order: (existingCaseCount ?? 0) + 1,
    cnr_number: cnr,
    source: "ecourtsindia",
    source_external_id: bundle.case.source_external_id ?? cnr,
    last_synced_at: new Date().toISOString(),
    filing_number: input.filing_number ?? bundle.case.filing_number ?? null,
    registration_number: input.registration_number ?? bundle.case.registration_number ?? null,
    registration_date: input.registration_date ?? bundle.case.registration_date ?? null,
    e_filing_number: input.e_filing_number ?? bundle.case.e_filing_number ?? null,
    e_filing_date: input.e_filing_date ?? bundle.case.e_filing_date ?? null,
    first_hearing_date: input.first_hearing_date ?? bundle.case.first_hearing_date ?? null,
    next_hearing_date: input.next_hearing_date ?? bundle.case.next_hearing_date ?? null,
    case_stage: input.case_stage ?? bundle.case.case_stage ?? null,
    court_number_and_judge: input.court_number_and_judge ?? bundle.case.court_number_and_judge ?? null,
    acts: input.acts ?? bundle.case.acts ?? null,
    sections: input.sections ?? bundle.case.sections ?? null,
    petitioners: input.petitioners ?? bundle.case.petitioners ?? [],
    respondents: input.respondents ?? bundle.case.respondents ?? [],
    judges: input.judges ?? bundle.case.judges ?? [],
    processes: input.processes ?? bundle.case.processes ?? [],
    fir_details: input.fir_details !== undefined ? input.fir_details : (bundle.case.fir_details ?? null),
  };

  const { data: insertedCase, error: caseError } = await supabaseService
    .from("order_cases")
    .insert(casePayload)
    .select("id")
    .single();
  if (caseError || !insertedCase) {
    throw new Error(`Failed to create order_cases row: ${caseError?.message || "unknown error"}`);
  }
  const orderCaseId = insertedCase.id as string;

  // Insert assigned employees (case-level junction).
  const uniqueEmployeeIds = [...new Set(input.assigned_employee_ids.filter(Boolean))];
  if (uniqueEmployeeIds.length > 0) {
    const employeeRows = uniqueEmployeeIds.map((userId, idx) => ({
      order_case_id: orderCaseId,
      user_id: userId,
      role: idx === 0 ? "primary" : "secondary",
    }));
    const { error: empError } = await supabaseService
      .from("case_assigned_employees")
      .insert(employeeRows);
    if (empError) {
      console.error("[court-api] Failed to insert case_assigned_employees:", empError.message);
    }
  }

  // Insert selected hearings.
  const selectedSet = new Set(input.selected_hearing_external_ids);
  const hearingsToInsert = bundle.hearings.filter((h) => selectedSet.has(h.source_external_id));
  const hearingsCreated = await insertHearings(orderCaseId, hearingsToInsert, 0);

  // Audit log.
  await supabaseService.from("court_sync_runs").insert({
    order_case_id: orderCaseId,
    trigger: "import",
    completed_at: new Date().toISOString(),
    status: "success",
    hearings_added: hearingsCreated,
  });

  return { order_case_id: orderCaseId, hearings_created: hearingsCreated, already_imported: false };
}

// Inserts hearings starting from `startNumber`. Returns count actually inserted.
// Skips any hearing whose source_external_id already exists (idempotent).
export async function insertHearings(
  orderCaseId: string,
  hearings: EcourtHearing[],
  startNumber: number
): Promise<number> {
  if (hearings.length === 0) return 0;

  const externalIds = hearings.map((h) => h.source_external_id);
  const { data: existing } = await supabaseService
    .from("case_hearings")
    .select("source_external_id")
    .in("source_external_id", externalIds);
  const existingIds = new Set((existing || []).map((row: any) => row.source_external_id));

  const newHearings = hearings.filter((h) => !existingIds.has(h.source_external_id));
  if (newHearings.length === 0) return 0;

  const rows = newHearings.map((h, idx) => ({
    order_case_id: orderCaseId,
    hearing_number: startNumber + idx + 1,
    hearing_date: h.hearing_date,
    hearing_time: h.hearing_time ?? null,
    court_room: h.court_room ?? null,
    purpose: h.purpose ?? null,
    outcome: h.outcome ?? null,
    next_hearing_date: h.next_hearing_date ?? null,
    status: mapHearingStatus(h.status),
    notes: h.notes ?? null,
    judge_name: h.judge_name ?? null,
    source: "ecourtsindia",
    source_external_id: h.source_external_id,
  }));

  const { error } = await supabaseService.from("case_hearings").insert(rows);
  if (error) {
    console.error("[court-api] Failed to insert case_hearings:", error.message);
    return 0;
  }
  return rows.length;
}
