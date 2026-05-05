/**
 * Per-channel notification senders. Each function never throws and returns
 * a ChannelResult so one channel's failure does not affect others.
 * Used by the single send route which runs all enabled channels in parallel.
 */

import { sendPushNotificationsToUsers } from "./web-push-service";
import { sendNotificationEmails, getEmailsForUserIds, EmailAttachment } from "./email-service";
import { getActiveMessagingSettings, sendSmsMessage, sendWhatsAppMessage } from "./messaging-channel-service";
import { getWorkPhonesForUserIds } from "./messaging-recipients";
import { filterActiveUserIds } from "./user-filter";

export interface ChannelResult {
    sent: number;
    failed: number;
    errors: string[];
}

/**
 * Push (browser) sender. Filters inactive/deleted users before sending.
 */
export async function runPushSender(
    userIds: string[],
    payload: { title: string; message: string; url?: string; icon?: string; badge?: string }
): Promise<ChannelResult> {
    try {
        const activeIds = await filterActiveUserIds(userIds, "push");
        if (activeIds.length === 0) {
            return { sent: 0, failed: 0, errors: ["All recipients are inactive/deleted — push skipped"] };
        }
        const result = await sendPushNotificationsToUsers(activeIds, payload);
        return {
            sent: result.success ?? 0,
            failed: result.failed ?? 0,
            errors: result.errors ?? [],
        };
    } catch (e: any) {
        const msg = e?.message ?? "Push send failed";
        console.error("[notification-senders] runPushSender error:", msg);
        return {
            sent: 0,
            failed: userIds.length,
            errors: [msg],
        };
    }
}

/**
 * Email sender. Filters inactive/deleted users, logs recipient emails, then sends.
 */
export async function runEmailSender(
    userIds: string[],
    subject: string,
    body: string,
    actionUrl: string | undefined,
    options?: { htmlBody?: string; textBody?: string; attachments?: EmailAttachment[]; recipientMode?: "individual" | "bcc" }
): Promise<ChannelResult> {
    try {
        const activeIds = await filterActiveUserIds(userIds, "email");
        if (activeIds.length === 0) {
            return { sent: 0, failed: 0, errors: ["All recipients are inactive/deleted — email skipped"] };
        }

        // Resolve and log the actual email addresses BEFORE sending
        const emailMap = await getEmailsForUserIds(activeIds);
        const resolvedEmails = [...emailMap.values()].filter(Boolean);
        if (resolvedEmails.length > 0) {
            console.log(`[Email] ✉️  Sending "${subject}" to ${resolvedEmails.length} address(es): ${resolvedEmails.join(", ")}`);
        } else {
            console.log(`[Email] No resolvable email addresses for ${activeIds.length} active user(s) — subject: "${subject}"`);
        }

        const result = await sendNotificationEmails(activeIds, subject, body, actionUrl, options);
        return {
            sent: result.sent,
            failed: result.failed,
            errors: result.errors ?? [],
        };
    } catch (e: any) {
        const msg = e?.message ?? "Email send failed";
        console.error("[notification-senders] runEmailSender error:", msg);
        return {
            sent: 0,
            failed: userIds.length,
            errors: [msg],
        };
    }
}

/**
 * SMS sender (HTTP outbound or Twilio/Vonage/MessageBird/AWS via notification_channel_settings).
 * Phone: prefer employees.work_phone, fallback user_profiles.phone; never throws.
 */
export async function runSmsSender(userIds: string[], body: string): Promise<ChannelResult> {
    const errors: string[] = [];
    let sent = 0;
    let failed = 0;
    try {
        console.log(`[SMS] ── runSmsSender called with ${userIds.length} user(s), body: "${body.slice(0, 120)}…"`);
        if (!userIds.length) return { sent: 0, failed: 0, errors: [] };
        userIds = await filterActiveUserIds(userIds, "sms");
        if (!userIds.length) return { sent: 0, failed: 0, errors: ["All recipients are inactive/deleted — SMS skipped"] };
        console.log(`[SMS] Active users after filter: ${userIds.length}`);

        const settings = await getActiveMessagingSettings("sms");
        if (!settings) {
            console.warn("[SMS] No active SMS channel configured in notification_channel_settings");
            return {
                sent: 0,
                failed: 0,
                errors: ["SMS not configured. Add settings under Notification configuration > SMS."],
            };
        }
        console.log(`[SMS] Provider: "${settings.provider}", has outbound config: ${!!settings.config?.outbound}`);

        const defaultCc = settings.config?.default_country_code as string | undefined;
        const phones = await getWorkPhonesForUserIds(userIds, defaultCc);
        console.log(`[SMS] Resolved ${phones.size} phone number(s) for ${userIds.length} user(s):`);
        for (const [uid, phone] of phones.entries()) {
            console.log(`[SMS]   user=${uid} → phone=${phone}`);
        }

        for (const uid of userIds) {
            const phone = phones.get(uid);
            if (!phone) {
                failed++;
                errors.push(`No phone for user ${uid}`);
                console.warn(`[SMS] ✗ No phone number found for user ${uid}`);
                continue;
            }
            console.log(`[SMS] Sending to ${phone} for user ${uid}…`);
            const r = await sendSmsMessage(phone, body);
            if (r.ok) {
                sent++;
                console.log(`[SMS] ✓ Sent to ${phone}: ${r.message}`);
            } else {
                failed++;
                errors.push(r.message);
                console.error(`[SMS] ✗ Failed to ${phone}: ${r.message}`);
            }
        }
        console.log(`[SMS] ── Done: sent=${sent}, failed=${failed}`);
        return { sent, failed, errors };
    } catch (e: any) {
        const msg = e?.message ?? "SMS send failed";
        console.error("[notification-senders] runSmsSender error:", msg);
        return { sent: 0, failed: userIds.length, errors: [msg] };
    }
}

/**
 * WhatsApp sender (HTTP outbound or Twilio/Meta via notification_channel_settings).
 * Phone: prefer employees.work_phone, fallback user_profiles.phone; never throws.
 */
export async function runWhatsAppSender(userIds: string[], body: string): Promise<ChannelResult> {
    const errors: string[] = [];
    let sent = 0;
    let failed = 0;
    try {
        if (!userIds.length) return { sent: 0, failed: 0, errors: [] };
        userIds = await filterActiveUserIds(userIds, "whatsapp");
        if (!userIds.length) return { sent: 0, failed: 0, errors: ["All recipients are inactive/deleted — WhatsApp skipped"] };

        const settings = await getActiveMessagingSettings("whatsapp");
        if (!settings) {
            return {
                sent: 0,
                failed: 0,
                errors: ["WhatsApp not configured. Add settings under Notification configuration > WhatsApp."],
            };
        }

        const defaultCc = settings.config?.default_country_code as string | undefined;
        const phones = await getWorkPhonesForUserIds(userIds, defaultCc);

        for (const uid of userIds) {
            const phone = phones.get(uid);
            if (!phone) {
                failed++;
                errors.push(`No phone for user ${uid}`);
                continue;
            }
            const r = await sendWhatsAppMessage(phone, body);
            if (r.ok) sent++;
            else {
                failed++;
                errors.push(r.message);
            }
        }
        return { sent, failed, errors };
    } catch (e: any) {
        const msg = e?.message ?? "WhatsApp send failed";
        console.error("[notification-senders] runWhatsAppSender error:", msg);
        return { sent: 0, failed: userIds.length, errors: [msg] };
    }
}
