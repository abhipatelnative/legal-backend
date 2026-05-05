import cron from "node-cron";
import dotenv from "dotenv";
import dayjs from "dayjs";
import express from "express";
import cors from "cors";
import { createClient } from "@supabase/supabase-js";
import customParseFormat from "dayjs/plugin/customParseFormat";

import { syncPunchRecords, syncPunchRecordsByDateRange, syncPunchRecordsByDateRangeAndUserId, processSyncRequests } from "./punch-sync";
import { exportAttendanceCSV } from "./attendance-csv";
import { processAttendanceToCSV } from "./attendance-processor-csv";
import { sendEventNotifications } from "./event-notification-service";
import { sendTestEmailToAddress, sendNotificationEmails, sendEmailsToAddresses, getEmailTemplateById, substituteTemplateVars, substituteTemplateVarsGeneric } from "./email-service";
import { getPublicVapidKey, subscribeUser, unsubscribeUser, sendPushNotificationsToUsers } from "./web-push-service";
import { runPushSender, runEmailSender, runSmsSender, runWhatsAppSender } from "./notification-senders";
import { sendSmsMessage, sendWhatsAppMessage } from "./messaging-channel-service";
import { checkAndNotifyLowStock } from "./low-stock-notification-service";
import {
    notifyExpenseSubmitted,
    notifyExpenseApproved,
    notifyExpenseRejected
} from "./expense-notification-service";
// import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';
import { syncGoogleReviewsFromSources } from "./cms-google-reviews-service";
import { runGoogleMapsScrapeTest } from "./google-maps-scrape-test-service";
import { scheduledNotificationService } from "./scheduled-notification-service";
import { processRecurringNotifications, computeInitialNextRunAt, sendScheduleNow } from "./recurring-notification-service";
import { getReportDefinitions, getReportDateRangePresets } from "./report-notification-service";
import { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } from './config/credentials';
import { twoFactorRouter } from "./two-factor-router";
import { aiRouter } from "./ai/router";

dotenv.config();
dayjs.extend(customParseFormat);

// Supabase client (anon key; RLS applies)
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
// Service-role client for server-only reads that must bypass RLS (e.g. auto-rules list for Settings)
const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

// Supabase connection verified implicitly on first query.
// MySQL connection is established on the first sync cycle using
// credentials stored in Settings → Biometric Devices.
async function initializeDatabases() {
    console.log('Database initialization: Supabase ready. MySQL will connect on first sync cycle.');
}


// Initialize Express app
const app = express();

const PORT = process.env.PORT || 3001;

app.use(cors());
app.use(express.json({ limit: "10mb" }));
app.use(twoFactorRouter);
app.use(aiRouter);

function sanitizePdfFileName(fileName?: string) {
    const baseName = (fileName || "document.pdf").replace(/[^\w.\-() ]+/g, "_");
    return baseName.toLowerCase().endsWith(".pdf") ? baseName : `${baseName}.pdf`;
}

// Test/Health check endpoint
app.get('/api/test', (req, res) => {
    res.status(200).json({
        success: true,
        message: 'Backend server is running',
        timestamp: new Date().toISOString()
    });
});

// Test expense notification endpoint (for debugging)
app.get('/api/expenses/test', (req, res) => {
    res.status(200).json({
        success: true,
        message: 'Expense notification endpoints are registered',
        endpoints: [
            'POST /api/expenses/notify-submitted',
            'POST /api/expenses/notify-approved',
            'POST /api/expenses/notify-rejected'
        ],
        timestamp: new Date().toISOString()
    });
});

// Test email endpoint
app.post('/api/test-email', async (req, res) => {
    try {
        const { email } = req.body;

        if (!email) {
            return res.status(400).json({
                success: false,
                message: 'Email address is required'
            });
        }

        const result = await sendTestEmailToAddress(email);

        if (result.success) {
            return res.status(200).json(result);
        } else {
            return res.status(400).json(result);
        }
    } catch (error: any) {
        console.error('Error in test email endpoint:', error);
        return res.status(500).json({
            success: false,
            message: error.message || 'Internal server error'
        });
    }
});

// app.post("/api/documents/render-pdf", async (req, res) => {
//     let browser;
//     try {
//         const { html, fileName } = req.body || {};

//         if (!html || typeof html !== "string") {
//             return res.status(400).send("HTML content is required");
//         }

//         try {
//             browser = await chromium.launch({
//                 headless: true,
//                 args: ["--no-sandbox", "--disable-setuid-sandbox"],
//             });
//         } catch (launchError: any) {
//             const message = String(launchError?.message || "Failed to launch Chromium for PDF rendering.");
//             if (message.includes("Executable") && message.includes("doesn't exist")) {
//                 return res.status(500).send(
//                     "Playwright Chromium browser binary is missing. Run `cd Backend && npx playwright install chromium` and restart the backend."
//                 );
//             }
//             console.error("Playwright launch error:", launchError);
//             return res.status(500).send(message);
//         }

//         const page = await browser.newPage();
//         await page.emulateMedia({ media: "print" });
//         await page.setContent(html, {
//             waitUntil: "networkidle",
//         });

//         const pdfBuffer = await page.pdf({
//             printBackground: true,
//             preferCSSPageSize: true,
//         });

//         res.setHeader("Content-Type", "application/pdf");
//         res.setHeader("Content-Disposition", `attachment; filename="${sanitizePdfFileName(fileName)}"`);
//         return res.send(Buffer.from(pdfBuffer));
//     } catch (error: any) {
//         console.error("Error rendering document PDF:", error);
//         return res.status(500).send(error?.message || "Failed to render PDF");
//     } finally {
//         if (browser) {
//             await browser.close().catch(() => undefined);
//         }
//     }
// });

// Test SMS (HTTP outbound or Twilio/AWS per notification_channel_settings)
app.post("/api/test-sms", async (req, res) => {
    try {
        const { to, message } = req.body;
        if (!to || typeof to !== "string") {
            return res.status(400).json({ success: false, message: "to (E.164 phone) is required" });
        }
        const body = typeof message === "string" && message.trim() ? message.trim() : "LegalPrime test SMS";
        const result = await sendSmsMessage(to.trim(), body);
        if (result.ok) {
            return res.status(200).json({ success: true, message: result.message, sid: result.sid });
        }
        return res.status(400).json({ success: false, message: result.message });
    } catch (error: any) {
        console.error("test-sms:", error);
        return res.status(500).json({ success: false, message: error.message || "Internal server error" });
    }
});

// Test WhatsApp (HTTP outbound or Twilio SDK per DB settings)
app.post("/api/test-whatsapp", async (req, res) => {
    try {
        const { to, message } = req.body;
        if (!to || typeof to !== "string") {
            return res.status(400).json({ success: false, message: "to (phone or whatsapp:+...) is required" });
        }
        const body = typeof message === "string" && message.trim() ? message.trim() : "LegalPrime test WhatsApp";
        const result = await sendWhatsAppMessage(to.trim(), body);
        if (result.ok) {
            return res.status(200).json({ success: true, message: result.message, sid: result.sid });
        }
        return res.status(400).json({ success: false, message: result.message });
    } catch (error: any) {
        console.error("test-whatsapp:", error);
        return res.status(500).json({ success: false, message: error.message || "Internal server error" });
    }
});

// Test web push to one user (must have an active browser subscription)
app.post("/api/test-push", async (req, res) => {
    try {
        const { userId, title, message } = req.body;
        if (!userId || typeof userId !== "string") {
            return res.status(400).json({ success: false, message: "userId is required" });
        }
        const result = await sendPushNotificationsToUsers([userId], {
            title: typeof title === "string" && title.trim() ? title.trim() : "Test notification",
            message: typeof message === "string" && message.trim() ? message.trim() : "LegalPrime test web push",
            url: "/notifications",
        });
        return res.status(200).json({
            success: true,
            sent: result.success,
            failed: result.failed,
            errors: result.errors,
        });
    } catch (error: any) {
        console.error("test-push:", error);
        return res.status(500).json({ success: false, message: error.message || "Internal server error" });
    }
});

// ============================================
// Web Push Notification Endpoints
// ============================================

// Get public VAPID key
app.get("/api/public-vapid-key", (req, res) => {
    try {
        const publicKey = getPublicVapidKey();
        res.json({
            success: true,
            publicKey: publicKey
        });
    } catch (error: any) {
        res.status(500).json({
            success: false,
            message: error.message || "Failed to get VAPID key"
        });
    }
});

// Subscribe to push notifications
app.post("/api/subscribe", async (req, res) => {
    try {
        const { userId, subscription, deviceInfo } = req.body;

        if (!userId || !subscription || !subscription.endpoint || !subscription.keys) {
            return res.status(400).json({
                success: false,
                message: "userId, subscription.endpoint, and subscription.keys are required"
            });
        }

        const result = await subscribeUser(userId, subscription, deviceInfo);

        if (result.success) {
            res.status(200).json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (error: any) {
        console.error("Error in subscribe endpoint:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Internal server error"
        });
    }
});

// Unsubscribe from push notifications
app.post("/api/unsubscribe", async (req, res) => {
    try {
        const { endpoint } = req.body;

        if (!endpoint) {
            return res.status(400).json({
                success: false,
                message: "endpoint is required"
            });
        }

        const result = await unsubscribeUser(endpoint);

        if (result.success) {
            res.status(200).json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (error: any) {
        console.error("Error in unsubscribe endpoint:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Internal server error"
        });
    }
});

// ============================================
// Navigation: 3-Level Hierarchy Endpoints
// ============================================

interface AppModuleGroup {
    id: string;
    name: string;
    slug: string;
    display_order: number;
    is_active: boolean;
}

interface AppModule {
    id: string;
    name: string;
    slug: string;
    icon_name: string | null;
    icon_color: string | null;
    module_group_id: string | null;
    display_order: number;
    is_active: boolean;
}

interface AppPage {
    id: string;
    title: string;
    url: string;
    module_id: string | null;
    module_group_id: string | null;
    display_order: number;
    is_active: boolean;
    resource_key: string | null;
    icon_name: string | null;
    icon_color: string | null;
}

interface Permission {
    id: string;
    name: string;
    module: string;
    description: string | null;
}

// ── Permissions ─────────────────────────────────────────────────────────────

app.get("/api/permissions", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("permissions")
            .select("*")
            .order("module", { ascending: true })
            .order("name", { ascending: true });
        if (error) throw error;
        res.json({ success: true, data: data || [] });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// ── Module Groups ──────────────────────────────────────────────────────────

app.get("/api/app-module-groups", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_module_groups")
            .select("*")
            .order("display_order", { ascending: true });
        if (error) throw error;
        res.json({ success: true, data: data || [] });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.post("/api/app-module-groups", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_module_groups")
            .insert(req.body)
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.put("/api/app-module-groups/:id", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_module_groups")
            .update(req.body)
            .eq("id", req.params.id)
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.delete("/api/app-module-groups/:id", async (req, res) => {
    try {
        const { error } = await supabaseService
            .from("app_module_groups")
            .delete()
            .eq("id", req.params.id);
        if (error) throw error;
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.patch("/api/app-module-groups/reorder", async (req, res) => {
    try {
        const items = req.body as { id: string; display_order: number }[];
        const promises = items.map(item =>
            supabaseService
                .from("app_module_groups")
                .update({ display_order: item.display_order })
                .eq("id", item.id)
        );
        await Promise.all(promises);
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// ── Modules ─────────────────────────────────────────────────────────────────

app.get("/api/app-modules", async (req, res) => {
    try {
        let query = supabaseService
            .from("app_modules")
            .select("*, app_module_groups(id, name, slug)");

        if (req.query.module_group_id) {
            query = query.eq("module_group_id", req.query.module_group_id);
        }

        const { data, error } = await query.order("display_order", { ascending: true });
        if (error) throw error;
        res.json({ success: true, data: data || [] });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.post("/api/app-modules", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_modules")
            .insert(req.body)
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.put("/api/app-modules/:id", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_modules")
            .update(req.body)
            .eq("id", req.params.id)
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.delete("/api/app-modules/:id", async (req, res) => {
    try {
        const { error } = await supabaseService
            .from("app_modules")
            .delete()
            .eq("id", req.params.id);
        if (error) throw error;
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.patch("/api/app-modules/reorder", async (req, res) => {
    try {
        const items = req.body as { id: string; display_order: number }[];
        const promises = items.map(item =>
            supabaseService
                .from("app_modules")
                .update({ display_order: item.display_order })
                .eq("id", item.id)
        );
        await Promise.all(promises);
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// ============================================================================
// Module -> DB Table mappings (for Admin Dashboard "Module-wise Data Size")
// ============================================================================

app.get("/api/app-module-tables", async (req, res) => {
    try {
        let query = supabaseService
            .from("app_module_tables")
            .select("id, module_id, table_name, created_at");

        if (req.query.module_id) {
            query = query.eq("module_id", req.query.module_id);
        }

        const { data, error } = await query.order("table_name", { ascending: true });
        if (error) throw error;
        res.json({ success: true, data: data || [] });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.post("/api/app-module-tables", async (req, res) => {
    try {
        const { module_id, table_name } = req.body as { module_id?: string; table_name?: string };
        if (!module_id || !table_name) {
            return res.status(400).json({ success: false, message: "module_id and table_name are required" });
        }

        // Validate table exists in public schema to block typos
        const { data: existsRows, error: existsErr } = await supabaseService
            .from("information_schema.tables" as any)
            .select("table_name")
            .eq("table_schema", "public")
            .eq("table_name", table_name)
            .limit(1);

        // Fallback validation via RPC (information_schema reads through PostgREST are not always allowed)
        if (existsErr || !existsRows || existsRows.length === 0) {
            const { data: sizes, error: rpcErr } = await supabaseService.rpc("get_table_sizes", { tables: [table_name] });
            if (rpcErr) throw rpcErr;
            if (!sizes || sizes.length === 0) {
                return res.status(400).json({ success: false, message: `Table "${table_name}" does not exist in the public schema` });
            }
        }

        const { data, error } = await supabaseService
            .from("app_module_tables")
            .insert({ module_id, table_name })
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.delete("/api/app-module-tables/:id", async (req, res) => {
    try {
        const { error } = await supabaseService
            .from("app_module_tables")
            .delete()
            .eq("id", req.params.id);
        if (error) throw error;
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// List of public-schema tables for the "add mapping" dropdown in the UI.
app.get("/api/admin/db-tables", async (_req, res) => {
    try {
        const { data, error } = await supabaseService.rpc("get_public_tables");
        if (error) {
            // Graceful fallback: derive from existing mappings + a known seed list.
            const { data: mapped } = await supabaseService
                .from("app_module_tables")
                .select("table_name");
            const names = Array.from(new Set((mapped || []).map((r: any) => r.table_name))).sort();
            return res.json({ success: true, data: names });
        }
        res.json({ success: true, data: (data || []).map((r: any) => r.table_name) });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// Aggregated size per module.
app.get("/api/admin/module-sizes", async (_req, res) => {
    try {
        const { data: modules, error: modErr } = await supabaseService
            .from("app_modules")
            .select("id, name, slug, module_group_id, app_module_groups(id, name, slug)")
            .eq("is_active", true);
        if (modErr) throw modErr;

        const { data: mappings, error: mapErr } = await supabaseService
            .from("app_module_tables")
            .select("module_id, table_name");
        if (mapErr) throw mapErr;

        const mappingsByModule = new Map<string, string[]>();
        const allMappedTables = new Set<string>();
        for (const row of mappings || []) {
            allMappedTables.add(row.table_name);
            const list = mappingsByModule.get(row.module_id) || [];
            list.push(row.table_name);
            mappingsByModule.set(row.module_id, list);
        }

        // Bucket mappings (module_id -> bucket_name[])
        const { data: bucketMappings, error: bMapErr } = await supabaseService
            .from("app_module_buckets")
            .select("module_id, bucket_name");
        if (bMapErr) throw bMapErr;

        const bucketsByModule = new Map<string, string[]>();
        const allMappedBuckets = new Set<string>();
        for (const row of bucketMappings || []) {
            allMappedBuckets.add(row.bucket_name);
            const list = bucketsByModule.get(row.module_id) || [];
            list.push(row.bucket_name);
            bucketsByModule.set(row.module_id, list);
        }

        // Get ALL public schema tables
        let allPublicTables: string[] = [];
        const { data: publicTables, error: ptErr } = await supabaseService.rpc("get_public_tables");
        if (!ptErr && publicTables) {
            allPublicTables = publicTables.map((r: any) => r.table_name);
        }

        // Get ALL storage buckets
        let allBuckets: string[] = [];
        const { data: storageBuckets, error: sbErr } = await supabaseService.rpc("get_storage_buckets");
        if (!sbErr && storageBuckets) {
            allBuckets = storageBuckets.map((r: any) => r.bucket_name);
        }

        // Find unmapped tables and unmapped buckets
        const unmappedTables = allPublicTables.filter(t => !allMappedTables.has(t));
        const unmappedBuckets = allBuckets.filter(b => !allMappedBuckets.has(b));

        // Get sizes for ALL tables (mapped + unmapped)
        const allTablesList = Array.from(new Set([...allMappedTables, ...unmappedTables]));
        const sizeByTable = new Map<string, number>();
        if (allTablesList.length > 0) {
            const { data: sizes, error: sizeErr } = await supabaseService.rpc("get_table_sizes", { tables: allTablesList });
            if (sizeErr) throw sizeErr;
            for (const row of sizes || []) {
                sizeByTable.set(row.table_name, Number(row.total_bytes) || 0);
            }
        }

        // Get sizes for ALL buckets (mapped + unmapped)
        const allBucketsList = Array.from(new Set([...allMappedBuckets, ...unmappedBuckets]));
        const sizeByBucket = new Map<string, number>();
        if (allBucketsList.length > 0) {
            const { data: bucketSizes, error: bSizeErr } = await supabaseService.rpc("get_bucket_sizes", { buckets: allBucketsList });
            if (bSizeErr) throw bSizeErr;
            for (const row of bucketSizes || []) {
                sizeByBucket.set(row.bucket_name, Number(row.total_bytes) || 0);
            }
        }

        const result = (modules || [])
            .map((m: any) => {
                const tables = mappingsByModule.get(m.id) || [];
                const tableEntries = tables
                    .map(name => ({ name, bytes: sizeByTable.get(name) || 0 }))
                    .sort((a, b) => b.bytes - a.bytes);
                const buckets = bucketsByModule.get(m.id) || [];
                const bucketEntries = buckets
                    .map(name => ({ name, bytes: sizeByBucket.get(name) || 0 }))
                    .sort((a, b) => b.bytes - a.bytes);
                const tablesTotal = tableEntries.reduce((sum, t) => sum + t.bytes, 0);
                const bucketsTotal = bucketEntries.reduce((sum, b) => sum + b.bytes, 0);
                return {
                    module_id: m.id,
                    module_name: m.name,
                    slug: m.slug,
                    group_name: m.app_module_groups?.name || null,
                    total_bytes: tablesTotal + bucketsTotal,
                    tables: tableEntries,
                    buckets: bucketEntries,
                };
            })
            .filter(m => m.tables.length > 0 || m.buckets.length > 0)
            .sort((a, b) => b.total_bytes - a.total_bytes);

        // Add "Other / Unassigned" entry for unmapped tables and buckets
        if (unmappedTables.length > 0 || unmappedBuckets.length > 0) {
            const otherTableEntries = unmappedTables
                .map(name => ({ name, bytes: sizeByTable.get(name) || 0 }))
                .sort((a, b) => b.bytes - a.bytes);
            const otherBucketEntries = unmappedBuckets
                .map(name => ({ name, bytes: sizeByBucket.get(name) || 0 }))
                .sort((a, b) => b.bytes - a.bytes);
            const otherTotalBytes =
                otherTableEntries.reduce((sum, t) => sum + t.bytes, 0) +
                otherBucketEntries.reduce((sum, b) => sum + b.bytes, 0);
            result.unshift({
                module_id: "__other__",
                module_name: "Other / Unassigned",
                slug: "__other__",
                group_name: null,
                total_bytes: otherTotalBytes,
                tables: otherTableEntries,
                buckets: otherBucketEntries,
            });
        }

        res.json({ success: true, data: result });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// Single Unified Reorder Endpoint for cross-table Drag and Drop
app.patch("/api/app-navigation/reorder", async (req, res) => {
    try {
        const items = req.body as { id: string; type: 'section' | 'module' | 'page'; display_order: number }[];

        const { error } = await supabaseService.rpc('reorder_navigation_items', {
            items: items
        });

        if (error) throw error;
        res.json({ success: true, message: 'Navigation order updated successfully' });
    } catch (err: any) {
        console.error("Failed to execute unified reorder:", err);
        res.status(500).json({ success: false, message: err.message });
    }
});

// ── Pages ───────────────────────────────────────────────────────────────────

app.get("/api/app-pages", async (req, res) => {
    try {
        let query = supabaseService
            .from("app_pages")
            .select("*, app_modules(id, name, slug), app_module_groups(id, name, slug)");

        if (req.query.module_id) {
            query = query.eq("module_id", req.query.module_id);
        }
        if (req.query.module_group_id) {
            query = query.eq("module_group_id", req.query.module_group_id);
        }

        const { data, error } = await query.order("display_order", { ascending: true });
        if (error) throw error;
        res.json({ success: true, data: data || [] });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.post("/api/app-pages", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_pages")
            .insert(req.body)
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.put("/api/app-pages/:id", async (req, res) => {
    try {
        const { data, error } = await supabaseService
            .from("app_pages")
            .update(req.body)
            .eq("id", req.params.id)
            .select()
            .single();
        if (error) throw error;
        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.delete("/api/app-pages/:id", async (req, res) => {
    try {
        const { error } = await supabaseService
            .from("app_pages")
            .delete()
            .eq("id", req.params.id);
        if (error) throw error;
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

app.patch("/api/app-pages/reorder", async (req, res) => {
    try {
        const items = req.body as { id: string; display_order: number }[];
        const promises = items.map(item =>
            supabaseService
                .from("app_pages")
                .update({ display_order: item.display_order })
                .eq("id", item.id)
        );
        await Promise.all(promises);
        res.json({ success: true });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// ============================================
// Notification Management Endpoints
// ============================================

// List auto rules (id, name, email_template_id) for Settings > Email Templates dropdown; uses service role to bypass RLS
// If email_template_id column is missing (older DB), falls back to id+name and returns email_template_id: null
app.get("/api/notifications/auto-rules", async (req, res) => {
    try {
        const { data: dataFull, error: errorFull } = await supabaseService
            .from("notification_auto_rules")
            .select("id, name, email_template_id")
            .order("name");
        if (!errorFull) {
            return res.json({ success: true, rules: dataFull || [] });
        }
        if (errorFull.message?.includes("email_template_id") || (errorFull as any).code === "PGRST204") {
            const { data: dataFallback, error: errorFallback } = await supabaseService
                .from("notification_auto_rules")
                .select("id, name")
                .order("name");
            if (errorFallback) throw errorFallback;
            const rules = (dataFallback || []).map((r: { id: string; name: string }) => ({ ...r, email_template_id: null }));
            return res.json({ success: true, rules });
        }
        throw errorFull;
    } catch (error: any) {
        console.error("Error fetching auto rules:", error);
        res.status(500).json({ success: false, message: error.message || "Failed to fetch auto rules", rules: [] });
    }
});

// Get notifications for a user
app.get("/api/notifications", async (req, res) => {
    try {
        const userId = req.query.userId as string;
        const limit = parseInt(req.query.limit as string) || 50;
        const offset = parseInt(req.query.offset as string) || 0;
        const unreadOnly = req.query.unreadOnly === 'true';

        if (!userId) {
            return res.status(400).json({
                success: false,
                message: "userId is required"
            });
        }

        let query = supabase
            .from("notifications")
            .select("*")
            .eq("user_id", userId)
            .eq("is_deleted", false)
            .or("status.is.null,status.neq.pending") // Exclude scheduled notifications but keep legacy NULL status rows
            .order("created_at", { ascending: false })
            .range(offset, offset + limit - 1);

        if (unreadOnly) {
            // Treat NULL is_read as unread (false)
            query = query.or("is_read.is.null,is_read.eq.false");
        }

        const { data, error } = await query;

        if (error) {
            throw error;
        }

        // Get unread count (treat NULL is_read as unread) while keeping legacy NULL status rows.
        const { data: unreadRows, error: unreadError } = await supabase
            .from("notifications")
            .select("id, is_read, status")
            .eq("user_id", userId)
            .eq("is_deleted", false);

        if (unreadError) {
            throw unreadError;
        }

        const unreadCount = (unreadRows || []).filter((row: any) => row.status !== "pending" && (row.is_read === null || row.is_read === false)).length;

        // Ensure all notifications have is_read set (default to false if null)
        const normalizedNotifications = (data || []).map((n: any) => ({
            ...n,
            is_read: n.is_read ?? false
        }));

        res.json({
            success: true,
            notifications: normalizedNotifications,
            unreadCount
        });
    } catch (error: any) {
        console.error("Error fetching notifications:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Failed to fetch notifications"
        });
    }
});

// Mark notification as read
app.patch("/api/notifications/mark-read", async (req, res) => {
    try {
        const { notificationId, userId } = req.body;

        if (!notificationId || !userId) {
            return res.status(400).json({
                success: false,
                message: "notificationId and userId are required"
            });
        }

        const { data, error } = await supabase
            .from("notifications")
            .update({
                is_read: true,
                read_at: new Date().toISOString()
            })
            .eq("id", notificationId)
            .eq("user_id", userId)
            .select()
            .single();

        if (error) {
            throw error;
        }

        res.json({
            success: true,
            notification: data
        });
    } catch (error: any) {
        console.error("Error marking notification as read:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Failed to mark notification as read"
        });
    }
});

// Mark all notifications as read for a user
app.patch("/api/notifications/mark-all-read", async (req, res) => {
    try {
        const { userId } = req.body;

        if (!userId) {
            return res.status(400).json({
                success: false,
                message: "userId is required"
            });
        }

        const { data, error } = await supabase
            .from("notifications")
            .update({
                is_read: true,
                read_at: new Date().toISOString()
            })
            .eq("user_id", userId)
            .eq("is_read", false)
            .eq("is_deleted", false)
            .select();

        if (error) {
            throw error;
        }

        res.json({
            success: true,
            updatedCount: data?.length || 0
        });
    } catch (error: any) {
        console.error("Error marking all notifications as read:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Failed to mark all notifications as read"
        });
    }
});

// Send notifications to users (single endpoint; dispatches by channel in parallel; one channel failing does not break others)
app.post("/api/notifications/send-push", async (req, res) => {
    try {
        const { userIds, notification, sendEmail, skipPush, emailTemplateId, channels: channelsBody } = req.body;

        // Normalize channels: support legacy sendEmail/skipPush or explicit channels object
        const channels = (() => {
            if (channelsBody && typeof channelsBody === "object") {
                return {
                    push: !!channelsBody.push,
                    email: !!channelsBody.email,
                    sms: !!channelsBody.sms,
                    whatsapp: !!channelsBody.whatsapp,
                };
            }
            return {
                push: !skipPush,
                email: !!sendEmail,
                sms: false,
                whatsapp: false,
            };
        })();

        console.log("[Notifications] send-push received: userIds=" + (userIds?.length ?? 0) + " channels=" + JSON.stringify(channels) + " emailTemplateId=" + (emailTemplateId || "none"));

        if (!userIds || !Array.isArray(userIds) || userIds.length === 0) {
            return res.status(400).json({
                success: false,
                message: "userIds array is required"
            });
        }

        const title = notification?.title ?? req.body.title ?? "";
        const message = notification?.message ?? req.body.message ?? "";
        const actionUrl = notification?.url ?? req.body.actionUrl ?? "/notifications";

        if (!title && !message) {
            return res.status(400).json({
                success: false,
                message: "notification.title and notification.message (or title and message) are required"
            });
        }

        // Build email subject/body once (for email channel)
        let subject = title || "Notification";
        const body = message || title || "";
        let htmlBodyOpt: { htmlBody?: string } | undefined;
        if (emailTemplateId && channels.email) {
            const template = await getEmailTemplateById(emailTemplateId);
            if (template) {
                subject = substituteTemplateVars(template.subject, { title, message: body, action_url: actionUrl });
                const substitutedBody = substituteTemplateVars(template.body, { title, message: body, action_url: actionUrl });
                htmlBodyOpt = { htmlBody: substitutedBody };
                console.log("[Notifications] Using email template; subject length=" + subject.length + " body length=" + substitutedBody.length);
            } else {
                console.warn("[Notifications] emailTemplateId not found: " + emailTemplateId + ", falling back to default");
            }
        }

        const pushPayload = {
            title: notification?.title ?? title,
            message: notification?.message ?? message,
            url: actionUrl || "/",
            icon: notification?.icon,
            badge: notification?.badge,
        };

        // Run all enabled channel senders in parallel; each wrapper never throws
        const [pushResult, emailResult, smsResult, whatsappResult] = await Promise.allSettled([
            channels.push ? runPushSender(userIds, pushPayload) : Promise.resolve(null),
            channels.email ? runEmailSender(userIds, subject, body, actionUrl, htmlBodyOpt) : Promise.resolve(null),
            channels.sms ? runSmsSender(userIds, body) : Promise.resolve(null),
            channels.whatsapp ? runWhatsAppSender(userIds, body) : Promise.resolve(null),
        ]);

        const toResult = (settled: PromiseSettledResult<{ sent: number; failed: number; errors: string[] } | null>): { sent: number; failed: number; errors: string[] } => {
            if (settled.status === "fulfilled" && settled.value) return settled.value;
            if (settled.status === "rejected") return { sent: 0, failed: userIds.length, errors: [settled.reason?.message ?? "Channel error"] };
            return { sent: 0, failed: 0, errors: [] };
        };

        const push = toResult(pushResult);
        const email = toResult(emailResult);
        const sms = toResult(smsResult);
        const whatsapp = toResult(whatsappResult);

        const pushSent = push.sent;
        const emailSent = email.sent;
        const smsSent = sms.sent;
        const whatsappSent = whatsapp.sent;
        const allErrors = [...push.errors, ...email.errors, ...sms.errors, ...whatsapp.errors];
        const totalSent = pushSent + emailSent + smsSent + whatsappSent;
        const totalFailed = push.failed + email.failed + sms.failed + whatsapp.failed;

        const emailRequestedButNoSmtp = channels.email && emailSent === 0 && email.failed === 0 && allErrors.some(e => e?.includes("SMTP") || e?.includes("smtp"));

        res.json({
            success: true,
            sent: totalSent,
            failed: totalFailed,
            errors: allErrors,
            pushSent,
            emailSent,
            smsSent,
            whatsappSent,
            ...(emailRequestedButNoSmtp ? { message: "Email was requested but not sent. Configure SMTP in Settings (e.g. Masters or System Settings)." } : {})
        });
    } catch (error: any) {
        console.error("Error sending notifications:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Failed to send notifications",
            sent: 0,
            failed: 0,
            errors: [error.message]
        });
    }
});

// Send email to external addresses only (hearing participants, witnesses, visitors - not system users).
// Optional triggerCode loads subject/message from notification_auto_rules and substitutes variables.
app.post("/api/notifications/send-external-email", async (req, res) => {
    try {
        const { emails, triggerCode, subject: subjectOverride, message: messageOverride, actionUrl, variables } = req.body;

        if (!emails || !Array.isArray(emails) || emails.length === 0) {
            return res.status(400).json({
                success: false,
                message: "emails array is required and must not be empty"
            });
        }

        const MAX_EXTERNAL_EMAILS = 100;
        const toSend = emails.slice(0, MAX_EXTERNAL_EMAILS);

        let subject = subjectOverride ?? "Notification";
        let message = messageOverride ?? "";

        if (triggerCode) {
            const { data: rule } = await supabaseService
                .from("notification_auto_rules")
                .select("subject_template, message_template, email_template_id")
                .eq("trigger_type", triggerCode)
                .eq("is_active", true)
                .maybeSingle();

            if (rule) {
                const vars: Record<string, string | undefined> = { ...(variables || {}) };
                subject = substituteTemplateVarsGeneric(rule.subject_template || subject, vars);
                message = substituteTemplateVarsGeneric(rule.message_template || message, vars);
                if (rule.email_template_id) {
                    const template = await getEmailTemplateById(rule.email_template_id);
                    if (template) {
                        subject = substituteTemplateVarsGeneric(template.subject, vars);
                        const body = substituteTemplateVarsGeneric(template.body, vars);
                        const result = await sendEmailsToAddresses(toSend, subject, message, actionUrl, { htmlBody: body });
                        return res.json({
                            success: true,
                            sent: result.sent,
                            failed: result.failed,
                            errors: result.errors
                        });
                    }
                }
            }
        }

        const result = await sendEmailsToAddresses(toSend, subject, message, actionUrl);
        res.json({
            success: true,
            sent: result.sent,
            failed: result.failed,
            errors: result.errors
        });
    } catch (error: any) {
        console.error("Error sending external emails:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Failed to send external emails",
            sent: 0,
            failed: 0,
            errors: [error.message]
        });
    }
});

// Send notification emails via SMTP (when email channel is enabled in auto rules)
app.post("/api/notifications/send-email", async (req, res) => {
    try {
        const { userIds, title, message, actionUrl } = req.body;

        if (!userIds || !Array.isArray(userIds) || userIds.length === 0) {
            return res.status(400).json({
                success: false,
                message: "userIds array is required"
            });
        }

        if (!title && !message) {
            return res.status(400).json({
                success: false,
                message: "At least one of title or message is required"
            });
        }

        const subject = title || "Notification";
        const body = message || title || "";

        const result = await sendNotificationEmails(userIds, subject, body, actionUrl);

        res.json({
            success: true,
            sent: result.sent,
            failed: result.failed,
            errors: result.errors
        });
    } catch (error: any) {
        console.error("Error sending notification emails:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Failed to send notification emails",
            sent: 0,
            failed: 0,
            errors: [error.message]
        });
    }
});

// ============================================
// Low Stock Notification Endpoint (for testing/manual trigger)
// ============================================

// Trigger low stock notification check (for testing)
app.post("/api/inventory/check-low-stock", async (req, res) => {
    try {
        const { inventoryItemId, branchId, quantity, itemName, minThreshold } = req.body;

        if (!inventoryItemId) {
            return res.status(400).json({
                success: false,
                message: "inventoryItemId is required"
            });
        }

        // If quantity and item details are provided, use them directly (avoids RLS and timing issues)
        const result = await checkAndNotifyLowStock(
            inventoryItemId,
            branchId,
            quantity,
            itemName,
            minThreshold
        );

        if (result.success) {
            res.status(200).json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (error: any) {
        console.error("Error checking low stock:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Internal server error"
        });
    }
});

// ============================================
// Expense Notification Endpoints
// ============================================

// Notify when expense is submitted/added
app.post("/api/expenses/notify-submitted", async (req, res) => {
    try {
        const { expenseId, expenseNumber, amount, description, categoryName, submittedBy, branchId } = req.body;

        if (!expenseId || !expenseNumber || amount === undefined || !description) {
            return res.status(400).json({
                success: false,
                message: "expenseId, expenseNumber, amount, and description are required"
            });
        }

        const result = await notifyExpenseSubmitted(
            expenseId,
            expenseNumber,
            amount,
            description,
            categoryName,
            submittedBy,
            branchId
        );

        if (result.success) {
            res.status(200).json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (error: any) {
        console.error("Error notifying expense submission:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Internal server error"
        });
    }
});

// Notify when expense is approved
app.post("/api/expenses/notify-approved", async (req, res) => {
    try {
        const { expenseId, expenseNumber, amount, description, categoryName, approvedBy, branchId } = req.body;

        if (!expenseId || !expenseNumber || amount === undefined || !description) {
            return res.status(400).json({
                success: false,
                message: "expenseId, expenseNumber, amount, and description are required"
            });
        }

        const result = await notifyExpenseApproved(
            expenseId,
            expenseNumber,
            amount,
            description,
            categoryName,
            approvedBy,
            branchId
        );

        if (result.success) {
            res.status(200).json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (error: any) {
        console.error("Error notifying expense approval:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Internal server error"
        });
    }
});

// Notify when expense is rejected
app.post("/api/expenses/notify-rejected", async (req, res) => {
    try {
        const { expenseId, expenseNumber, amount, description, rejectionReason, categoryName, rejectedBy, branchId } = req.body;

        if (!expenseId || !expenseNumber || amount === undefined || !description) {
            return res.status(400).json({
                success: false,
                message: "expenseId, expenseNumber, amount, and description are required"
            });
        }

        const result = await notifyExpenseRejected(
            expenseId,
            expenseNumber,
            amount,
            description,
            rejectionReason,
            categoryName,
            rejectedBy,
            branchId
        );

        if (result.success) {
            res.status(200).json(result);
        } else {
            res.status(400).json(result);
        }
    } catch (error: any) {
        console.error("Error notifying expense rejection:", error);
        res.status(500).json({
            success: false,
            message: error.message || "Internal server error"
        });
    }
});

// ============================================================================
// INCOME RECORDS API
// ============================================================================

// GET /api/incomes — List income records with optional filters
app.get("/api/incomes", async (req, res) => {
    try {
        const { startDate, endDate, bankAccountId, status, search } = req.query;

        let query = supabaseService
            .from("income_records")
            .select(`
                *,
                bank_accounts (account_name, account_type),
                clients (name),
                employees (employee_code)
            `)
            .is('deleted_at', null);

        if (startDate) query = query.gte('income_date', startDate as string);
        if (endDate) query = query.lte('income_date', endDate as string);
        if (bankAccountId) query = query.eq('bank_account_id', bankAccountId);
        if (status) query = query.eq('status', status);
        if (search) {
            query = query.or(`income_name.ilike.%${search}%,reference_number.ilike.%${search}%,remarks.ilike.%${search}%`);
        }

        const { data, error } = await query.order('income_date', { ascending: false });

        if (error) throw error;
        res.json({ success: true, data: data || [] });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// GET /api/incomes/:id — Get single income record
app.get("/api/incomes/:id", async (req, res) => {
    try {
        const { id } = req.params;

        const { data, error } = await supabaseService
            .from("income_records")
            .select(`
                *,
                bank_accounts (account_name, account_type, bank_name, account_number),
                clients (name),
                employees (employee_code),
                payment_transactions_registry (*)
            `)
            .eq('id', id)
            .single();

        if (error) throw error;
        if (!data) {
            return res.status(404).json({ success: false, message: "Income record not found" });
        }

        res.json({ success: true, data });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// POST /api/incomes — Create income record + auto-create RECEIVED transaction
// Writes to payment_transactions_registry (header) AND payment_transaction_details (ties amount
// to bank_account_id). Both rows are required for calculate_account_balance() to pick up the
// income — without the details row the bank account balance is NOT updated.
app.post("/api/incomes", async (req, res) => {
    try {
        const { 
            income_date, 
            income_name, 
            amount, 
            bank_account_id, 
            payment_mode, 
            reference_number, 
            client_id, 
            employee_id, 
            remarks,
            cheque_number,
            cheque_date,
            cheque_bank_name
        } = req.body;

        if (!income_date || !income_name || !amount || !bank_account_id || !payment_mode) {
            return res.status(400).json({ success: false, message: "Missing required fields" });
        }

        // Derive party info from client/employee link for traceability in the registry
        const partyId = client_id || employee_id || null;
        const partyType = client_id ? "client" : (employee_id ? "employee" : null);

        // Step 1: Create the payment transaction header (RECEIVED)
        const { data: transaction, error: txError } = await supabaseService
            .from("payment_transactions_registry")
            .insert([{
                transaction_date: income_date,
                transaction_type: "INCOME",
                direction: "RECEIVED",
                total_amount: amount,
                source_type: "income",
                party_id: partyId,
                party_type: partyType,
                reference_number: reference_number || null,
                remarks: remarks || `Income: ${income_name}`,
                status: "completed"
            }])
            .select()
            .single();

        if (txError) throw txError;

        // Step 2: Create payment_transaction_details row — this is what actually credits the
        // bank account balance (calculate_account_balance joins on ptd.bank_account_id)
        const { error: detailError } = await supabaseService
            .from("payment_transaction_details")
            .insert([{
                payment_id: transaction.id,
                bank_account_id,
                payment_mode,
                amount,
                transaction_reference: reference_number || null,
                remarks: remarks || `Income: ${income_name}`,
                cheque_number: cheque_number || null,
                cheque_date: cheque_date || null,
                cheque_bank_name: cheque_bank_name || null
            }]);

        if (detailError) {
            // Rollback: cancel the registry row so it does not appear in any ledger/balance view
            await supabaseService
                .from("payment_transactions_registry")
                .update({ status: "cancelled", cancellation_reason: "Income detail creation failed" })
                .eq('id', transaction.id);
            throw detailError;
        }

        // Step 3: Create income record with transaction_id
        const { data: income, error: incomeError } = await supabaseService
            .from("income_records")
            .insert([{
                income_date,
                income_name,
                amount,
                bank_account_id,
                payment_mode,
                reference_number: reference_number || null,
                client_id: client_id || null,
                employee_id: employee_id || null,
                remarks: remarks || null,
                transaction_id: transaction.id,
                status: "completed",
                cheque_number: cheque_number || null,
                cheque_date: cheque_date || null,
                cheque_bank_name: cheque_bank_name || null
            }])
            .select()
            .single();

        if (incomeError) {
            // Rollback: cancel the transaction if income creation fails. The cascade-linked
            // detail row stays but is filtered out because calculate_account_balance requires
            // ptr.status = 'completed'.
            await supabaseService
                .from("payment_transactions_registry")
                .update({ status: "cancelled", cancellation_reason: "Income creation failed" })
                .eq('id', transaction.id);
            throw incomeError;
        }

        // Step 4: Backfill source_id on the registry row for traceability back to income_records
        await supabaseService
            .from("payment_transactions_registry")
            .update({ source_id: income.id })
            .eq('id', transaction.id);

        res.json({ success: true, data: income });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// PUT /api/incomes/:id — Update income record + sync linked transaction
// Keeps three rows in sync: income_records, payment_transactions_registry (header), and
// payment_transaction_details (amount + bank_account_id driver of balance calc).
app.put("/api/incomes/:id", async (req, res) => {
    try {
        const { id } = req.params;
        const { 
            income_date, 
            income_name, 
            amount, 
            bank_account_id, 
            payment_mode, 
            reference_number, 
            client_id, 
            employee_id, 
            remarks,
            cheque_number,
            cheque_date,
            cheque_bank_name
        } = req.body;

        // Get existing record to find the linked transaction
        const { data: existing, error: fetchError } = await supabaseService
            .from("income_records")
            .select("transaction_id")
            .eq('id', id)
            .single();

        if (fetchError) throw fetchError;
        if (!existing) {
            return res.status(404).json({ success: false, message: "Income record not found" });
        }

        // Update income record
        const { data: income, error: incomeError } = await supabaseService
            .from("income_records")
            .update({
                income_date: income_date,
                income_name: income_name,
                amount: amount,
                bank_account_id: bank_account_id,
                payment_mode: payment_mode,
                reference_number: reference_number || null,
                client_id: client_id || null,
                employee_id: employee_id || null,
                remarks: remarks || null,
                cheque_number: cheque_number || null,
                cheque_date: cheque_date || null,
                cheque_bank_name: cheque_bank_name || null,
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (incomeError) throw incomeError;

        // Update linked transaction + detail row to keep balances in sync
        if (existing.transaction_id) {
            const partyId = client_id || employee_id || null;
            const partyType = client_id ? "client" : (employee_id ? "employee" : null);

            // Update registry header
            await supabaseService
                .from("payment_transactions_registry")
                .update({
                    transaction_date: income_date,
                    total_amount: amount,
                    party_id: partyId,
                    party_type: partyType,
                    reference_number: reference_number || null,
                    remarks: remarks || `Income: ${income_name}`,
                    updated_at: new Date().toISOString()
                })
                .eq('id', existing.transaction_id);

            // Update the payment_transaction_details row so the account balance follows the
            // edit (changing bank_account_id, payment_mode, or amount must propagate here).
            const { data: existingDetails } = await supabaseService
                .from("payment_transaction_details")
                .select("id")
                .eq('payment_id', existing.transaction_id)
                .limit(1);

            if (existingDetails && existingDetails.length > 0) {
                await supabaseService
                    .from("payment_transaction_details")
                    .update({
                        bank_account_id,
                        payment_mode,
                        amount,
                        transaction_reference: reference_number || null,
                        remarks: remarks || `Income: ${income_name}`,
                        cheque_number: cheque_number || null,
                        cheque_date: cheque_date || null,
                        cheque_bank_name: cheque_bank_name || null
                    })
                    .eq('id', existingDetails[0].id);
            } else {
                // Legacy/backfill path: income created before this fix has no detail row —
                // create one now so the balance starts tracking correctly.
                await supabaseService
                    .from("payment_transaction_details")
                    .insert([{
                        payment_id: existing.transaction_id,
                        bank_account_id,
                        payment_mode,
                        amount,
                        transaction_reference: reference_number || null,
                        remarks: remarks || `Income: ${income_name}`,
                        cheque_number: cheque_number || null,
                        cheque_date: cheque_date || null,
                        cheque_bank_name: cheque_bank_name || null
                    }]);
            }
        }

        res.json({ success: true, data: income });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// PATCH /api/incomes/:id/cancel — Cancel income + cancel linked transaction
// Setting the registry row's status to 'cancelled' is sufficient to back out the account
// balance: calculate_account_balance() and get_account_ledger() both filter on
// ptr.status = 'completed', so cancelled rows are excluded automatically. We leave the
// payment_transaction_details row in place for audit.
app.patch("/api/incomes/:id/cancel", async (req, res) => {
    try {
        const { id } = req.params;
        const { reason } = req.body;

        if (!reason) {
            return res.status(400).json({ success: false, message: "Cancellation reason is required" });
        }

        // Get existing record to find the linked transaction
        const { data: existing, error: fetchError } = await supabaseService
            .from("income_records")
            .select("transaction_id")
            .eq('id', id)
            .single();

        if (fetchError) throw fetchError;
        if (!existing) {
            return res.status(404).json({ success: false, message: "Income record not found" });
        }

        // Cancel income record
        const { data: income, error: incomeError } = await supabaseService
            .from("income_records")
            .update({
                status: "cancelled",
                cancelled_at: new Date().toISOString(),
                cancellation_reason: reason,
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (incomeError) throw incomeError;

        // Cancel linked transaction to adjust balance
        if (existing.transaction_id) {
            await supabaseService
                .from("payment_transactions_registry")
                .update({
                    status: "cancelled",
                    cancelled_at: new Date().toISOString(),
                    cancellation_reason: `Income cancelled: ${reason}`,
                    updated_at: new Date().toISOString()
                })
                .eq('id', existing.transaction_id);
        }

        res.json({ success: true, data: income });
    } catch (error: any) {
        res.status(500).json({ success: false, message: error.message });
    }
});

// Health check endpoint
app.get("/api/health", async (req, res) => {
    try {
        res.json({
            status: "ok",
            timestamp: new Date().toISOString(),
        });
    } catch (error: any) {
        res.status(500).json({
            status: "error",
            error: error.message,
        });
    }
});

// Sync Google reviews for CMS testimonials
app.post("/api/cms/testimonials/google/sync", async (req, res) => {
    try {
        const bodySourceId = typeof req.body?.sourceId === "string"
            ? req.body.sourceId
            : undefined;

        const result = await syncGoogleReviewsFromSources({ sourceId: bodySourceId });

        return res.status(200).json(result);
    } catch (error: any) {
        console.error("Google review sync endpoint error:", error);
        return res.status(500).json({
            success: false,
            message: error?.message || "Failed to sync Google reviews"
        });
    }
});

// Experimental scrape test endpoint for Google Maps reviews.
app.post("/api/cms/testimonials/google/scrape-test", async (req, res) => {
    try {
        const body = req.body || {};
        const result = await runGoogleMapsScrapeTest({
            placeId: typeof body.placeId === "string" ? body.placeId : undefined,
            maxReviews: body.maxReviews,
            maxScrolls: body.maxScrolls,
            debugHeaded: body.debugHeaded,
            slowMoMs: body.slowMoMs,
        });

        return res.status(200).json(result);
    } catch (error: any) {
        const message = error?.message || "Failed to execute scrape test";
        console.error("Google scrape-test endpoint error:", error);
        const isValidationError =
            message.includes("Google Place ID is required") ||
            message.includes("Could not open Google Maps reviews surface");

        return res.status(isValidationError ? 400 : 500).json({
            success: false,
            message,
        });
    }
});

// ============================================================================
// APP MODULE GROUPS (section headers) — CRUD
// ============================================================================

app.get('/api/app-module-groups', async (_req, res) => {
    const { data, error } = await supabaseService.from('app_module_groups').select('*').order('display_order', { ascending: true });
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.post('/api/app-module-groups', async (req, res) => {
    const { name, slug, display_order, is_active } = req.body;
    if (!name || !slug) return res.status(400).json({ success: false, message: 'name and slug are required' });
    const { data, error } = await supabaseService.from('app_module_groups').insert([{ name, slug, display_order: display_order ?? 0, is_active: is_active ?? true }]).select().single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.status(201).json({ success: true, data });
});

app.put('/api/app-module-groups/:id', async (req, res) => {
    const { id } = req.params;
    const { name, slug, display_order, is_active } = req.body;
    const { data, error } = await supabaseService.from('app_module_groups').update({ name, slug, display_order, is_active, updated_at: new Date().toISOString() }).eq('id', id).select().single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.delete('/api/app-module-groups/:id', async (req, res) => {
    const { error } = await supabaseService.from('app_module_groups').delete().eq('id', req.params.id);
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true });
});

app.patch('/api/app-module-groups/reorder', async (req, res) => {
    const items: { id: string; display_order: number }[] = req.body;
    if (!Array.isArray(items)) return res.status(400).json({ success: false, message: 'Expected array' });
    const results = await Promise.all(items.map(({ id, display_order }) => supabaseService.from('app_module_groups').update({ display_order, updated_at: new Date().toISOString() }).eq('id', id)));
    const failed = results.find(r => r.error);
    if (failed?.error) return res.status(500).json({ success: false, message: failed.error.message });
    return res.json({ success: true });
});

// ============================================================================
// APP MODULES (collapsible groups) — CRUD
// ============================================================================

app.get('/api/app-modules', async (req, res) => {
    const { module_group_id } = req.query;
    let query = supabaseService.from('app_modules').select('*, app_module_groups(id, name, slug)').order('display_order', { ascending: true });
    if (module_group_id && module_group_id !== 'all') {
        if (module_group_id === 'none') query = query.is('module_group_id', null);
        else query = query.eq('module_group_id', module_group_id as string);
    }
    const { data, error } = await query;
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.post('/api/app-modules', async (req, res) => {
    const { name, slug, icon_name, icon_color, module_group_id, display_order, is_active } = req.body;
    if (!name || !slug) return res.status(400).json({ success: false, message: 'name and slug are required' });
    const { data, error } = await supabaseService.from('app_modules').insert([{ name, slug, icon_name: icon_name || null, icon_color: icon_color || null, module_group_id: module_group_id || null, display_order: display_order ?? 0, is_active: is_active ?? true }]).select().single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.status(201).json({ success: true, data });
});

app.put('/api/app-modules/:id', async (req, res) => {
    const { id } = req.params;
    const { name, slug, icon_name, icon_color, module_group_id, display_order, is_active } = req.body;
    const { data, error } = await supabaseService.from('app_modules').update({ name, slug, icon_name: icon_name || null, icon_color: icon_color || null, module_group_id: module_group_id || null, display_order, is_active, updated_at: new Date().toISOString() }).eq('id', id).select().single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.delete('/api/app-modules/:id', async (req, res) => {
    const { error } = await supabaseService.from('app_modules').delete().eq('id', req.params.id);
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true });
});

app.patch('/api/app-modules/reorder', async (req, res) => {
    const items: { id: string; display_order: number }[] = req.body;
    if (!Array.isArray(items)) return res.status(400).json({ success: false, message: 'Expected array' });
    const results = await Promise.all(items.map(({ id, display_order }) => supabaseService.from('app_modules').update({ display_order, updated_at: new Date().toISOString() }).eq('id', id)));
    const failed = results.find(r => r.error);
    if (failed?.error) return res.status(500).json({ success: false, message: failed.error.message });
    return res.json({ success: true });
});

// ============================================================================
// APP PAGES (leaf items) — CRUD
// ============================================================================

app.get('/api/app-pages', async (req, res) => {
    const { module_id, module_group_id } = req.query;
    let query = supabaseService.from('app_pages').select('*, app_modules(id, name, slug), app_module_groups(id, name, slug)').order('display_order', { ascending: true });
    if (module_id) query = query.eq('module_id', module_id as string);
    if (module_group_id) query = query.eq('module_group_id', module_group_id as string);
    const { data, error } = await query;
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.post('/api/app-pages', async (req, res) => {
    const { title, url, module_id, module_group_id, display_order, is_active, resource_key, icon_name, icon_color } = req.body;
    if (!title || !url) return res.status(400).json({ success: false, message: 'title and url are required' });
    const { data, error } = await supabaseService.from('app_pages').insert([{ title, url, module_id: module_id || null, module_group_id: module_group_id || null, display_order: display_order ?? 0, is_active: is_active ?? true, resource_key: resource_key || null, icon_name: icon_name || null, icon_color: icon_color || null }]).select().single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.status(201).json({ success: true, data });
});

app.put('/api/app-pages/:id', async (req, res) => {
    const { id } = req.params;
    const { title, url, module_id, module_group_id, display_order, is_active, resource_key, icon_name, icon_color } = req.body;
    const { data, error } = await supabaseService.from('app_pages').update({ title, url, module_id: module_id || null, module_group_id: module_group_id || null, display_order, is_active, resource_key: resource_key || null, icon_name: icon_name || null, icon_color: icon_color || null, updated_at: new Date().toISOString() }).eq('id', id).select().single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.delete('/api/app-pages/:id', async (req, res) => {
    const { error } = await supabaseService.from('app_pages').delete().eq('id', req.params.id);
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true });
});

app.patch('/api/app-pages/reorder', async (req, res) => {
    const items: { id: string; display_order: number }[] = req.body;
    if (!Array.isArray(items)) return res.status(400).json({ success: false, message: 'Expected array' });
    const results = await Promise.all(items.map(({ id, display_order }) => supabaseService.from('app_pages').update({ display_order, updated_at: new Date().toISOString() }).eq('id', id)));
    const failed = results.find(r => r.error);
    if (failed?.error) return res.status(500).json({ success: false, message: failed.error.message });
    return res.json({ success: true });
});

// ============================================================================
// RECURRING NOTIFICATION SCHEDULES — CRUD
// ============================================================================

app.get('/api/reports/definitions', async (_req, res) => {
    return res.json({
        success: true,
        reports: getReportDefinitions(),
        dateRangePresets: getReportDateRangePresets(),
    });
});

app.get('/api/recurring-notifications', async (req, res) => {
    let query = supabaseService
        .from('recurring_notification_schedules')
        .select('*')
        .order('created_at', { ascending: false });
    if (req.query.active === 'true') query = query.eq('is_active', true);
    const { data, error } = await query;
    if (error) return res.status(500).json({ success: false, message: error.message });

    // Fetch linked auto-rule details (channels, name, trigger_type)
    const ruleIds = [...new Set((data ?? []).map((r: any) => r.auto_rule_id).filter(Boolean))];
    let ruleMap: Record<string, any> = {};
    let roleMap: Record<string, string[]> = {};

    if (ruleIds.length) {
        const { data: rules } = await supabaseService
            .from('notification_auto_rules')
            .select('id, name, trigger_type, channels')
            .in('id', ruleIds);
        for (const rule of (rules ?? [])) {
            ruleMap[rule.id] = {
                id: rule.id,
                name: rule.name,
                trigger_type: rule.trigger_type,
                channels: typeof rule.channels === 'string' ? JSON.parse(rule.channels) : rule.channels,
            };
        }

        const { data: roleMappings } = await supabaseService
            .from('notification_auto_rule_roles')
            .select('rule_id, roles(name)')
            .in('rule_id', ruleIds);
        for (const rm of (roleMappings ?? [])) {
            const ruleId = (rm as any).rule_id;
            const roleName = (rm as any).roles?.name;
            if (!roleMap[ruleId]) roleMap[ruleId] = [];
            if (roleName) roleMap[ruleId].push(roleName);
        }
    }

    const mapped = (data ?? []).map((row: any) => {
        const rule = ruleMap[row.auto_rule_id] ?? null;
        return {
            ...row,
            auto_rule: rule ? { ...rule, role_names: roleMap[rule.id] ?? [] } : null,
        };
    });
    return res.json({ success: true, data: mapped });
});

app.post('/api/recurring-notifications', async (req, res) => {
    const {
        name, title, message, type, priority,
        recurrence_type, time_of_day, days_of_week, day_of_month, cron_expression,
        start_date, end_date, channels, recipient_type,
        recipient_role_ids, recipient_branch_ids, recipient_user_ids,
        action_url, is_active, created_by, auto_rule_id,
    } = req.body;
    // When linked to an auto-rule, title/message are optional (inherited from rule)
    if (!name || !recurrence_type) {
        return res.status(400).json({ success: false, message: 'name and recurrence_type are required' });
    }
    if (!auto_rule_id && (!title || !message)) {
        return res.status(400).json({ success: false, message: 'title and message are required for standalone schedules' });
    }
    const next_run_at = computeInitialNextRunAt({
        recurrence_type,
        time_of_day: time_of_day ?? '09:00',
        days_of_week: days_of_week ?? null,
        day_of_month: day_of_month ?? null,
        cron_expression: cron_expression ?? null,
        start_date: start_date ?? new Date().toISOString().slice(0, 10),
    });
    const { data, error } = await supabaseService
        .from('recurring_notification_schedules')
        .insert([{
            name, title, message,
            type: type ?? 'info',
            priority: priority ?? 'medium',
            recurrence_type,
            time_of_day: time_of_day ?? '09:00',
            days_of_week: days_of_week ?? null,
            day_of_month: day_of_month ?? null,
            cron_expression: cron_expression ?? null,
            start_date: start_date ?? new Date().toISOString().slice(0, 10),
            end_date: end_date ?? null,
            channels: channels ?? { push: true, email: false, sms: false, whatsapp: false },
            recipient_type: recipient_type ?? 'all',
            recipient_role_ids: recipient_role_ids ?? null,
            recipient_branch_ids: recipient_branch_ids ?? null,
            recipient_user_ids: recipient_user_ids ?? null,
            action_url: action_url ?? null,
            auto_rule_id: auto_rule_id ?? null,
            is_active: is_active ?? true,
            next_run_at,
            created_by: created_by ?? null,
        }])
        .select()
        .single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.status(201).json({ success: true, data });
});

app.put('/api/recurring-notifications/:id', async (req, res) => {
    const { id } = req.params;
    const {
        name, title, message, type, priority,
        recurrence_type, time_of_day, days_of_week, day_of_month, cron_expression,
        start_date, end_date, channels, recipient_type,
        recipient_role_ids, recipient_branch_ids, recipient_user_ids,
        action_url, is_active, auto_rule_id,
    } = req.body;
    const next_run_at = computeInitialNextRunAt({
        recurrence_type,
        time_of_day: time_of_day ?? '09:00',
        days_of_week: days_of_week ?? null,
        day_of_month: day_of_month ?? null,
        cron_expression: cron_expression ?? null,
        start_date: start_date ?? new Date().toISOString().slice(0, 10),
    });
    const { data, error } = await supabaseService
        .from('recurring_notification_schedules')
        .update({
            name, title, message, type, priority,
            recurrence_type, time_of_day, days_of_week, day_of_month, cron_expression,
            start_date, end_date, channels, recipient_type,
            recipient_role_ids, recipient_branch_ids, recipient_user_ids,
            action_url, auto_rule_id: auto_rule_id ?? null, is_active, next_run_at,
        })
        .eq('id', id)
        .select()
        .single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.delete('/api/recurring-notifications/:id', async (req, res) => {
    const { error } = await supabaseService
        .from('recurring_notification_schedules')
        .delete()
        .eq('id', req.params.id);
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true });
});

app.patch('/api/recurring-notifications/:id/toggle', async (req, res) => {
    const { id } = req.params;
    const { is_active } = req.body;
    if (typeof is_active !== 'boolean') {
        return res.status(400).json({ success: false, message: 'is_active (boolean) is required' });
    }
    const { data, error } = await supabaseService
        .from('recurring_notification_schedules')
        .update({ is_active })
        .eq('id', id)
        .select()
        .single();
    if (error) return res.status(500).json({ success: false, message: error.message });
    return res.json({ success: true, data });
});

app.post('/api/recurring-notifications/:id/send-now', async (req, res) => {
    try {
        const result = await sendScheduleNow(req.params.id);
        if (!result.success) return res.status(400).json(result);
        return res.json(result);
    } catch (err: any) {
        console.error('send-now error:', err);
        return res.status(500).json({ success: false, message: err?.message || 'Send failed' });
    }
});

// Start Express server
app.listen(PORT, () => {
    console.log(`Express server running on port ${PORT}`);
});

// Initialize databases
initializeDatabases();

// Run punch sync only if company setting attendance_method_biometric is true
async function runPunchSyncIfEnabled() {
    try {
        const { data: settings, error } = await supabase
            .from("company_settings")
            .select("attendance_method_biometric")
            .eq("is_active", true)
            .eq("is_deleted", false)
            .maybeSingle();
        if (error) {
            console.warn("Could not read company_settings for punch sync gate:", error.message);
            return;
        }
        if (settings?.attendance_method_biometric === true) {
            syncPunchRecords();
        }
    } catch (e) {
        console.warn("runPunchSyncIfEnabled:", e);
    }
}

// Start punch sync cron job (every minute), gated by attendance_method_biometric
cron.schedule('* * * * *', () => {
    runPunchSyncIfEnabled();
    processSyncRequests();
});

// Refresh global search index every minute
cron.schedule('*/1 * * * *', async () => {
    try {
        const { error } = await supabaseService.rpc('refresh_search_index');
        if (error) throw error;
    } catch (err: any) {
        console.warn('Search index refresh failed:', err?.message || err);
    }
});

// Start scheduled notification service
scheduledNotificationService.startScheduler();

// Process recurring notifications every minute
cron.schedule('* * * * *', async () => {
    await processRecurringNotifications();
});

// Run punch sync immediately on startup (gated)
runPunchSyncIfEnabled();

// Run date range punch sync on startup for August 2025
// syncPunchRecordsByDateRange('2025-09-22', '2025-08-31');

// Run punch sync for specific user and date range
// syncPunchRecordsByDateRangeAndUserId('2025-08-01', '2025-08-31', 8);

// Run attendance processing for August 2025

interface PunchData {
    enroll_number: number;
    punch_time: dayjs.Dayjs;
}

async function processAttendanceForDate(targetDate: string) {
    try {
        console.log(`Processing attendance for ${targetDate}...`);

        // Get punch records from database for the target date
        const { data: punchRecords, error: punchError } = await supabase
            .from("punch_records")
            .select("enroll_number, punch_time")
            .gte("punch_time", `${targetDate} 00:00:00`)
            .lt("punch_time", `${dayjs(targetDate).add(1, "day").format("YYYY-MM-DD")} 00:00:00`)
            .order("punch_time", { ascending: true });

        if (punchError) throw punchError;
        if (!punchRecords || punchRecords.length === 0) {
            console.log("No punch records found for the date");
            return;
        }

        console.log(`Found ${punchRecords.length} punch records`);

        // Convert to PunchData format
        const punchData: PunchData[] = punchRecords.map(record => ({
            enroll_number: record.enroll_number,
            punch_time: dayjs(record.punch_time)
        }));

        const enrollNumbers = [...new Set(punchData.map((p) => p.enroll_number))];
        console.log(`Processing attendance for ${enrollNumbers.length} unique employees`);

        for (const enrollNumber of enrollNumbers) {
            console.log(`Processing enroll number: ${enrollNumber}`);

            const punches = punchData
                .filter((p) => p.enroll_number === enrollNumber)
                .sort((a, b) => a.punch_time.valueOf() - b.punch_time.valueOf());

            if (punches.length === 0) continue;

            const { data: profile, error: profileErr } = await supabase.from("user_profiles").select("id").eq("biometric_code", enrollNumber).single();
            if (profileErr || !profile) { console.log(`Profile not found for ${enrollNumber}`); continue; }
            const { data: emp, error: empErr } = await supabase.from("employees").select("id").eq("user_id", profile.id).single();
            if (empErr || !emp) { console.log(`Employee not found for user_id ${profile.id}`); continue; }

            const userProfileId = profile.id;
            const employeeId = emp.id;
            const attendanceDate = punches[0].punch_time.format("YYYY-MM-DD");

            // Check if attendance already exists
            const { data: existingAttendance } = await supabase
                .from("attendance_records")
                .select("id")
                .eq("user_profile_id", userProfileId)
                .eq("attendance_date", attendanceDate)
                .single();

            if (existingAttendance) {
                console.log(`Attendance already exists for ${enrollNumber} on ${attendanceDate}`);
                continue;
            }

            const checkIn = punches[0].punch_time;
            let checkOut = punches.length > 1 ? punches[punches.length - 1].punch_time : null;

            // If only check-in exists, estimate check-out based on shift or default 8 hours
            if (!checkOut || punches.length === 1) {
                console.log(`Only check-in found for ${enrollNumber}, estimating check-out time`);
                checkOut = checkIn.add(8, 'hour'); // Default 8-hour shift
            }

            let totalBreakMs = 0;
            if (punches.length > 2) {
                for (let i = 1; i < punches.length - 1; i += 2) {
                    const breakStart = punches[i].punch_time;
                    const breakEnd = punches[i + 1].punch_time;
                    totalBreakMs += breakEnd.diff(breakStart, 'millisecond');
                }
            }

            const totalBreakMinutes = Math.round(totalBreakMs / (1000 * 60));
            const totalWorkMs = checkOut.diff(checkIn, 'millisecond') - totalBreakMs;
            const totalHours = parseFloat((totalWorkMs / (1000 * 60 * 60)).toFixed(2));

            // --- DEBUG: Check what employee_shifts exist ---
            const { data: allShifts } = await supabase
                .from("employee_shifts")
                .select("*")
                .eq("employee_id", employeeId);
            console.log(`All shifts for employee ${employeeId}:`, allShifts);

            // --- SHIFT-BASED LOGIC INITIALIZATION ---
            const { data: shift, error: shiftErr } = await supabase
                .from("employee_shifts")
                .select("shift_id, shifts(start_time, end_time, grace_period)")
                .eq("employee_id", employeeId)
                .eq("is_active", true)
                .eq("is_deleted", false)
                .maybeSingle();

            console.log(`Shift query result for employee ${employeeId}:`, { shift, shiftErr });

            let lateArrivalMinutes = 0;
            let consecutiveLateCount = 0;
            let halfDayPenalty = false;
            let earlyDepartureMinutes = 0;
            let overtimeHours = 0;

            if (!shiftErr && shift?.shifts) {
                // --- SHIFT WAS FOUND, CALCULATE EVERYTHING BASED ON IT ---
                console.log(`Shift found for employee ${enrollNumber}. Using shift-based calculations.`);
                const actualShift = shift.shifts;

                // If only check-in exists, use shift end time for check-out estimation
                if (punches.length === 1) {
                    const shiftEndTime = dayjs(`${attendanceDate} ${(actualShift as any).end_time}`);
                    checkOut = shiftEndTime;
                    const totalWorkMs = checkOut.diff(checkIn, 'millisecond');
                    const totalHours = parseFloat((totalWorkMs / (1000 * 60 * 60)).toFixed(2));
                    console.log(`Using shift end time for check-out: ${checkOut.format('HH:mm:ss')}`);
                }

                // 1. LATE ARRIVAL CALCULATION
                const shiftStartTime = dayjs(`${attendanceDate} ${(actualShift as any).start_time}`);
                const gracePeriod = (actualShift as any).grace_period || 5;
                if (checkIn.isAfter(shiftStartTime.add(gracePeriod, "minute"))) {
                    lateArrivalMinutes = checkIn.diff(shiftStartTime, "minute");
                    // Consecutive late logic...
                    const { data: lastAttendance } = await supabase.from("attendance_records").select("consecutive_late_count").eq("user_profile_id", userProfileId).order("attendance_date", { ascending: false }).limit(1);
                    consecutiveLateCount = (lastAttendance?.[0]?.consecutive_late_count || 0) + 1;
                    if (consecutiveLateCount >= 3) {
                        halfDayPenalty = true;
                        consecutiveLateCount = 0; // Reset after penalty
                    }
                }

                // 2. EARLY DEPARTURE CALCULATION
                const shiftEndTime = dayjs(`${attendanceDate} ${(actualShift as any).end_time}`);
                if (checkOut.isBefore(shiftEndTime)) {
                    earlyDepartureMinutes = shiftEndTime.diff(checkOut, "minute");
                }

                // 3. SHIFT-BASED OVERTIME CALCULATION
                const shiftStart = dayjs(`${attendanceDate} ${(actualShift as any).start_time}`);
                const shiftEnd = dayjs(`${attendanceDate} ${(actualShift as any).end_time}`);
                const shiftDurationHours = shiftEnd.diff(shiftStart, 'hour', true);
                const requiredWorkHours = shiftDurationHours - 0.5; // Assuming a 30-minute break

                if (totalHours > shiftDurationHours) {
                    overtimeHours = parseFloat((totalHours - shiftDurationHours).toFixed(2));
                }

            } else {
                // --- NO SHIFT FOUND, USE DEFAULTS ---
                console.log(`No shift found for employee ${enrollNumber}. Using default calculations.`);
                const standardWorkHours = 8.5;
                if (totalHours > standardWorkHours) {
                    overtimeHours = parseFloat((totalHours - standardWorkHours).toFixed(2));
                }
            }

            // Provide all calculated fields to avoid trigger issues
            const attendanceData = {
                user_profile_id: userProfileId,
                attendance_date: attendanceDate,
                check_in: checkIn.format('YYYY-MM-DD HH:mm:ss'),
                check_out: checkOut.format('YYYY-MM-DD HH:mm:ss'),
                total_break_duration_minutes: totalBreakMinutes,
                total_hours: totalHours,
                overtime_hours: overtimeHours,
                status: "present",
                late_arrival_minutes: lateArrivalMinutes,
                early_departure_minutes: earlyDepartureMinutes,
                consecutive_late_count: consecutiveLateCount,
                half_day_penalty: halfDayPenalty,
                actual_work_hours: totalHours,
                is_manual_entry: false,
                grace_period_minutes: 5
            };

            console.log(`Attempting to insert data:`, attendanceData);

            const { error: attErr } = await supabase
                .from("attendance_records")
                .insert(attendanceData);

            if (attErr) {
                console.error(`Error inserting attendance:`, JSON.stringify(attErr, null, 2));
            } else {
                console.log(`Successfully inserted attendance for user_profile ${userProfileId}`);
            }
        }

        console.log("Attendance processing completed.");
    } catch (err) {
        console.error("Error:", err);
    }
}

async function processAttendance() {
    const targetDate = dayjs().subtract(1, "day").format("YYYY-MM-DD");
    await processAttendanceForDate(targetDate);
}

async function processAttendanceForDateRange(startDate: string, endDate: string) {
    const start = dayjs(startDate);
    const end = dayjs(endDate);

    let currentDate = start;
    while (currentDate.isBefore(end) || currentDate.isSame(end)) {
        const dateStr = currentDate.format('YYYY-MM-DD');
        console.log(`Processing attendance for ${dateStr}`);
        await processAttendanceForDate(dateStr);
        currentDate = currentDate.add(1, 'day');
    }
}

async function processAttendanceForDateRangeAndUser(startDate: string, endDate: string, enrollNumber: number) {
    const start = dayjs(startDate);
    const end = dayjs(endDate);

    let currentDate = start;
    while (currentDate.isBefore(end) || currentDate.isSame(end)) {
        const dateStr = currentDate.format('YYYY-MM-DD');
        console.log(`Processing attendance for user ${enrollNumber} on ${dateStr}`);
        await processAttendanceForUserAndDate(dateStr, enrollNumber);
        currentDate = currentDate.add(1, 'day');
    }
}

// One-time function to process current month attendance
// async function processCurrentMonthOnce() {
//   const currentMonth = dayjs().format('YYYY-MM');
//   const startDate = dayjs(currentMonth + '-01');
//   const today = dayjs();

//   console.log(`One-time processing for month: ${currentMonth}`);

//   let currentDate = startDate;
//   while (currentDate.isBefore(today) || currentDate.isSame(today, 'day')) {
//     const dateStr = currentDate.format('YYYY-MM-DD');
//     console.log(`\n=== One-time processing ${dateStr} ===`);
//     await processAttendanceForDate(dateStr);
//     currentDate = currentDate.add(1, 'day');
//   }

//   console.log('\nOne-time current month processing completed!');
// }

// // Run one-time current month processing
// processCurrentMonthOnce();

// Process attendance for date range
// async function processSpecificDateRange() {
//   const startDate = '2025-08-01';
//   const endDate = '2025-08-31';
//   console.log(`Processing attendance for date range: ${startDate} to ${endDate}`);
//   await processAttendanceForDateRange(startDate, endDate);
// }

// Run for date range
// processSpecificDateRange();

// Schedule to run daily at midnight
cron.schedule('0 0 * * *', () => {
    console.log("Running daily attendance processing...");
    processAttendance();
});

// Schedule event notification check daily at 9 AM
cron.schedule('0 9 * * *', () => {
    console.log("Running event notification check...");
    sendEventNotifications();
});

// Schedule Google reviews sync daily at 3 AM
cron.schedule('0 3 * * *', async () => {
    try {
        console.log("Running scheduled Google review sync...");
        const result = await syncGoogleReviewsFromSources();
        console.log(
            `Google review sync done: sources=${result.totalSources}, imported=${result.totalImported}, updated=${result.totalUpdated}, failed=${result.failedSources}`
        );
    } catch (error: any) {
        console.error("Scheduled Google review sync failed:", error?.message || error);
    }
});


// Function to calculate attendance for specific user and date
async function processAttendanceForUserAndDate(targetDate: string, enrollNumber: number) {
    try {
        console.log(`Processing attendance for user ${enrollNumber} on ${targetDate}...`);

        // Get punch records for specific user and date
        const { data: punchRecords, error: punchError } = await supabase
            .from("punch_records")
            .select("enroll_number, punch_time")
            .eq("enroll_number", enrollNumber)
            .gte("punch_time", `${targetDate} 00:00:00`)
            .lt("punch_time", `${dayjs(targetDate).add(1, "day").format("YYYY-MM-DD")} 00:00:00`)
            .order("punch_time", { ascending: true });

        if (punchError) throw punchError;
        if (!punchRecords || punchRecords.length === 0) {
            console.log(`No punch records found for user ${enrollNumber} on ${targetDate}`);
            return;
        }

        console.log(`Found ${punchRecords.length} punch records for user ${enrollNumber}`);

        // Convert to PunchData format
        const punchData: PunchData[] = punchRecords.map(record => ({
            enroll_number: record.enroll_number,
            punch_time: dayjs(record.punch_time)
        }));

        const punches = punchData.sort((a, b) => a.punch_time.valueOf() - b.punch_time.valueOf());

        const { data: profile, error: profileErr } = await supabase.from("user_profiles").select("id").eq("biometric_code", enrollNumber).single();
        if (profileErr || !profile) { console.log(`Profile not found for ${enrollNumber}`); return; }
        const { data: emp, error: empErr } = await supabase.from("employees").select("id").eq("user_id", profile.id).single();
        if (empErr || !emp) { console.log(`Employee not found for user_id ${profile.id}`); return; }

        const userProfileId = profile.id;
        const employeeId = emp.id;
        const attendanceDate = punches[0].punch_time.format("YYYY-MM-DD");

        // Check if attendance already exists
        const { data: existingAttendance } = await supabase
            .from("attendance_records")
            .select("id")
            .eq("user_profile_id", userProfileId)
            .eq("attendance_date", attendanceDate)
            .single();

        if (existingAttendance) {
            console.log(`Attendance already exists for ${enrollNumber} on ${attendanceDate}`);
            return;
        }

        const checkIn = punches[0].punch_time;
        let checkOut = punches.length > 1 ? punches[punches.length - 1].punch_time : null;

        if (!checkOut || punches.length === 1) {
            console.log(`Only check-in found for ${enrollNumber}, estimating check-out time`);
            checkOut = checkIn.add(8, 'hour');
        }

        let totalBreakMs = 0;
        if (punches.length > 2) {
            for (let i = 1; i < punches.length - 1; i += 2) {
                const breakStart = punches[i].punch_time;
                const breakEnd = punches[i + 1].punch_time;
                totalBreakMs += breakEnd.diff(breakStart, 'millisecond');
            }
        }

        const totalBreakMinutes = Math.round(totalBreakMs / (1000 * 60));
        const totalWorkMs = checkOut.diff(checkIn, 'millisecond') - totalBreakMs;
        const totalHours = parseFloat((totalWorkMs / (1000 * 60 * 60)).toFixed(2));

        const { data: shift, error: shiftErr } = await supabase
            .from("employee_shifts")
            .select("shift_id, shifts(start_time, end_time, grace_period)")
            .eq("employee_id", employeeId)
            .eq("is_active", true)
            .eq("is_deleted", false)
            .maybeSingle();

        let lateArrivalMinutes = 0;
        let consecutiveLateCount = 0;
        let halfDayPenalty = false;
        let earlyDepartureMinutes = 0;
        let overtimeHours = 0;

        if (!shiftErr && shift?.shifts) {
            const actualShift = shift.shifts;

            if (punches.length === 1) {
                const shiftEndTime = dayjs(`${attendanceDate} ${(actualShift as any).end_time}`);
                checkOut = shiftEndTime;
            }

            const shiftStartTime = dayjs(`${attendanceDate} ${(actualShift as any).start_time}`);
            const gracePeriod = (actualShift as any).grace_period || 5;
            if (checkIn.isAfter(shiftStartTime.add(gracePeriod, "minute"))) {
                lateArrivalMinutes = checkIn.diff(shiftStartTime, "minute");
                const { data: lastAttendance } = await supabase.from("attendance_records").select("consecutive_late_count").eq("user_profile_id", userProfileId).order("attendance_date", { ascending: false }).limit(1);
                consecutiveLateCount = (lastAttendance?.[0]?.consecutive_late_count || 0) + 1;
                if (consecutiveLateCount >= 3) {
                    halfDayPenalty = true;
                    consecutiveLateCount = 0;
                }
            }

            const shiftEndTime = dayjs(`${attendanceDate} ${(actualShift as any).end_time}`);
            if (checkOut.isBefore(shiftEndTime)) {
                earlyDepartureMinutes = shiftEndTime.diff(checkOut, "minute");
            }

            const shiftStart = dayjs(`${attendanceDate} ${(actualShift as any).start_time}`);
            const shiftEnd = dayjs(`${attendanceDate} ${(actualShift as any).end_time}`);
            const shiftDurationHours = shiftEnd.diff(shiftStart, 'hour', true);

            if (totalHours > shiftDurationHours) {
                overtimeHours = parseFloat((totalHours - shiftDurationHours).toFixed(2));
            }
        } else {
            const standardWorkHours = 8.5;
            if (totalHours > standardWorkHours) {
                overtimeHours = parseFloat((totalHours - standardWorkHours).toFixed(2));
            }
        }

        const attendanceData = {
            user_profile_id: userProfileId,
            attendance_date: attendanceDate,
            check_in: checkIn.format('YYYY-MM-DD HH:mm:ss'),
            check_out: checkOut.format('YYYY-MM-DD HH:mm:ss'),
            total_break_duration_minutes: totalBreakMinutes,
            total_hours: totalHours,
            overtime_hours: overtimeHours,
            status: "present",
            late_arrival_minutes: lateArrivalMinutes,
            early_departure_minutes: earlyDepartureMinutes,
            consecutive_late_count: consecutiveLateCount,
            half_day_penalty: halfDayPenalty,
            actual_work_hours: totalHours,
            is_manual_entry: false,
            grace_period_minutes: 5
        };

        const { error: attErr } = await supabase
            .from("attendance_records")
            .insert(attendanceData);

        if (attErr) {
            console.error(`Error inserting attendance:`, JSON.stringify(attErr, null, 2));
        } else {
            console.log(`Successfully calculated attendance for user ${enrollNumber} on ${targetDate}`);
        }

    } catch (err) {
        console.error("Error:", err);
    }
}
// Calculate attendance for user with enroll_number 123 for January 2025
// processAttendanceForDateRangeAndUser('2025-09-01', '2025-09-31', 2);
// Calculate attendance for all users from 2025-01-01 to 2025-01-31
// processAttendanceForDateRange('2025-07-01', '2025-10-14');

// Export attendance CSV for date range
// exportAttendanceCSV('2025-07-01', '2025-07-31');

// Process attendance from punch records to CSV (like SQL function)
// processAttendanceToCSV('2025-10-11', '2025-10-27');

console.log('Server started - running initial attendance processing...');
