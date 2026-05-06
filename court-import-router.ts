import { Router } from "express";
import { createClient, type User } from "@supabase/supabase-js";

import { SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "./config/credentials";
import { fetchByCnr, importCaseFromCnr } from "./services/court-api/import-service";
import { getActiveAdapter, loadActiveConfig } from "./services/court-api/registry";
import { backfillHearingStatuses, syncAllImportedCases, syncImportedCase } from "./services/court-api/sync-service";

const router = Router();
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function getBearerToken(authorizationHeader?: string): string | null {
  if (!authorizationHeader) return null;
  const [scheme, token] = authorizationHeader.split(" ");
  if (!scheme || scheme.toLowerCase() !== "bearer" || !token) return null;
  return token.trim();
}

async function getUserFromRequest(authHeader: string | undefined): Promise<User | null> {
  const token = getBearerToken(authHeader);
  if (!token) return null;
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user;
}

async function isAdmin(userId: string): Promise<boolean> {
  const { data, error } = await supabaseService
    .from("user_roles")
    .select("roles(name)")
    .eq("user_id", userId)
    .eq("is_active", true)
    .eq("is_deleted", false);
  if (error) return false;
  const names = (data || [])
    .map((row: any) => (Array.isArray(row.roles) ? row.roles[0]?.name : row.roles?.name))
    .filter((name: any): name is string => typeof name === "string");
  return names.some((n) => n === "Admin" || n === "Super Admin");
}

// ── 1. Fetch case + hearings from API by CNR (used by Add Case dialog) ─────
router.post("/api/court/fetch-by-cnr", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });

  const cnr = String(req.body?.cnr || "").trim();
  if (!cnr) return res.status(400).json({ error: "cnr is required" });

  try {
    const { bundle } = await fetchByCnr(cnr);
    return res.json(bundle);
  } catch (error: any) {
    return res.status(502).json({ error: error?.message || "Failed to fetch from eCourts API" });
  }
});

// ── 2. Import — creates order_cases + case_hearings rows ───────────────────
router.post("/api/court/import", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });

  const {
    cnr,
    service_order_id,
    assigned_employee_ids,
    selected_hearing_external_ids,
    case_title,
    case_number,
    case_type,
    filing_date,
    status,
    notes,
  } = req.body || {};

  if (!cnr || !service_order_id) {
    return res.status(400).json({ error: "cnr and service_order_id are required" });
  }

  try {
    const result = await importCaseFromCnr({
      cnr: String(cnr),
      service_order_id: String(service_order_id),
      assigned_employee_ids: Array.isArray(assigned_employee_ids) ? assigned_employee_ids : [],
      selected_hearing_external_ids: Array.isArray(selected_hearing_external_ids)
        ? selected_hearing_external_ids
        : [],
      case_title,
      case_number,
      case_type,
      filing_date,
      status,
      notes,
    });
    return res.json(result);
  } catch (error: any) {
    return res.status(500).json({ error: error?.message || "Import failed" });
  }
});

// ── 3. Manual re-sync for one imported case ────────────────────────────────
router.post("/api/court/sync/:orderCaseId", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });

  const orderCaseId = req.params.orderCaseId;
  if (!orderCaseId) return res.status(400).json({ error: "orderCaseId is required" });

  try {
    const result = await syncImportedCase(orderCaseId, "manual");
    return res.json(result);
  } catch (error: any) {
    return res.status(500).json({ error: error?.message || "Sync failed" });
  }
});

// ── 3b. Fix hearing statuses for one case (DB-only, no API call) ──────────
// Use this to immediately correct already-imported hearings without re-fetching.
router.post("/api/court/fix-hearing-statuses/:orderCaseId", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });

  const orderCaseId = req.params.orderCaseId;
  if (!orderCaseId) return res.status(400).json({ error: "orderCaseId is required" });

  try {
    await backfillHearingStatuses(orderCaseId);
    return res.json({ ok: true });
  } catch (error: any) {
    return res.status(500).json({ error: error?.message || "Backfill failed" });
  }
});

// ── 4. Read current eCourts API config (configured? balance?) ──────────────
// Returns the api_key (stored plain text per project decision) for admins so
// the Settings form can prefill the field on edit. Endpoint is gated by isAdmin().
router.get("/api/court-api/config", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  if (!(await isAdmin(user.id))) return res.status(403).json({ error: "Admins only" });

  const config = await loadActiveConfig();
  return res.json({
    configured: !!config,
    api_key: config?.api_key ?? "",
    base_url: config?.base_url ?? "https://webapi.ecourtsindia.com/api/partner",
    rate_limit_per_min: config?.rate_limit_per_min ?? 30,
    credit_balance_inr: config?.credit_balance_inr ?? null,
    last_test_at: config?.last_test_at ?? null,
    last_test_status: config?.last_test_status ?? null,
  });
});

// ── 5. Save / update encrypted API key ─────────────────────────────────────
router.post("/api/court-api/config", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  if (!(await isAdmin(user.id))) return res.status(403).json({ error: "Admins only" });

  const apiKey = String(req.body?.api_key || "").trim();
  const baseUrl = String(req.body?.base_url || "https://webapi.ecourtsindia.com/api/partner").trim();
  const rateLimit = Number(req.body?.rate_limit_per_min) || 30;
  if (!apiKey) return res.status(400).json({ error: "api_key is required" });

  const payload = {
    provider: "ecourtsindia",
    api_key: apiKey,
    base_url: baseUrl,
    rate_limit_per_min: rateLimit,
    is_active: true,
    updated_at: new Date().toISOString(),
  };

  const { error } = await supabaseService
    .from("court_api_configs")
    .upsert(payload, { onConflict: "provider" });
  if (error) return res.status(500).json({ error: error.message });

  return res.json({ ok: true });
});

// ── 5b. Disable eCourts integration (sets is_active = false) ───────────────
router.delete("/api/court-api/config", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  if (!(await isAdmin(user.id))) return res.status(403).json({ error: "Admins only" });

  const { error } = await supabaseService
    .from("court_api_configs")
    .update({ is_active: false, updated_at: new Date().toISOString() })
    .eq("provider", "ecourtsindia");
  if (error) return res.status(500).json({ error: error.message });
  return res.json({ ok: true });
});

// ── 6. Test the configured key (cheap call) ────────────────────────────────
router.post("/api/court-api/test", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  if (!(await isAdmin(user.id))) return res.status(403).json({ error: "Admins only" });

  const adapter = await getActiveAdapter();
  if (!adapter) return res.status(400).json({ ok: false, message: "API key not configured" });

  const result = await adapter.testConnection();

  await supabaseService
    .from("court_api_configs")
    .update({
      last_test_at: new Date().toISOString(),
      last_test_status: result.ok ? "ok" : "failed",
      credit_balance_inr: typeof result.balance_inr === "number" ? result.balance_inr : undefined,
    })
    .eq("provider", "ecourtsindia");

  return res.json(result);
});

// ── 7. Manually trigger full nightly sync (admin) ─────────────────────────
router.post("/api/court/sync-all", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  if (!(await isAdmin(user.id))) return res.status(403).json({ error: "Admins only" });

  // Fire-and-forget so the HTTP response returns immediately
  syncAllImportedCases()
    .then((r) => console.log("[court-sync] Manual trigger done:", r))
    .catch((e) => console.error("[court-sync] Manual trigger failed:", e?.message));

  return res.json({ ok: true, message: "Sync started" });
});

// ── 8. Recent sync runs (admin diagnostics) ────────────────────────────────
router.get("/api/court/sync-runs", async (req, res) => {
  const user = await getUserFromRequest(req.headers.authorization);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  if (!(await isAdmin(user.id))) return res.status(403).json({ error: "Admins only" });

  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const { data, error } = await supabaseService
    .from("court_sync_runs")
    .select("*")
    .order("started_at", { ascending: false })
    .limit(limit);
  if (error) return res.status(500).json({ error: error.message });
  return res.json({ runs: data || [] });
});

export const courtImportRouter = router;
