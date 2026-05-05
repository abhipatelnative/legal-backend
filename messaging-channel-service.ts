/**
 * DB-driven SMS / WhatsApp.
 *
 * Priority:
 * 1. config.outbound.* — HTTP request (URL, method, headers, body templates). No hardcoded provider URLs.
 * 2. provider + secrets for SDK paths only: twilio (SMS + WhatsApp), aws_sns (SMS via AWS SDK).
 *
 * Templates in URL, header values, and body support:
 *   {{to}} {{to_noplus}} {{to_digits}} {{body}} {{body_json}}
 *   {{to_whatsapp}} — whatsapp:+E164…
 *   {{secrets.KEY}} {{secrets.nested.key}}  (secrets flattened with dot keys for one level of nesting)
 *   {{config.KEY}}  {{config.nested.key}}
 */

import twilio from "twilio";
import { createClient } from "@supabase/supabase-js";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from "./config/credentials";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

export type MessagingChannelKey = "sms" | "whatsapp";

export interface ChannelRow {
    provider: string;
    config: Record<string, unknown>;
    secrets: Record<string, unknown>;
}

export type SendResult = { ok: boolean; message: string; sid?: string };

export interface OutboundHttpConfig {
    url: string;
    method: string;
    headers: Record<string, string>;
    /** Raw body string after template resolution (often JSON). */
    body: string;
    success_http_status?: number[];
    response_id_json_path?: string;
}

export async function getActiveMessagingSettings(channel: MessagingChannelKey): Promise<ChannelRow | null> {
    const { data, error } = await supabase
        .from("notification_channel_settings")
        .select("provider, config, secrets")
        .eq("channel", channel)
        .eq("is_active", true)
        .eq("is_deleted", false)
        .maybeSingle();

    if (error) {
        console.error("[messaging-channel] fetch settings", channel, error);
        return null;
    }
    if (!data) return null;
    return {
        provider: String((data as any).provider || "").trim() || "custom",
        config: ((data as any).config as Record<string, unknown>) || {},
        secrets: ((data as any).secrets as Record<string, unknown>) || {},
    };
}

function getByPath(obj: unknown, path: string): unknown {
    if (!path || !obj || typeof obj !== "object") return undefined;
    const parts = path.split(".").filter(Boolean);
    let cur: unknown = obj;
    for (const p of parts) {
        if (cur === null || cur === undefined) return undefined;
        if (/^\d+$/.test(p) && Array.isArray(cur)) {
            cur = cur[parseInt(p, 10)];
        } else if (typeof cur === "object" && p in (cur as object)) {
            cur = (cur as Record<string, unknown>)[p];
        } else return undefined;
    }
    return cur;
}

function flattenForTemplate(prefix: string, obj: unknown, out: Record<string, string>): void {
    if (obj === null || obj === undefined) return;
    if (typeof obj !== "object" || Array.isArray(obj)) {
        out[prefix] = String(obj);
        return;
    }
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
        const key = prefix ? `${prefix}.${k}` : k;
        if (v !== null && typeof v === "object" && !Array.isArray(v)) {
            flattenForTemplate(key, v, out);
        } else {
            out[key] = v === undefined || v === null ? "" : String(v);
        }
    }
}

function escapeJsonString(s: string): string {
    return JSON.stringify(s).slice(1, -1);
}

export function buildTemplateContext(
    toRaw: string,
    body: string,
    secrets: Record<string, unknown>,
    config: Record<string, unknown>
): Record<string, string> {
    const to = toRaw.trim();
    const digits = to.replace(/\D/g, "");
    const noplus = to.startsWith("+") ? to.slice(1) : to.replace(/^\+/, "");

    let wa = to;
    if (!wa.toLowerCase().startsWith("whatsapp:")) {
        const num = wa.startsWith("+") ? wa : `+${wa.replace(/^\+/, "")}`;
        wa = `whatsapp:${num}`;
    }

    const flat: Record<string, string> = {
        to,
        to_noplus: noplus,
        to_digits: digits,
        body,
        body_json: escapeJsonString(body),
        to_whatsapp: wa,
    };

    const secFlat: Record<string, string> = {};
    flattenForTemplate("", secrets, secFlat);
    for (const [k, v] of Object.entries(secFlat)) {
        flat[`secrets.${k}`] = v;
    }

    const cfgFlat: Record<string, string> = {};
    flattenForTemplate("", config, cfgFlat);
    for (const [k, v] of Object.entries(cfgFlat)) {
        flat[`config.${k}`] = v;
    }

    return flat;
}

/** Replace {{key}} placeholders; repeated passes for nested substitution. */
export function interpolateTemplate(template: string, vars: Record<string, string>, maxPasses = 4): string {
    let result = template;
    for (let i = 0; i < maxPasses; i++) {
        const next = result.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_, key: string) => {
            const k = key.trim();
            if (k in vars) return vars[k] ?? "";
            return `{{${k}}}`;
        });
        if (next === result) break;
        result = next;
    }
    return result;
}

function parseOutbound(row: ChannelRow): OutboundHttpConfig | null {
    const c = row.config || {};
    const o = (c.outbound as Record<string, unknown>) || {};
    const urlRaw = (o.url || o.request_url || c.http_url || c.outbound_url) as string | undefined;
    const url = urlRaw?.trim();
    if (!url) return null;

    const method = String(o.method || o.http_method || "POST").toUpperCase() || "POST";
    let headers: Record<string, string> = {};
    const h = o.headers;
    if (h && typeof h === "object" && !Array.isArray(h)) {
        for (const [k, v] of Object.entries(h as Record<string, unknown>)) {
            headers[k] = v === undefined || v === null ? "" : String(v);
        }
    }

    const bodyTemplate = (o.body ?? o.body_template ?? "") as string;
    const body = typeof bodyTemplate === "string" ? bodyTemplate : JSON.stringify(bodyTemplate);

    let success_http_status: number[] | undefined;
    const sh = o.success_http_status ?? o.success_status_codes;
    if (Array.isArray(sh)) {
        success_http_status = sh.map((x) => Number(x)).filter((n) => !Number.isNaN(n));
    } else if (typeof sh === "string" && sh.trim()) {
        success_http_status = sh
            .split(",")
            .map((s) => parseInt(s.trim(), 10))
            .filter((n) => !Number.isNaN(n));
    }

    const response_id_json_path = (o.response_id_json_path || o.response_sid_path) as string | undefined;

    return {
        url,
        method,
        headers,
        body,
        success_http_status: success_http_status?.length ? success_http_status : undefined,
        response_id_json_path: response_id_json_path?.trim() || undefined,
    };
}

async function sendOutboundHttp(
    row: ChannelRow,
    channel: MessagingChannelKey,
    to: string,
    bodyText: string,
    ob: OutboundHttpConfig
): Promise<SendResult> {
    const vars = buildTemplateContext(to, bodyText, row.secrets as Record<string, unknown>, row.config as Record<string, unknown>);
    console.log(`[${channel.toUpperCase()}-HTTP] Template vars: to="${vars.to}", body="${(vars.body || "").slice(0, 80)}…"`);

    const url = interpolateTemplate(ob.url, vars);
    const headerEntries: Record<string, string> = {};
    for (const [hk, hv] of Object.entries(ob.headers)) {
        headerEntries[hk] = interpolateTemplate(hv, vars);
    }
    const reqBody = interpolateTemplate(ob.body, vars);
    console.log(`[${channel.toUpperCase()}-HTTP] → ${ob.method} ${url}`);
    console.log(`[${channel.toUpperCase()}-HTTP] → Headers: ${JSON.stringify(headerEntries)}`);
    console.log(`[${channel.toUpperCase()}-HTTP] → Body: ${reqBody.slice(0, 300)}`);

    try {
        const res = await fetch(url, {
            method: ob.method,
            headers: headerEntries,
            body: ob.method === "GET" || ob.method === "HEAD" ? undefined : reqBody,
        });

        const allowed = ob.success_http_status;
        const okStatus = allowed?.length ? allowed.includes(res.status) : res.ok;

        let json: any;
        const ct = res.headers.get("content-type") || "";
        if (ct.includes("application/json")) {
            json = await res.json().catch(() => ({}));
        } else {
            json = null;
        }

        if (okStatus) {
            let sid: string | undefined;
            if (ob.response_id_json_path && json && typeof json === "object") {
                const v = getByPath(json, ob.response_id_json_path);
                if (v !== undefined && v !== null) sid = String(v);
            }
            console.log(`[${channel.toUpperCase()}-HTTP] ✓ Response HTTP ${res.status}${sid ? ` sid=${sid}` : ""}`);
            return { ok: true, message: `Sent (HTTP ${res.status})`, sid };
        }

        const errText =
            (json && (json.error?.message || json.message)) || (await res.text().catch(() => "")) || res.statusText || `HTTP ${res.status}`;
        console.error(`[${channel.toUpperCase()}-HTTP] ✗ Response HTTP ${res.status}: ${String(errText).slice(0, 200)}`);
        return { ok: false, message: String(errText).slice(0, 500) };
    } catch (e: any) {
        console.error(`[${channel.toUpperCase()}-HTTP] ✗ Request error: ${e?.message}`);
        return { ok: false, message: e?.message || "HTTP outbound request failed" };
    }
}

function twilioSdkClient(secrets: Record<string, unknown>) {
    const accountSid = (secrets.account_sid || secrets.accountSid) as string | undefined;
    const authToken = (secrets.auth_token || secrets.authToken) as string | undefined;
    if (!accountSid || !authToken) return null;
    return twilio(accountSid, authToken);
}

async function sendSmsTwilio(row: ChannelRow, toE164: string, body: string): Promise<SendResult> {
    const client = twilioSdkClient(row.secrets);
    if (!client) return { ok: false, message: "Twilio: Account SID or Auth Token missing in secrets." };

    const messagingServiceSid = row.config.messaging_service_sid as string | undefined;
    const from = (row.config.sms_from_number || row.config.from_number) as string | undefined;

    if (!messagingServiceSid && !from) {
        return { ok: false, message: "Twilio SMS: set messaging_service_sid or sms_from_number in config." };
    }

    try {
        const params: Record<string, string> = { to: toE164, body };
        if (messagingServiceSid) params.messagingServiceSid = messagingServiceSid;
        else params.from = from!;
        const msg = await client.messages.create(params as any);
        return { ok: true, message: "Sent (Twilio)", sid: msg.sid };
    } catch (e: any) {
        return { ok: false, message: e?.message || "Twilio SMS error" };
    }
}

async function sendSmsVonage(row: ChannelRow, toE164: string, body: string): Promise<SendResult> {
    const apiKey = (row.secrets.vonage_api_key || row.secrets.api_key) as string | undefined;
    const apiSecret = (row.secrets.vonage_api_secret || row.secrets.api_secret) as string | undefined;
    if (!apiKey?.trim() || !apiSecret?.trim()) {
        return { ok: false, message: "Vonage: API Key and API Secret required in secrets." };
    }
    const from = (row.config.vonage_from_number || row.config.sms_from_number || row.config.from_number) as string | undefined;
    if (!from?.trim()) {
        return { ok: false, message: "Vonage: From number or sender ID required in config." };
    }
    const to = toE164.replace(/^\+/, "");
    const params = new URLSearchParams({
        api_key: apiKey,
        api_secret: apiSecret,
        to,
        from: from.replace(/^\+/, ""),
        text: body,
    });
    try {
        const res = await fetch("https://rest.nexmo.com/sms/json", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: params.toString(),
        });
        const json: any = await res.json().catch(() => ({}));
        const messages = json?.messages;
        const first = Array.isArray(messages) ? messages[0] : null;
        if (first?.["status"] === "0") {
            return { ok: true, message: "Sent (Vonage)", sid: first["message-id"] };
        }
        const errText = first?.["error-text"] || json?.message || res.statusText || "Vonage API error";
        return { ok: false, message: errText };
    } catch (e: any) {
        return { ok: false, message: e?.message || "Vonage request failed" };
    }
}

async function sendSmsMessageBird(row: ChannelRow, toE164: string, body: string): Promise<SendResult> {
    const accessKey = (row.secrets.messagebird_access_key || row.secrets.access_key) as string | undefined;
    if (!accessKey?.trim()) {
        return { ok: false, message: "MessageBird: Access key required in secrets." };
    }
    const originator = (row.config.messagebird_originator || row.config.sms_from_number || row.config.originator) as string | undefined;
    if (!originator?.trim()) {
        return { ok: false, message: "MessageBird: Originator (sender) required in config." };
    }
    const recipients = [toE164.replace(/^\+/, "")];
    try {
        const res = await fetch("https://rest.messagebird.com/messages", {
            method: "POST",
            headers: {
                Authorization: `AccessKey ${accessKey}`,
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ recipients, originator, body }),
        });
        const json: any = await res.json().catch(() => ({}));
        if (res.ok && json.id) {
            return { ok: true, message: "Sent (MessageBird)", sid: json.id };
        }
        return {
            ok: false,
            message: json.errors?.[0]?.description || json.message || `MessageBird HTTP ${res.status}`,
        };
    } catch (e: any) {
        return { ok: false, message: e?.message || "MessageBird request failed" };
    }
}

async function sendSmsAwsSns(row: ChannelRow, toE164: string, body: string): Promise<SendResult> {
    const accessKeyId = (row.secrets.aws_access_key_id || row.secrets.access_key_id) as string | undefined;
    const secretAccessKey = (row.secrets.aws_secret_access_key || row.secrets.secret_access_key) as string | undefined;
    const region = (row.config.aws_region || row.config.region || "us-east-1") as string;
    if (!accessKeyId?.trim() || !secretAccessKey?.trim()) {
        return {
            ok: false,
            message: "AWS SNS: aws_access_key_id and aws_secret_access_key in secrets; aws_region in config.",
        };
    }

    const client = new SNSClient({
        region,
        credentials: { accessKeyId, secretAccessKey },
    });
    try {
        const out = await client.send(
            new PublishCommand({
                Message: body,
                PhoneNumber: toE164.startsWith("+") ? toE164 : `+${toE164}`,
            })
        );
        return { ok: true, message: "Sent (AWS SNS)", sid: out.MessageId };
    } catch (e: any) {
        return { ok: false, message: e?.message || "AWS SNS error" };
    }
}

async function sendWhatsAppMeta(row: ChannelRow, toE164: string, body: string): Promise<SendResult> {
    const token = (row.secrets.meta_access_token || row.secrets.access_token || row.secrets.meta_whatsapp_token) as string | undefined;
    const phoneNumberId = (row.config.meta_phone_number_id || row.config.phone_number_id) as string | undefined;
    const graphVersion = (row.config.meta_graph_version || "v21.0") as string;
    if (!token?.trim()) {
        return { ok: false, message: "Meta: Access token required in secrets." };
    }
    if (!phoneNumberId?.trim()) {
        return { ok: false, message: "Meta: Phone number ID required in config." };
    }
    const to = toE164.replace(/\D/g, "");
    if (!to) return { ok: false, message: "Invalid recipient for Meta WhatsApp." };
    const url = `https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`;
    try {
        const res = await fetch(url, {
            method: "POST",
            headers: {
                Authorization: `Bearer ${token}`,
                "Content-Type": "application/json",
            },
            body: JSON.stringify({
                messaging_product: "whatsapp",
                to,
                type: "text",
                text: { body },
            }),
        });
        const json: any = await res.json().catch(() => ({}));
        if (res.ok && json.messages?.[0]?.id) {
            return { ok: true, message: "Sent (Meta WhatsApp)", sid: json.messages[0].id };
        }
        const err = json.error?.message || json.error?.error_user_msg || JSON.stringify(json.error || json) || `HTTP ${res.status}`;
        return { ok: false, message: err };
    } catch (e: any) {
        return { ok: false, message: e?.message || "Meta WhatsApp request failed" };
    }
}

async function sendWhatsAppTwilio(row: ChannelRow, toWhatsAppE164: string, body: string): Promise<SendResult> {
    const client = twilioSdkClient(row.secrets);
    if (!client) return { ok: false, message: "Twilio: Account SID or Auth Token missing in secrets." };

    const waFrom = (row.config.whatsapp_from_number || row.config.from_number) as string | undefined;
    if (!waFrom || !waFrom.startsWith("whatsapp:")) {
        return { ok: false, message: 'Twilio WhatsApp: config.whatsapp_from_number must be like "whatsapp:+14155238886".' };
    }

    let to = toWhatsAppE164.trim();
    if (!to.startsWith("whatsapp:")) {
        const num = to.startsWith("+") ? to : `+${to.replace(/^\+/, "")}`;
        to = `whatsapp:${num}`;
    }

    try {
        const msg = await client.messages.create({ from: waFrom, to, body });
        return { ok: true, message: "Sent (Twilio WhatsApp)", sid: msg.sid };
    } catch (e: any) {
        return { ok: false, message: e?.message || "Twilio WhatsApp error" };
    }
}

function normalizedSdkProvider(provider: string): string {
    return provider.trim().toLowerCase();
}

/**
 * Send one SMS: outbound HTTP if config.outbound.url set; else twilio | aws_sns | sns via provider column.
 */
export async function sendSmsMessage(toE164: string, body: string): Promise<SendResult> {
    const row = await getActiveMessagingSettings("sms");
    if (!row) return { ok: false, message: "SMS channel not configured in database." };

    const ob = parseOutbound(row);
    if (ob) return sendOutboundHttp(row, "sms", toE164, body, ob);

    const p = normalizedSdkProvider(row.provider);
    switch (p) {
        case "twilio":
            return sendSmsTwilio(row, toE164, body);
        case "vonage":
        case "nexmo":
            return sendSmsVonage(row, toE164, body);
        case "messagebird":
            return sendSmsMessageBird(row, toE164, body);
        case "aws_sns":
        case "sns":
            return sendSmsAwsSns(row, toE164, body);
        default:
            return {
                ok: false,
                message: `SMS: choose provider twilio, vonage, messagebird, or aws_sns. Current: "${row.provider}".`,
            };
    }
}

/**
 * Send one WhatsApp: outbound HTTP if config.outbound.url set; else twilio SDK only.
 */
export async function sendWhatsAppMessage(toE164OrWa: string, body: string): Promise<SendResult> {
    const row = await getActiveMessagingSettings("whatsapp");
    if (!row) return { ok: false, message: "WhatsApp channel not configured in database." };

    const ob = parseOutbound(row);
    if (ob) return sendOutboundHttp(row, "whatsapp", toE164OrWa, body, ob);

    const p = normalizedSdkProvider(row.provider);
    switch (p) {
        case "twilio":
            return sendWhatsAppTwilio(row, toE164OrWa, body);
        case "meta":
        case "meta_cloud":
        case "whatsapp_cloud":
            return sendWhatsAppMeta(row, toE164OrWa, body);
        default:
            return {
                ok: false,
                message: `WhatsApp: choose provider twilio or meta. Current: "${row.provider}".`,
            };
    }
}

/** @deprecated use sendSmsMessage */
export async function sendTwilioSms(toE164: string, body: string): Promise<SendResult> {
    return sendSmsMessage(toE164, body);
}

/** @deprecated use sendWhatsAppMessage */
export async function sendTwilioWhatsApp(to: string, body: string): Promise<SendResult> {
    return sendWhatsAppMessage(to, body);
}
