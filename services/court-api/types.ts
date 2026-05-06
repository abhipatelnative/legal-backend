// Shape of normalized court data after the API client + field mappers run.
// The actual eCourtsIndia response shape is unknown until the user signs up
// at https://ecourtsindia.com/api and accesses their authenticated docs portal.
// The client is responsible for mapping their raw payload to these types.

export type OrderCaseStatus = "Pending" | "Disposed";
export type CaseType = "Civil" | "Criminal" | "Family" | "Labour" | "Revenue" | "Consumer" | "Corporate" | "Other";
export type HearingStatus = "Scheduled" | "Completed" | "Adjourned" | "Cancelled";

export interface PartyWithAdvocate {
  name: string;
  advocate?: string;
}

export interface CaseProcess {
  process_id?: string;
  title?: string;
  date?: string;
}

export interface FirDetails {
  police_station?: string;
  fir_number?: string;
  year?: string | number;
}

export interface EcourtCase {
  cnr_number: string;
  case_number?: string;
  filing_number?: string;
  registration_number?: string;
  registration_date?: string;
  e_filing_number?: string;
  e_filing_date?: string;
  case_title: string;
  court_name?: string;
  case_type?: CaseType | string;
  filing_date?: string;
  first_hearing_date?: string;
  next_hearing_date?: string;
  case_stage?: string;
  court_number_and_judge?: string;
  acts?: string;
  sections?: string;
  status?: OrderCaseStatus | string;
  notes?: string;
  petitioners: PartyWithAdvocate[];
  respondents: PartyWithAdvocate[];
  judges: string[];
  processes: CaseProcess[];
  fir_details?: FirDetails | null;
  source_external_id?: string;
}

export interface EcourtHearing {
  source_external_id: string;
  hearing_date: string;
  hearing_time?: string;
  judge_name?: string;
  court_room?: string;
  purpose?: string;
  outcome?: string;
  next_hearing_date?: string;
  status?: HearingStatus | string;
  notes?: string;
}

export interface EcourtCaseBundle {
  case: EcourtCase;
  hearings: EcourtHearing[];
  raw_case?: unknown;
  raw_hearings?: unknown;
}

export interface CourtApiTestResult {
  ok: boolean;
  balance_inr?: number;
  message?: string;
}

export interface CourtApiAdapter {
  fetchCaseByCnr(cnr: string): Promise<EcourtCaseBundle>;
  testConnection(): Promise<CourtApiTestResult>;
}

export interface CourtApiConfigRow {
  id: string;
  provider: string;
  api_key: string;
  base_url: string;
  is_active: boolean;
  rate_limit_per_min: number;
  credit_balance_inr: number | null;
  last_test_at: string | null;
  last_test_status: string | null;
}
