import { createHash } from "crypto";
import fetch from "node-fetch";
import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from "./config/credentials";

type ModerationStatus = "pending" | "approved" | "rejected";

interface GoogleReviewSource {
  id: string;
  provider: "google_places";
  source_location_id: string;
  business_name: string;
  api_key: string;
}

interface ExistingReviewRow {
  id: string;
  external_review_id: string;
  moderation_status: ModerationStatus;
}

interface GooglePlaceReview {
  author_name?: string;
  profile_photo_url?: string;
  rating?: number;
  text?: string;
  time?: number;
  author_url?: string;
}

interface GooglePlaceDetailsResponse {
  status: string;
  error_message?: string;
  result?: {
    reviews?: GooglePlaceReview[];
  };
}

interface SyncSourceResult {
  sourceId: string;
  businessName: string;
  sourceLocationId: string;
  importedCount: number;
  updatedCount: number;
  totalFetched: number;
  status: "success" | "failed";
  error?: string;
}

interface SyncOptions {
  sourceId?: string;
}

interface SyncSummary {
  success: boolean;
  totalSources: number;
  completedSources: number;
  failedSources: number;
  totalFetched: number;
  totalImported: number;
  totalUpdated: number;
  results: SyncSourceResult[];
}

const GOOGLE_PROVIDER = "google_places";
const GOOGLE_FIELDS = "name,reviews";

const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const buildExternalReviewId = (
  sourceLocationId: string,
  review: GooglePlaceReview
): string => {
  const seed = [
    sourceLocationId,
    review.author_url || review.author_name || "unknown-author",
    String(review.time || 0),
    String(review.rating || 0),
    review.text || "",
  ].join("|");
  return createHash("sha1").update(seed).digest("hex");
};

const upsertReviewForSource = async (
  source: GoogleReviewSource,
  review: GooglePlaceReview,
  existingByExternalId: Map<string, ExistingReviewRow>
): Promise<"imported" | "updated"> => {
  const externalReviewId = buildExternalReviewId(source.source_location_id, review);
  const existing = existingByExternalId.get(externalReviewId);
  const moderationStatus: ModerationStatus = existing?.moderation_status || "pending";

  const payload = {
    provider: GOOGLE_PROVIDER,
    source_location_id: source.source_location_id,
    external_review_id: externalReviewId,
    reviewer_name: review.author_name || "Google User",
    reviewer_photo_url: review.profile_photo_url || null,
    rating: Number(review.rating || 0),
    review_text: review.text || "",
    review_time: review.time ? new Date(review.time * 1000).toISOString() : null,
    raw_payload: review as unknown as Record<string, unknown>,
    moderation_status: moderationStatus,
    is_active: true,
    is_deleted: false,
  };

  if (existing) {
    const { error } = await (supabaseAdmin as any)
      .from("cms_external_reviews")
      .update(payload)
      .eq("id", existing.id);

    if (error) throw error;
    return "updated";
  }

  const { data: insertedRow, error } = await (supabaseAdmin as any)
    .from("cms_external_reviews")
    .insert(payload)
    .select("id, external_review_id, moderation_status")
    .single();

  if (error) throw error;
  if (insertedRow?.external_review_id && insertedRow?.id) {
    existingByExternalId.set(insertedRow.external_review_id, {
      id: insertedRow.id,
      external_review_id: insertedRow.external_review_id,
      moderation_status: insertedRow.moderation_status as ModerationStatus,
    });
  }
  return "imported";
};

const updateSourceSyncStatus = async (
  sourceId: string,
  status: "success" | "failed",
  syncError?: string
) => {
  const { error } = await (supabaseAdmin as any)
    .from("cms_review_sources")
    .update({
      last_synced_at: new Date().toISOString(),
      last_sync_status: status,
      last_sync_error: syncError || null,
    })
    .eq("id", sourceId);

  if (error) {
    console.error(`Failed to update sync status for source ${sourceId}:`, error.message);
  }
};

const syncOneSource = async (source: GoogleReviewSource): Promise<SyncSourceResult> => {
  try {
    const placeDetailsUrl =
      "https://maps.googleapis.com/maps/api/place/details/json" +
      `?place_id=${encodeURIComponent(source.source_location_id)}` +
      `&fields=${encodeURIComponent(GOOGLE_FIELDS)}` +
      `&key=${encodeURIComponent(source.api_key)}`;

    const response = await fetch(placeDetailsUrl);
    if (!response.ok) {
      throw new Error(`Google API request failed with status ${response.status}`);
    }

    const payload = (await response.json()) as GooglePlaceDetailsResponse;
    if (payload.status !== "OK") {
      const detail = payload.error_message ? `: ${payload.error_message}` : "";
      throw new Error(`Google API status ${payload.status}${detail}`);
    }

    const reviews = payload.result?.reviews || [];

    const { data: existingRows, error: existingError } = await (supabaseAdmin as any)
      .from("cms_external_reviews")
      .select("id, external_review_id, moderation_status")
      .eq("provider", GOOGLE_PROVIDER)
      .eq("source_location_id", source.source_location_id)
      .eq("is_deleted", false);

    if (existingError) throw existingError;

    const existingByExternalId = new Map<string, ExistingReviewRow>(
      (existingRows || []).map((row: ExistingReviewRow) => [row.external_review_id, row])
    );

    let importedCount = 0;
    let updatedCount = 0;

    for (const review of reviews) {
      const operation = await upsertReviewForSource(source, review, existingByExternalId);
      if (operation === "imported") importedCount += 1;
      if (operation === "updated") updatedCount += 1;
    }

    await updateSourceSyncStatus(source.id, "success");

    return {
      sourceId: source.id,
      businessName: source.business_name,
      sourceLocationId: source.source_location_id,
      importedCount,
      updatedCount,
      totalFetched: reviews.length,
      status: "success",
    };
  } catch (error: any) {
    const message = error?.message || "Unknown sync error";
    await updateSourceSyncStatus(source.id, "failed", message);

    return {
      sourceId: source.id,
      businessName: source.business_name,
      sourceLocationId: source.source_location_id,
      importedCount: 0,
      updatedCount: 0,
      totalFetched: 0,
      status: "failed",
      error: message,
    };
  }
};

export const syncGoogleReviewsFromSources = async (
  options: SyncOptions = {}
): Promise<SyncSummary> => {
  const { sourceId } = options;

  let query = (supabaseAdmin as any)
    .from("cms_review_sources")
    .select("id, provider, source_location_id, business_name, api_key")
    .eq("provider", GOOGLE_PROVIDER)
    .eq("is_active", true)
    .eq("is_deleted", false);

  if (sourceId) {
    query = query.eq("id", sourceId);
  }

  const { data: sources, error } = await query;
  if (error) throw error;

  const sourceRows = (sources || []) as GoogleReviewSource[];
  const results: SyncSourceResult[] = [];

  for (const source of sourceRows) {
    const result = await syncOneSource(source);
    results.push(result);
  }

  const failedSources = results.filter((item) => item.status === "failed").length;
  const totalFetched = results.reduce((acc, item) => acc + item.totalFetched, 0);
  const totalImported = results.reduce((acc, item) => acc + item.importedCount, 0);
  const totalUpdated = results.reduce((acc, item) => acc + item.updatedCount, 0);

  return {
    success: failedSources === 0,
    totalSources: sourceRows.length,
    completedSources: results.length - failedSources,
    failedSources,
    totalFetched,
    totalImported,
    totalUpdated,
    results,
  };
};
