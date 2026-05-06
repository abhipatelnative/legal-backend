import cron from "node-cron";

import { syncAllImportedCases } from "./sync-service";

let started = false;

// Daily at 2:00 AM IST (server time). Walks every order_cases row where
// source='ecourtsindia' and inserts any new hearings the court has added.
export function startCourtSyncScheduler(): void {
  if (started) return;
  started = true;

  cron.schedule(
    "0 2 * * *",
    async () => {
      const startedAt = new Date().toISOString();
      console.log(`[court-sync] Cron fired at ${startedAt}`);
      try {
        const result = await syncAllImportedCases();
        console.log(
          `[court-sync] Completed: total=${result.total} succeeded=${result.succeeded} failed=${result.failed}`
        );
      } catch (error: any) {
        console.error("[court-sync] Cron run failed:", error?.message || error);
      }
    },
    { timezone: "Asia/Kolkata" }
  );

  console.log("[court-sync] Scheduler registered: 0 2 * * * (2 AM IST daily)");
}
