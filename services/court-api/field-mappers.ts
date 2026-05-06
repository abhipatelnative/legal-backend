import { createClient } from "@supabase/supabase-js";

import { SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "../../config/credentials";
import type {
  CaseProcess,
  CaseType,
  EcourtCase,
  EcourtHearing,
  FirDetails,
  HearingStatus,
  OrderCaseStatus,
  PartyWithAdvocate,
} from "./types";

const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

// Two-value enum: anything that's still alive → Pending, everything finalized → Disposed.
const CASE_STATUS_MAP: Record<string, OrderCaseStatus> = {
  pending: "Pending",
  active: "Pending",
  open: "Pending",
  ongoing: "Pending",
  on_hold: "Pending",
  "on hold": "Pending",
  stayed: "Pending",
  disposed: "Disposed",
  decided: "Disposed",
  closed: "Disposed",
  dismissed: "Disposed",
  transferred: "Disposed",
  finalized: "Disposed",
  finalised: "Disposed",
};

const CASE_TYPE_MAP: Record<string, CaseType> = {
  // Plain English
  civil: "Civil",
  criminal: "Criminal",
  family: "Family",
  matrimonial: "Family",
  labour: "Labour",
  labor: "Labour",
  revenue: "Revenue",
  consumer: "Consumer",
  corporate: "Corporate",
  commercial: "Corporate",
  // eCourts case-type codes
  cc: "Criminal",                // Criminal Complaint Case
  cr: "Criminal",
  crl: "Criminal",
  cri: "Criminal",
  cs: "Civil",                   // Civil Suit
  rcs: "Civil",                  // Regular Civil Suit
  scs: "Civil",                  // Special Civil Suit
  rfa: "Civil",                  // Regular First Appeal
  fa: "Family",
  hma: "Family",                 // Hindu Marriage Act
  da: "Family",                  // Divorce Act
  cp: "Corporate",               // Company Petition
};

const HEARING_STATUS_MAP: Record<string, HearingStatus> = {
  scheduled: "Scheduled",
  listed: "Scheduled",
  pending: "Scheduled",
  completed: "Completed",
  done: "Completed",
  heard: "Completed",
  adjourned: "Adjourned",
  postponed: "Adjourned",
  cancelled: "Cancelled",
  canceled: "Cancelled",
};

export function mapCaseStatus(raw: unknown): OrderCaseStatus {
  if (typeof raw !== "string") return "Pending";
  return CASE_STATUS_MAP[raw.trim().toLowerCase()] ?? "Pending";
}

export function mapCaseType(raw: unknown): CaseType | undefined {
  if (typeof raw !== "string") return undefined;
  return CASE_TYPE_MAP[raw.trim().toLowerCase()] ?? "Other";
}

export function mapHearingStatus(raw: unknown): HearingStatus {
  if (typeof raw !== "string") return "Scheduled";
  return HEARING_STATUS_MAP[raw.trim().toLowerCase()] ?? "Scheduled";
}

function pickString(...candidates: unknown[]): string | undefined {
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) {
      return candidate.trim();
    }
    if (typeof candidate === "number") {
      return String(candidate);
    }
  }
  return undefined;
}

function pickDate(...candidates: unknown[]): string | undefined {
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) {
      const trimmed = candidate.trim();
      // Handle Indian DD-MM-YYYY format common in court data.
      const ddmmyyyy = /^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$/.exec(trimmed);
      if (ddmmyyyy) {
        const [, dd, mm, yyyy] = ddmmyyyy;
        return `${yyyy}-${mm.padStart(2, "0")}-${dd.padStart(2, "0")}`;
      }
      const parsed = new Date(trimmed);
      if (!Number.isNaN(parsed.getTime())) {
        return parsed.toISOString().slice(0, 10);
      }
    }
  }
  return undefined;
}

// Recursively peeks into common envelope shapes so the mapper sees the actual
// case object regardless of nesting. eCourtsIndia wraps the payload as:
//   { data: { courtCaseData: { ...real fields... } } }
function unwrap(raw: any): any {
  if (!raw || typeof raw !== "object") return raw;
  if (raw.courtCaseData && typeof raw.courtCaseData === "object") {
    return unwrap(raw.courtCaseData);
  }
  if (raw.data && typeof raw.data === "object" && !Array.isArray(raw.data)) {
    return unwrap(raw.data);
  }
  if (raw.case && typeof raw.case === "object" && !Array.isArray(raw.case)) {
    return unwrap(raw.case);
  }
  if (raw.result && typeof raw.result === "object" && !Array.isArray(raw.result)) {
    return unwrap(raw.result);
  }
  return raw;
}

function joinList(value: unknown): string | undefined {
  if (Array.isArray(value)) {
    const items = value.filter((v) => typeof v === "string" && v.trim()).map((v) => (v as string).trim());
    return items.length > 0 ? items.join(", ") : undefined;
  }
  if (typeof value === "string" && value.trim()) return value.trim();
  return undefined;
}

function stripHtml(value?: string): string | undefined {
  if (!value) return undefined;
  return value.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
}

function buildTitleFromParties(d: any): string | undefined {
  const petitioner =
    joinList(d?.petitioners) ??
    pickString(
      d?.petitioner,
      d?.petitioner_name,
      d?.petitionerName,
      d?.parties?.petitioner,
      d?.parties?.petitioner_name,
      d?.parties?.petitionerName,
      d?.plaintiff,
      d?.appellant
    );
  const respondent =
    joinList(d?.respondents) ??
    pickString(
      d?.respondent,
      d?.respondent_name,
      d?.respondentName,
      d?.parties?.respondent,
      d?.parties?.respondent_name,
      d?.parties?.respondentName,
      d?.defendant
    );
  if (petitioner && respondent) return `${petitioner} vs ${respondent}`;
  return undefined;
}

// "THE BHARATIYA NYAYA SANHITA, 2023 - 324(4), 351(3), 352, 54"
// → { acts: "THE BHARATIYA NYAYA SANHITA, 2023", sections: "324(4), 351(3), 352, 54" }
// Splits on the FIRST " - " so commas inside the act name aren't broken.
export function splitCaseTypeSub(raw: unknown): { acts?: string; sections?: string } {
  if (typeof raw !== "string" || !raw.trim()) return {};
  const idx = raw.indexOf(" - ");
  if (idx === -1) return { acts: raw.trim() };
  return {
    acts: raw.slice(0, idx).trim() || undefined,
    sections: raw.slice(idx + 3).trim().replace(/,\s*$/, "") || undefined,
  };
}

// Index-based pairing: petitioners[i] + petitionerAdvocates[i]. Tolerates
// uneven array lengths (extra advocates ignored, missing advocates → undefined).
export function mapPartiesWithAdvocates(
  names: unknown,
  advocates: unknown
): PartyWithAdvocate[] {
  const nameList = Array.isArray(names) ? names.filter((n) => typeof n === "string") : [];
  const advList = Array.isArray(advocates) ? advocates.filter((n) => typeof n === "string") : [];
  return nameList.map((name, idx) => ({
    name: (name as string).trim(),
    advocate: typeof advList[idx] === "string" ? (advList[idx] as string).trim() || undefined : undefined,
  }));
}

function mapProcesses(raw: unknown): CaseProcess[] {
  if (!Array.isArray(raw)) return [];
  const result: CaseProcess[] = [];
  raw.forEach((p: any) => {
    const title = pickString(p?.title, p?.processTitle, p?.process_title, p?.name);
    const date = pickDate(p?.date, p?.processDate, p?.process_date);
    const id = pickString(p?.id, p?.processId, p?.process_id);
    if (!title && !date && !id) return;
    result.push({ process_id: id, title, date });
  });
  return result;
}

function mapFirDetails(raw: unknown): FirDetails | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const d: any = raw;
  const station = pickString(d.policeStation, d.police_station, d.PSName, d.psName);
  const num = pickString(d.firNumber, d.fir_number, d.FIRNo, d.firNo);
  const yearVal = d.year ?? d.firYear ?? d.fir_year;
  const year = typeof yearVal === "number" ? yearVal : pickString(yearVal);
  if (!station && !num && !year) return null;
  return { police_station: station, fir_number: num, year };
}

function mapJudges(d: any): string[] {
  if (Array.isArray(d?.judges)) {
    return d.judges.filter((j: any) => typeof j === "string" && j.trim()).map((j: string) => j.trim());
  }
  const single = pickString(d?.judge_name, d?.judgeName, d?.judge);
  return single ? [single] : [];
}

// Build "1-PRINCIPAL CIVIL JUDGE & J.M.F.C" style label from courtNo + judges.
function buildCourtNumberAndJudge(d: any): string | undefined {
  const judges = mapJudges(d);
  const courtNo = d?.courtNo ?? d?.court_no ?? d?.courtNumber;
  if (judges.length === 0 && courtNo == null) return undefined;
  const judgeStr = judges.join(" & ");
  if (courtNo != null && judgeStr) return `${courtNo}-${judgeStr}`;
  return judgeStr || (courtNo != null ? String(courtNo) : undefined);
}

export function mapApiCase(raw: any, cnr: string): EcourtCase {
  const d = unwrap(raw);
  const cd = d?.case_details ?? d?.caseDetails ?? {};

  const { acts, sections } = splitCaseTypeSub(d.caseTypeSub ?? d.act ?? d.acts_and_sections ?? d.actsAndSections);
  const petitioners = mapPartiesWithAdvocates(d.petitioners, d.petitionerAdvocates);
  const respondents = mapPartiesWithAdvocates(d.respondents, d.respondentAdvocates);
  const judges = mapJudges(d);
  const processes = mapProcesses(d.processes);
  const firDetails = mapFirDetails(d.firDetails ?? d.fir_details);
  const stage = stripHtml(pickString(d.purpose, d.stageOfCaseRaw, d.stageOfCase));

  return {
    cnr_number: pickString(d.cnr, d.cnr_number, d.cnrNumber, d.CNR, cd.cnr, cd.cnr_number, cnr) ?? cnr,
    case_number: pickString(
      // Prefer human-readable filing number first (e.g. "260/2026")
      d.filingNumber,
      d.filing_number,
      d.registrationNumber,
      d.registration_number,
      d.case_number,
      d.case_no,
      d.caseNumber,
      d.caseNo,
      cd.case_number,
      cd.caseNumber
    ),
    filing_number: pickString(d.filingNumber, d.filing_number, cd.filing_number, cd.filingNumber),
    registration_number: pickString(d.registrationNumber, d.registration_number, cd.registration_number, cd.registrationNumber),
    registration_date: pickDate(d.registrationDate, d.registration_date, cd.registration_date, cd.registrationDate),
    e_filing_number: pickString(d.eFilingNumber, d.efilingNumber, d.e_filing_number),
    e_filing_date: pickDate(d.eFilingDate, d.efilingDate, d.e_filing_date),
    case_title:
      pickString(
        d.case_title,
        d.title,
        d.case_name,
        d.caseTitle,
        d.caseName,
        d.caption,
        cd.title,
        cd.case_title,
        cd.caseTitle,
        d.parties?.title
      ) ??
      buildTitleFromParties(d) ??
      buildTitleFromParties(cd) ??
      "Untitled Case",
    court_name: pickString(
      d.courtName,
      d.court_name,
      d.court,
      d.court_complex,
      d.courtComplex,
      d.establishment,
      d.establishment_name,
      d.establishmentName,
      d.bench,
      cd.court_name,
      cd.courtName,
      cd.court
    ),
    case_type: pickString(
      d.caseType,
      d.case_type,
      d.caseTypeRaw,
      d.type,
      d.nature,
      d.category,
      d.categoryName,
      cd.case_type,
      cd.caseType,
      cd.type
    ),
    filing_date: pickDate(
      d.filingDate,
      d.filing_date,
      d.filed_date,
      d.filedDate,
      d.dateOfFiling,
      d.date_of_filing,
      cd.filing_date,
      cd.filingDate,
      cd.dateOfFiling
    ),
    first_hearing_date: pickDate(d.firstHearingDate, d.first_hearing_date, cd.firstHearingDate, cd.first_hearing_date),
    next_hearing_date: pickDate(d.nextHearingDate, d.next_hearing_date, cd.nextHearingDate, cd.next_hearing_date),
    case_stage: stage,
    court_number_and_judge: buildCourtNumberAndJudge(d),
    acts,
    sections,
    status: pickString(
      d.caseStatus,
      d.status,
      d.case_status,
      d.stage,
      d.currentStage,
      d.current_stage,
      d.disposition,
      cd.status,
      cd.caseStatus,
      cd.stage
    ),
    notes: pickString(d.notes, d.remarks),
    petitioners,
    respondents,
    judges,
    processes,
    fir_details: firDetails,
    source_external_id: pickString(d.id, d.case_id, d.caseId, d.cnr, d.cnr_number, cnr),
  };
}

export function mapApiHearings(raw: any, cnr?: string): EcourtHearing[] {
  const list: any[] =
    Array.isArray(raw) ? raw :
    Array.isArray(raw?.historyOfCaseHearings) ? raw.historyOfCaseHearings :
    Array.isArray(raw?.data) ? raw.data :
    Array.isArray(raw?.hearings) ? raw.hearings :
    Array.isArray(raw?.history) ? raw.history :
    Array.isArray(raw?.case_history) ? raw.case_history :
    Array.isArray(raw?.caseHistory) ? raw.caseHistory :
    [];
  const cnrPrefix = cnr ? cnr.trim() : pickString(raw?.cnr, raw?.cnr_number, raw?.cnrNumber) ?? "h";

  // Today (server date) — used to decide Completed vs Scheduled when the API
  // doesn't return a per-hearing status (eCourtsIndia historyOfCaseHearings doesn't).
  const today = new Date().toISOString().slice(0, 10);
  const nextHearingDate = pickDate(raw?.nextHearingDate, raw?.next_hearing_date);

  const result: EcourtHearing[] = [];
  list.forEach((h) => {
    const hearing_date = pickDate(
      h?.hearing_date,
      h?.hearingDate,
      h?.date,
      h?.scheduled_date,
      h?.scheduledDate,
      h?.business_date,
      h?.businessDate
    );
    if (!hearing_date) return;
    const businessOnDate =
      pickDate(h?.businessOnDate, h?.business_on_date, h?.businessDate, h?.business_date) ?? "x";
    // Stable composite ID: case-scoped + dates make it unique even across cases
    // and idempotent on re-sync (same hearing → same id, no duplicates).
    const externalId =
      pickString(h?.id, h?.hearing_id, h?.hearingId, h?.source_external_id, h?.sl_no, h?.slNo) ??
      `${cnrPrefix}-${hearing_date}-${businessOnDate}`;

    // Auto-compute status by date when API didn't provide one. The eCourts
    // historyOfCaseHearings array describes past hearings; only the upcoming
    // nextHearingDate should be Scheduled.
    const apiStatus = pickString(h?.status, h?.hearing_status, h?.hearingStatus);
    const computedStatus =
      hearing_date >= today || (nextHearingDate && hearing_date === nextHearingDate)
        ? "Scheduled"
        : "Completed";

    result.push({
      source_external_id: externalId,
      hearing_date,
      hearing_time: pickString(h?.hearing_time, h?.hearingTime, h?.time),
      judge_name: pickString(
        h?.judge_name,
        h?.judgeName,
        h?.judge,
        h?.coram,
        h?.bench,
        h?.presiding_officer,
        h?.presidingOfficer
      ),
      court_room: pickString(h?.court_room, h?.courtRoom, h?.room, h?.court_no, h?.courtNo),
      purpose: pickString(h?.purpose, h?.purposeOfHearing, h?.stage, h?.reason, h?.business),
      outcome: pickString(h?.outcome, h?.result, h?.disposition, h?.order_summary, h?.orderSummary),
      next_hearing_date: pickDate(h?.next_hearing_date, h?.nextHearingDate, h?.next_date, h?.nextDate),
      status: apiStatus ?? computedStatus,
      notes: pickString(h?.notes, h?.remarks),
    });
  });

  // If the API gave us a nextHearingDate that isn't already represented as
  // a hearing in the history, add a synthetic Scheduled entry for it.
  if (nextHearingDate && !result.some((h) => h.hearing_date === nextHearingDate)) {
    result.push({
      source_external_id: `${cnrPrefix}-${nextHearingDate}-next`,
      hearing_date: nextHearingDate,
      status: "Scheduled",
      purpose: pickString(raw?.purpose, raw?.stageOfCaseRaw, raw?.stageOfCase),
      judge_name: undefined,
    });
  }

  return result;
}

// Looks up the courts master by name (case-insensitive, trimmed) and creates
// it if missing. Returns the court_id to set on order_cases.
export async function findOrCreateCourt(courtName?: string): Promise<string | null> {
  if (!courtName || !courtName.trim()) return null;
  const normalized = courtName.trim();

  const { data: existing, error: fetchError } = await supabaseService
    .from("courts")
    .select("id")
    .ilike("court_name", normalized)
    .limit(1)
    .maybeSingle();

  if (fetchError) {
    console.error("[court-api] Failed to look up court:", fetchError.message);
    return null;
  }
  if (existing?.id) return existing.id;

  const { data: created, error: insertError } = await supabaseService
    .from("courts")
    .insert({ court_name: normalized })
    .select("id")
    .single();

  if (insertError) {
    console.error("[court-api] Failed to create court:", insertError.message);
    return null;
  }
  return created?.id ?? null;
}
