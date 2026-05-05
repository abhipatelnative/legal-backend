/**
 * Recurring Notification Service
 * Processes recurring_notification_schedules and fires notifications when due.
 */

import { createClient } from "@supabase/supabase-js";
import dayjs from "dayjs";
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from "./config/credentials";
import { runPushSender, runEmailSender, runSmsSender, runWhatsAppSender } from "./notification-senders";
import { getReportDefinitionByKey, prepareReportNotification } from "./report-notification-service";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function stripPlaceholders(text: string) {
    return text.replace(/\{\{[^}]*\}\}/g, "").replace(/\s{2,}/g, " ").trim();
}

interface RecurringSchedule {
    id: string;
    name: string;
    title: string;
    message: string;
    type: string;
    priority: string;
    recurrence_type: "daily" | "weekly" | "monthly" | "custom";
    time_of_day: string;
    days_of_week: number[] | null;
    day_of_month: number | null;
    cron_expression: string | null;
    start_date: string;
    end_date: string | null;
    channels: { push: boolean; email: boolean; sms: boolean; whatsapp: boolean };
    recipient_type: "all" | "by_role" | "by_branch" | "specific";
    recipient_role_ids: string[] | null;
    recipient_branch_ids: string[] | null;
    recipient_user_ids: string[] | null;
    action_url: string | null;
    auto_rule_id: string | null;
    is_active: boolean;
    last_run_at: string | null;
    next_run_at: string | null;
}

interface ResolvedAutoRule {
    triggerType: string;
    channels: { push: boolean; email: boolean; sms: boolean; whatsapp: boolean };
    subjectTemplate: string;
    messageTemplate: string;
    recipientRoleIds: string[];
    emailTemplateId: string | null;
    isReportNotification: boolean;
    reportKey: string | null;
    reportDateRangeKey: string | null;
}

interface PreparedNotification {
    title: string;
    message: string;
    htmlBody?: string;
    textBody?: string;
    attachments?: Array<{ filename: string; content: Buffer; contentType: string }>;
}

let isProcessingRecurringNotifications = false;

async function resolveAutoRule(ruleId: string): Promise<ResolvedAutoRule | null> {
    try {
        const { data: rule, error: ruleError } = await supabase
            .from("notification_auto_rules")
            .select("id, is_active, trigger_type, channels, subject_template, message_template, email_template_id, is_report_notification, report_key, report_date_range_key")
            .eq("id", ruleId)
            .maybeSingle();

        if (ruleError || !rule) {
            console.warn(`[recurring-notifications] Auto-rule ${ruleId} not found or error:`, ruleError?.message);
            return null;
        }

        if (!rule.is_active) {
            console.warn(`[recurring-notifications] Auto-rule ${ruleId} is inactive, skipping`);
            return null;
        }

        const { data: roleRows, error: roleError } = await supabase
            .from("notification_auto_rule_roles")
            .select("role_id")
            .eq("rule_id", ruleId);

        if (roleError) {
            console.warn(`[recurring-notifications] Failed to fetch roles for rule ${ruleId}:`, roleError.message);
        }

        const recipientRoleIds = (roleRows ?? []).map((row: any) => row.role_id as string).filter(Boolean);
        const channels = typeof rule.channels === "string" ? JSON.parse(rule.channels || "{}") : (rule.channels || {});

        return {
            triggerType: rule.trigger_type ?? "",
            channels: { push: !!channels.push, email: !!channels.email, sms: !!channels.sms, whatsapp: !!channels.whatsapp },
            subjectTemplate: rule.subject_template ?? "",
            messageTemplate: rule.message_template ?? "",
            recipientRoleIds,
            emailTemplateId: rule.email_template_id ?? null,
            isReportNotification: !!rule.is_report_notification,
            reportKey: rule.report_key ?? null,
            reportDateRangeKey: rule.report_date_range_key ?? null,
        };
    } catch (err: any) {
        console.error(`[recurring-notifications] resolveAutoRule error for ${ruleId}:`, err?.message);
        return null;
    }
}

async function resolveUsersByRoles(roleIds: string[]): Promise<string[]> {
    if (!roleIds.length) return [];
    const { data, error } = await supabase
        .from("user_roles")
        .select("user_id")
        .in("role_id", roleIds)
        .eq("is_active", true);

    if (error) {
        console.error("[recurring-notifications] resolveUsersByRoles error:", error.message);
        return [];
    }

    return [...new Set((data ?? []).map((row: any) => row.user_id as string))];
}

function computeNextRunAt(schedule: RecurringSchedule, afterTime: dayjs.Dayjs): dayjs.Dayjs {
    const [hours, minutes] = schedule.time_of_day.split(":").map(Number);

    switch (schedule.recurrence_type) {
        case "daily":
            return afterTime.add(1, "day").hour(hours).minute(minutes).second(0).millisecond(0);
        case "weekly": {
            const targetDays = schedule.days_of_week ?? [1];
            let candidate = afterTime.add(1, "day").hour(hours).minute(minutes).second(0).millisecond(0);
            for (let index = 0; index < 7; index++) {
                if (targetDays.includes(candidate.day())) return candidate;
                candidate = candidate.add(1, "day");
            }
            return candidate;
        }
        case "monthly": {
            const targetDay = schedule.day_of_month ?? 1;
            let next = afterTime.add(1, "month").date(1).hour(hours).minute(minutes).second(0).millisecond(0);
            next = next.date(Math.min(targetDay, next.daysInMonth()));
            return next;
        }
        case "custom": {
            const expression = (schedule.cron_expression ?? "").trim();
            if (expression.startsWith("EVERY:")) {
                const parts = expression.split(":");
                const amount = parseInt(parts[1], 10) || 1;
                const unit = parts[2] || "weeks";
                const hour = parseInt(parts[3], 10) || 9;
                const minute = parseInt(parts[4], 10) || 0;
                return afterTime.add(amount, unit as dayjs.ManipulateType).hour(hour).minute(minute).second(0).millisecond(0);
            }

            const parts = expression.split(/\s+/);
            if (parts[0]?.startsWith("*/")) {
                return afterTime.add(parseInt(parts[0].slice(2), 10) || 30, "minute").second(0).millisecond(0);
            }
            if (parts[1]?.startsWith("*/")) {
                return afterTime.add(parseInt(parts[1].slice(2), 10) || 1, "hour").minute(0).second(0).millisecond(0);
            }
            if (parts[2]?.startsWith("*/")) {
                const dayEvery = parseInt(parts[2].slice(2), 10) || 1;
                const cronHour = parseInt(parts[1], 10) || 9;
                const cronMinute = parseInt(parts[0], 10) || 0;
                return afterTime.add(dayEvery, "day").hour(cronHour).minute(cronMinute).second(0).millisecond(0);
            }

            const cronMinute = parts[0] && !parts[0].includes("*") ? parseInt(parts[0], 10) : 0;
            const cronHour = parts[1] && !parts[1].includes("*") ? parseInt(parts[1], 10) : 9;
            return afterTime.add(1, "day").hour(isNaN(cronHour) ? 9 : cronHour).minute(isNaN(cronMinute) ? 0 : cronMinute).second(0).millisecond(0);
        }
        default:
            return afterTime.add(1, "day");
    }
}

async function resolveRecipients(schedule: RecurringSchedule): Promise<string[]> {
    try {
        if (schedule.recipient_type === "specific" && schedule.recipient_user_ids?.length) {
            return schedule.recipient_user_ids;
        }

        if (schedule.recipient_type === "by_role" && schedule.recipient_role_ids?.length) {
            const { data, error } = await supabase
                .from("user_roles")
                .select("user_id")
                .in("role_id", schedule.recipient_role_ids);
            if (error) throw error;
            return [...new Set((data ?? []).map((row: any) => row.user_id as string))];
        }

        if (schedule.recipient_type === "by_branch" && schedule.recipient_branch_ids?.length) {
            const { data, error } = await supabase
                .from("employees")
                .select("user_id")
                .in("branch_id", schedule.recipient_branch_ids)
                .not("user_id", "is", null);
            if (error) throw error;
            return [...new Set((data ?? []).map((row: any) => row.user_id as string))];
        }

        const { data, error } = await supabase
            .from("user_profiles")
            .select("id")
            .eq("is_active", true)
            .eq("is_deleted", false);
        if (error) throw error;
        return (data ?? []).map((row: any) => row.id as string);
    } catch (err: any) {
        console.error(`[recurring-notifications] resolveRecipients error for schedule ${schedule.id}:`, err?.message);
        return [];
    }
}

async function substituteTemplateVars(
    titleTemplate: string,
    messageTemplate: string,
    triggerType: string
): Promise<PreparedNotification[]> {
    switch (triggerType) {
        case "event_reminder": {
            const today = dayjs();
            const { data: events, error } = await supabase
                .from("company_events")
                .select("title, description, start_date, is_recurring")
                .eq("is_active", true)
                .eq("is_deleted", false)
                .order("start_date", { ascending: true });

            if (error || !events?.length) return [];

            const upcoming = events.filter((event: any) => {
                const eventDate = event.is_recurring
                    ? dayjs(event.start_date).year(today.year())
                    : dayjs(event.start_date);
                const daysUntil = eventDate.startOf("day").diff(today.startOf("day"), "day");
                return daysUntil >= 0 && daysUntil <= 7;
            });

            return upcoming.map((event: any) => {
                const displayDate = (event.is_recurring
                    ? dayjs(event.start_date).year(today.year())
                    : dayjs(event.start_date)).format("DD MMM YYYY");
                return {
                    title: stripPlaceholders(
                        titleTemplate
                            .replace(/\{\{event_title\}\}/g, event.title || "")
                            .replace(/\{\{event_date\}\}/g, displayDate)
                            .replace(/\{\{event_description\}\}/g, (event.description || "").substring(0, 200))
                    ),
                    message: stripPlaceholders(
                        messageTemplate
                            .replace(/\{\{event_title\}\}/g, event.title || "")
                            .replace(/\{\{event_date\}\}/g, displayDate)
                            .replace(/\{\{event_description\}\}/g, (event.description || "").substring(0, 200))
                    ),
                };
            });
        }

        case "low_stock": {
            const { data: items, error } = await supabase
                .from("inventory_items")
                .select("name, quantity, min_threshold")
                .eq("is_deleted", false)
                .not("min_threshold", "is", null);

            if (error || !items?.length) return [];

            return items
                .filter((item: any) => item.quantity <= (item.min_threshold ?? 0))
                .map((item: any) => ({
                    title: stripPlaceholders(
                        titleTemplate
                            .replace(/\{\{item_name\}\}/g, item.name || "")
                            .replace(/\{\{quantity\}\}/g, String(item.quantity ?? 0))
                            .replace(/\{\{min_threshold\}\}/g, String(item.min_threshold ?? 0))
                    ),
                    message: stripPlaceholders(
                        messageTemplate
                            .replace(/\{\{item_name\}\}/g, item.name || "")
                            .replace(/\{\{quantity\}\}/g, String(item.quantity ?? 0))
                            .replace(/\{\{min_threshold\}\}/g, String(item.min_threshold ?? 0))
                    ),
                }));
        }

        default:
            return [{
                title: stripPlaceholders(titleTemplate),
                message: stripPlaceholders(messageTemplate),
            }];
    }
}

function computeInitialNextRunAtInternal(schedule: Pick<RecurringSchedule, "recurrence_type" | "time_of_day" | "days_of_week" | "day_of_month" | "start_date" | "cron_expression">): string {
    let hours: number;
    let minutes: number;

    if (schedule.recurrence_type === "custom" && schedule.cron_expression) {
        const expression = schedule.cron_expression.trim();
        if (expression.startsWith("EVERY:")) {
            const fakeSchedule = { ...schedule, last_run_at: null, next_run_at: null } as unknown as RecurringSchedule;
            return computeNextRunAt(fakeSchedule, dayjs()).toISOString();
        }

        const parts = expression.split(/\s+/);
        if (parts[0]?.startsWith("*/") || parts[1]?.startsWith("*/")) {
            const fakeSchedule = { ...schedule, last_run_at: null, next_run_at: null } as unknown as RecurringSchedule;
            return computeNextRunAt(fakeSchedule, dayjs()).toISOString();
        }

        minutes = parts[0] && !parts[0].includes("*") ? parseInt(parts[0], 10) : 0;
        hours = parts[1] && !parts[1].includes("*") ? parseInt(parts[1], 10) : 9;
        if (isNaN(hours)) hours = 9;
        if (isNaN(minutes)) minutes = 0;
    } else {
        [hours, minutes] = schedule.time_of_day.split(":").map(Number);
    }

    const startDay = dayjs(schedule.start_date).hour(hours).minute(minutes).second(0).millisecond(0);
    const now = dayjs();

    if (startDay.isAfter(now)) {
        return startDay.toISOString();
    }

    const fakeSchedule = { ...schedule, last_run_at: null, next_run_at: null } as unknown as RecurringSchedule;
    return computeNextRunAt(fakeSchedule, now).toISOString();
}

async function initializeScheduleIfNeeded(schedule: RecurringSchedule): Promise<boolean> {
    if (schedule.next_run_at) return false;

    const nextRunAt = computeInitialNextRunAtInternal({
        recurrence_type: schedule.recurrence_type,
        time_of_day: schedule.time_of_day,
        days_of_week: schedule.days_of_week,
        day_of_month: schedule.day_of_month,
        start_date: schedule.start_date,
        cron_expression: schedule.cron_expression,
    });

    const { error } = await supabase
        .from("recurring_notification_schedules")
        .update({ next_run_at: nextRunAt })
        .eq("id", schedule.id);

    if (error) {
        console.error(`[recurring-notifications] Failed to initialize schedule ${schedule.id}:`, error.message);
    } else {
        console.log(`[recurring-notifications] Initialized schedule ${schedule.id} (${schedule.name})`);
    }

    return true;
}

async function updateScheduleAfterRun(schedule: RecurringSchedule) {
    const now = dayjs();
    const nextRunAt = computeNextRunAt(schedule, now);
    const isExpired = schedule.end_date && dayjs(schedule.end_date).isBefore(nextRunAt, "day");

    const { error } = await supabase
        .from("recurring_notification_schedules")
        .update({
            last_run_at: now.toISOString(),
            next_run_at: isExpired ? null : nextRunAt.toISOString(),
            is_active: isExpired ? false : schedule.is_active,
        })
        .eq("id", schedule.id);

    if (error) {
        console.error(`[recurring-notifications] Failed to update schedule ${schedule.id}:`, error.message);
    }
}

async function insertInAppNotifications(
    schedule: RecurringSchedule,
    channels: RecurringSchedule["channels"],
    userIds: string[],
    notification: PreparedNotification,
    actionUrl: string | null
) {
    const rows = userIds.map((userId) => ({
        user_id: userId,
        title: notification.title,
        message: notification.message,
        type: schedule.type,
        priority: schedule.priority,
        action_url: actionUrl,
        channels,
        status: "sent",
        is_read: false,
    }));

    const batchSize = 100;
    for (let index = 0; index < rows.length; index += batchSize) {
        const { error } = await supabase.from("notifications").insert(rows.slice(index, index + batchSize));
        if (error) {
            console.error(`[recurring-notifications] insert batch error:`, error.message);
        }
    }
}

async function processSchedule(schedule: RecurringSchedule, updateTimestamps = true): Promise<{ success: boolean; initialized?: boolean; message?: string }> {
    let channels = schedule.channels;
    let userIds: string[] = [];
    let notifications: PreparedNotification[] = [];
    let actionUrl = schedule.action_url ?? null;
    let isReportNotification = false;

    if (updateTimestamps) {
        const initialized = await initializeScheduleIfNeeded(schedule);
        if (initialized) {
            return { success: true, initialized: true, message: "Schedule initialized" };
        }
    }

    if (schedule.auto_rule_id) {
        const rule = await resolveAutoRule(schedule.auto_rule_id);
        if (!rule) {
            console.warn(`[recurring-notifications] Schedule ${schedule.id} (${schedule.name}): linked auto-rule not found or inactive, skipping send`);
        } else {
            channels = rule.channels;
            userIds = await resolveUsersByRoles(rule.recipientRoleIds);
            isReportNotification = rule.isReportNotification;

            if (isReportNotification) {
                if (!rule.reportKey || !rule.reportDateRangeKey) {
                    return { success: false, message: "Report notification rule is missing report configuration" };
                }

                const reportDefinition = getReportDefinitionByKey(rule.reportKey);
                actionUrl = actionUrl ?? reportDefinition?.defaultActionUrl ?? null;
                notifications = [await prepareReportNotification({
                    triggerType: rule.triggerType,
                    reportKey: rule.reportKey,
                    reportDateRangeKey: rule.reportDateRangeKey,
                    subjectTemplate: rule.subjectTemplate,
                    messageTemplate: rule.messageTemplate,
                    emailTemplateId: rule.emailTemplateId,
                })];
            } else {
                notifications = await substituteTemplateVars(rule.subjectTemplate, rule.messageTemplate, rule.triggerType);
            }
        }
    } else {
        userIds = await resolveRecipients(schedule);
        notifications = [{ title: schedule.title, message: schedule.message }];
    }

    if (!userIds.length || !notifications.length) {
        console.log(`[recurring-notifications] Schedule ${schedule.id} (${schedule.name}): no recipients or no data, skipping`);
        if (updateTimestamps) {
            await updateScheduleAfterRun(schedule);
        }
        return { success: true, message: "No recipients or data" };
    }

    for (const notification of notifications) {
        if (channels.email) {
            const emailResult = await runEmailSender(
                userIds,
                notification.title,
                notification.message,
                actionUrl ?? undefined,
                {
                    htmlBody: notification.htmlBody,
                    textBody: notification.textBody,
                    attachments: notification.attachments,
                    recipientMode: isReportNotification ? "bcc" : "individual",
                }
            );
            console.log(`[recurring-notifications] Email: sent=${emailResult.sent}, failed=${emailResult.failed}`);

            if (isReportNotification && emailResult.failed > 0) {
                return { success: false, message: emailResult.errors[0] || "Report email send failed" };
            }
        }

        await insertInAppNotifications(schedule, channels, userIds, notification, actionUrl);

        if (channels.push) {
            const pushResult = await runPushSender(userIds, {
                title: notification.title,
                message: notification.message,
                url: actionUrl ?? undefined,
            });
            console.log(`[recurring-notifications] Push: sent=${pushResult.sent}, failed=${pushResult.failed}`);
        }

        if (channels.sms) {
            const smsResult = await runSmsSender(userIds, `${notification.title}: ${notification.message}`);
            console.log(`[recurring-notifications] SMS: sent=${smsResult.sent}, failed=${smsResult.failed}`);
        }

        if (channels.whatsapp) {
            const waResult = await runWhatsAppSender(userIds, `${notification.title}: ${notification.message}`);
            console.log(`[recurring-notifications] WhatsApp: sent=${waResult.sent}, failed=${waResult.failed}`);
        }
    }

    if (updateTimestamps) {
        await updateScheduleAfterRun(schedule);
    }

    return { success: true };
}

export async function processRecurringNotifications(): Promise<void> {
    if (isProcessingRecurringNotifications) {
        console.log("[recurring-notifications] Previous cycle is still running, skipping overlap");
        return;
    }

    isProcessingRecurringNotifications = true;
    try {
        const now = new Date().toISOString();
        const today = dayjs().format("YYYY-MM-DD");

        const { data: schedules, error } = await supabase
            .from("recurring_notification_schedules")
            .select("*")
            .eq("is_active", true)
            .or(`next_run_at.is.null,next_run_at.lte.${now}`)
            .or(`end_date.is.null,end_date.gte.${today}`)
            .lte("start_date", today);

        if (error) {
            console.error("[recurring-notifications] Fetch error:", error.message);
            return;
        }

        if (!schedules || schedules.length === 0) return;

        console.log(`[recurring-notifications] Processing ${schedules.length} due schedule(s)`);

        for (const schedule of schedules) {
            await processSchedule(schedule as RecurringSchedule);
        }
    } catch (err: any) {
        console.error("[recurring-notifications] Unhandled error:", err?.message ?? err);
    } finally {
        isProcessingRecurringNotifications = false;
    }
}

export async function sendScheduleNow(scheduleId: string): Promise<{ success: boolean; message: string }> {
    const { data: schedule, error } = await supabase
        .from("recurring_notification_schedules")
        .select("*")
        .eq("id", scheduleId)
        .single();

    if (error || !schedule) {
        return { success: false, message: error?.message ?? "Schedule not found" };
    }

    const result = await processSchedule(schedule as RecurringSchedule, false);
    return {
        success: result.success,
        message: result.message || (result.success ? "Notification sent successfully" : "Notification send failed"),
    };
}

export function computeInitialNextRunAt(schedule: Pick<RecurringSchedule, "recurrence_type" | "time_of_day" | "days_of_week" | "day_of_month" | "start_date" | "cron_expression">): string {
    return computeInitialNextRunAtInternal(schedule);
}
