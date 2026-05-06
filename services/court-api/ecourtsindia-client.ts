import fetch from "node-fetch";

import { mapApiCase, mapApiHearings } from "./field-mappers";
import type {
  CourtApiAdapter,
  CourtApiConfigRow,
  CourtApiTestResult,
  EcourtCaseBundle,
} from "./types";

// Real eCourtsIndia API endpoints (confirmed via working Postman call):
//   curl -H "Authorization: Bearer eci_live_..." \
//        https://webapi.ecourtsindia.com/api/partner/case/GJSR080000252022
// Configure the base URL as `https://webapi.ecourtsindia.com/api/partner` in
// Settings → Integrations. These paths are appended to that base URL.
const ENDPOINTS = {
  account: "/account",
  caseByCnr: (cnr: string) => `/case/${encodeURIComponent(cnr)}`,
  hearingsByCnr: (cnr: string) => `/case/${encodeURIComponent(cnr)}/hearings`,
};

export class EcourtsIndiaClient implements CourtApiAdapter {
  private readonly baseUrl: string;
  private readonly token: string;

  constructor(config: CourtApiConfigRow) {
    if (!config.api_key) {
      throw new Error("eCourts API key is missing. Configure it in Settings → Integrations.");
    }
    this.baseUrl = config.base_url.replace(/\/+$/, "");
    // Tolerate users pasting the whole "Bearer eci_live_..." header value into
    // the token field — strip the prefix so we don't end up with double "Bearer".
    this.token = config.api_key.trim().replace(/^Bearer\s+/i, "");
  }

  private async request<T>(path: string): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${this.token}`,
        Accept: "application/json",
        "User-Agent": "LegalPrime/1.0 (+https://legalprime.in)",
      },
    });

    const contentType = response.headers.get("content-type") || "";
    const isJson = contentType.includes("application/json");

    if (!response.ok) {
      // If the response is HTML, the request hit the wrong host (e.g. Cloudflare
      // challenge on the public website) instead of the API server. Surface a
      // clear, short message instead of dumping the entire HTML challenge page.
      if (!isJson) {
        throw new Error(
          `eCourts API ${response.status} on ${path}: hit a non-API host (got HTML response). ` +
            `The configured Base URL "${this.baseUrl}" may be wrong — check your eCourtsIndia dashboard for the real API host (often api.ecourtsindia.com) and update Settings → Integrations.`
        );
      }
      const body = await response.text().catch(() => "");
      throw new Error(`eCourts API ${response.status} on ${path}: ${body || response.statusText}`);
    }

    if (!isJson) {
      throw new Error(
        `eCourts API on ${path}: expected JSON but got "${contentType}". ` +
          `The configured Base URL "${this.baseUrl}" likely points at the website, not the API. Check your dashboard for the real API host.`
      );
    }

    return (await response.json()) as T;
  }

  async testConnection(): Promise<CourtApiTestResult> {
    try {
      const data = await this.request<any>(ENDPOINTS.account);
      const balance =
        typeof data?.balance_inr === "number"
          ? data.balance_inr
          : typeof data?.credits === "number"
            ? data.credits
            : typeof data?.balance === "number"
              ? data.balance
              : undefined;
      return { ok: true, balance_inr: balance, message: "Connected" };
    } catch (error: any) {
      return { ok: false, message: error?.message || "Connection failed" };
    }
  }

  async fetchCaseByCnr(cnr: string): Promise<EcourtCaseBundle> {
    const trimmed = cnr.trim();
    if (!trimmed) {
      throw new Error("CNR number is required");
    }

    // eCourtsIndia returns hearings inline at data.courtCaseData.historyOfCaseHearings,
    // so a single request is enough — no need to call /hearings.
    const caseRaw = await this.request<any>(ENDPOINTS.caseByCnr(trimmed));

    const mappedCase = mapApiCase(caseRaw, trimmed);
    // Hearings live at data.courtCaseData.historyOfCaseHearings — mapApiHearings
    // walks several common shapes so passing the inner courtCaseData (or the whole
    // payload) both work.
    const courtCaseData =
      caseRaw?.data?.courtCaseData ??
      caseRaw?.courtCaseData ??
      caseRaw?.data ??
      caseRaw;
    const mappedHearings = mapApiHearings(courtCaseData, trimmed);

    return {
      case: mappedCase,
      hearings: mappedHearings,
      raw_case: caseRaw,
      raw_hearings: null,
    };
  }
}
