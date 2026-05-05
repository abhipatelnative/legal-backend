import dayjs from 'dayjs';
import { createClient } from "@supabase/supabase-js";
import isSameOrBefore from 'dayjs/plugin/isSameOrBefore';
import isSameOrAfter from 'dayjs/plugin/isSameOrAfter';
import dotenv from "dotenv";
import {
  getSmtpSettings,
  sendEventNotificationEmail,
  logEventNotification,
  hasNotificationBeenSent,
  sendNotificationEmails,
  getEmailTemplateById,
  substituteTemplateVars,
} from './email-service';
import { sendPushNotificationsToUsers } from './web-push-service';
import { runSmsSender, runWhatsAppSender } from './notification-senders';
import { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } from './config/credentials';

dayjs.extend(isSameOrBefore);
dayjs.extend(isSameOrAfter);

dotenv.config();

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
// Service role for reading notification_auto_rules and user_roles (cron has no auth)
const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface CompanyEvent {
  id: string;
  title: string;
  description: string | null;
  start_date: string;
  end_date: string | null;
  event_type: string;
  is_recurring: boolean;
  recurrence_pattern: string | null;
  branch_id: string | null;
}

interface Employee {
  id: string;
  company_email: string;
  user_id: string;
  branch_id: string | null;
}

/**
 * Calculate the actual event date for recurring events
 * For recurring events, we need to calculate the next occurrence
 */
function calculateEventDate(event: CompanyEvent, currentYear: number): string {
  if (!event.is_recurring) {
    return event.start_date;
  }

  // For recurring events, calculate the date for the current year
  const originalDate = dayjs(event.start_date);
  const currentDate = dayjs();

  // Get the month and day from the original event
  const month = originalDate.month();
  const day = originalDate.date();

  // Create date for current year
  let eventDate = dayjs().year(currentYear).month(month).date(day);

  // If the date has already passed this year, use next year
  if (eventDate.isBefore(currentDate, 'day')) {
    eventDate = eventDate.add(1, 'year');
  }

  return eventDate.format('YYYY-MM-DD');
}

/**
 * Get the event date to use for notification (handles recurring events)
 */
function getEventDateForNotification(event: CompanyEvent): string {
  if (!event.is_recurring) {
    return event.start_date;
  }

  const currentYear = dayjs().year();
  return calculateEventDate(event, currentYear);
}

/**
 * Check if an event should trigger notifications today
 * Uses start-of-day for both dates so "N days before" is by calendar days, not time-of-day.
 */
function shouldSendNotificationToday(event: CompanyEvent, daysBefore: number, currentYear: number): boolean {
  const eventDate = calculateEventDate(event, currentYear);
  const today = dayjs().startOf('day');
  const targetDate = dayjs(eventDate).startOf('day');
  const daysUntilEvent = targetDate.diff(today, 'day');

  // Send notification if event is exactly 'daysBefore' days away
  return daysUntilEvent === daysBefore;
}

/** Event reminder auto-rule config from notification_auto_rules */
interface EventReminderRule {
  id: string;
  is_active: boolean;
  channels: { push?: boolean; email?: boolean; sms?: boolean; whatsapp?: boolean };
  subject_template: string | null;
  message_template: string | null;
  email_template_id: string | null;
  recipient_role_ids: string[];
}

/**
 * Fetch event_reminder notification rule and its recipient role IDs (service role).
 */
async function getEventReminderRule(): Promise<EventReminderRule | null> {
  try {
    const { data: rule, error: ruleError } = await supabaseAdmin
      .from('notification_auto_rules')
      .select('id, is_active, channels, subject_template, message_template, email_template_id')
      .eq('trigger_type', 'event_reminder')
      .maybeSingle();

    if (ruleError || !rule) {
      console.log('[Event notifications] No event_reminder rule found or error:', ruleError?.message);
      return null;
    }

    const { data: roleRows, error: roleError } = await supabaseAdmin
      .from('notification_auto_rule_roles')
      .select('role_id')
      .eq('rule_id', rule.id);

    if (roleError) {
      console.warn('[Event notifications] Failed to fetch rule roles:', roleError.message);
    }

    const recipient_role_ids = (roleRows || []).map((r: { role_id: string }) => r.role_id).filter(Boolean);
    const channels = typeof rule.channels === 'string' ? JSON.parse(rule.channels || '{}') : (rule.channels || {});

    return {
      id: rule.id,
      is_active: !!rule.is_active,
      channels: { push: !!channels.push, email: !!channels.email, sms: !!channels.sms, whatsapp: !!channels.whatsapp },
      subject_template: rule.subject_template ?? null,
      message_template: rule.message_template ?? null,
      email_template_id: rule.email_template_id ?? null,
      recipient_role_ids,
    };
  } catch (err) {
    console.error('[Event notifications] Error fetching event_reminder rule:', err);
    return null;
  }
}

/**
 * Resolve recipient user IDs: by rule roles (Admin, HR, Manager, Staff/Employee) or all employees.
 * When rule has role_ids, returns users with those roles. When empty, returns all active employees' user_id (optionally by branch).
 */
async function getEventRecipientUserIds(rule: EventReminderRule | null, branchId: string | null): Promise<string[]> {
  if (rule && rule.recipient_role_ids.length > 0) {
    const { data: userRoles, error } = await supabaseAdmin
      .from('user_roles')
      .select('user_id')
      .in('role_id', rule.recipient_role_ids)
      .eq('is_active', true);

    if (error) {
      console.error('[Event notifications] Error fetching users by role:', error);
      return [];
    }
    const userIds = [...new Set((userRoles || []).map((r: { user_id: string }) => r.user_id).filter(Boolean))];
    console.log(`[Event notifications] Resolved ${userIds.length} recipient(s) by roles`);
    return userIds;
  }

  const employees = await getActiveEmployees(branchId);
  const userIds = employees.map(e => e.user_id).filter(Boolean);
  console.log(`[Event notifications] Resolved ${userIds.length} recipient(s) (all employees for branch)`);
  return userIds;
}

/**
 * Get user_id -> employee_id map for users who have an employee record (for duplicate check and logging).
 */
async function getUserIdToEmployeeIdMap(userIds: string[]): Promise<Map<string, string>> {
  if (!userIds.length) return new Map();
  const { data, error } = await supabaseAdmin
    .from('employees')
    .select('user_id, id')
    .in('user_id', userIds)
    .eq('is_active', true)
    .eq('is_deleted', false);

  if (error) return new Map();
  const map = new Map<string, string>();
  (data || []).forEach((row: { user_id: string; id: string }) => {
    if (row.user_id && row.id) map.set(row.user_id, row.id);
  });
  return map;
}

/**
 * Get all active employees
 */
async function getActiveEmployees(branchId: string | null = null): Promise<Employee[]> {
  try {
    let query = supabase
      .from('employees')
      .select('id, company_email, user_id, branch_id')
      .eq('is_active', true)
      .eq('is_deleted', false);

    // Filter by branch if specified
    if (branchId) {
      query = query.eq('branch_id', branchId);
    }

    const { data, error } = await query;

    if (error) {
      console.error('Error fetching employees:', error);
      return [];
    }

    return data || [];
  } catch (error) {
    console.error('Error in getActiveEmployees:', error);
    return [];
  }
}

/**
 * Get upcoming events that need notifications
 */
async function getUpcomingEvents(daysBefore: number): Promise<CompanyEvent[]> {
  try {
    const today = dayjs();
    const currentYear = today.year();
    const nextYear = currentYear + 1;

    // Get all active events (including recurring ones)
    const { data, error } = await supabase
      .from('company_events')
      .select('*')
      .eq('is_active', true)
      .eq('is_deleted', false)
      .order('start_date', { ascending: true });

    if (error) {
      console.error('Error fetching events:', error);
      return [];
    }

    if (!data) {
      return [];
    }

    console.log(`[Event notifications] Loaded ${data.length} active event(s) from DB. Looking for events exactly ${daysBefore} days away.`);

    // Filter events that should trigger notifications today
    const eventsToNotify: CompanyEvent[] = [];

    for (const event of data) {
      const eventDate = getEventDateForNotification(event);
      const daysUntil = dayjs(eventDate).startOf('day').diff(today.startOf('day'), 'day');
      const match = daysUntil === daysBefore;
      console.log(`  - "${event.title}" (${event.start_date}) → event date ${eventDate}, ${daysUntil} days away → ${match ? 'INCLUDED' : 'skip (need exactly ' + daysBefore + ' days)'}`);

      // Check current year
      if (shouldSendNotificationToday(event, daysBefore, currentYear)) {
        eventsToNotify.push(event);
        continue;
      }

      // For recurring events, also check next year
      if (event.is_recurring && shouldSendNotificationToday(event, daysBefore, nextYear)) {
        eventsToNotify.push(event);
      }
    }

    return eventsToNotify;
  } catch (error) {
    console.error('Error in getUpcomingEvents:', error);
    return [];
  }
}

/**
 * Substitute template variables for event reminder (e.g. {{event_title}}, {{event_date}}, {{event_description}}).
 */
function substituteEventVars(template: string, event: CompanyEvent, eventDate: string): string {
  return template
    .replace(/\{\{event_title\}\}/g, event.title || '')
    .replace(/\{\{event_date\}\}/g, eventDate || '')
    .replace(/\{\{event_description\}\}/g, (event.description || '').substring(0, 200));
}

/**
 * Send event notifications for all upcoming events.
 * Uses event_reminder notification auto-rule: recipients (All / HR / Staff / Manager / Admin), channels (email, push), templates.
 */
export async function sendEventNotifications(): Promise<void> {
  try {
    console.log('Starting event notification process...');

    const smtpSettings = await getSmtpSettings();
    if (!smtpSettings) {
      console.log('No SMTP settings found. Skipping event notifications.');
      return;
    }

    if (!smtpSettings.enable_event_notifications) {
      console.log('Event notifications are disabled in SMTP settings. Skipping event notifications.');
      return;
    }

    const rule = await getEventReminderRule();
    if (!rule || !rule.is_active) {
      console.log('Event reminder rule not found or inactive. Skipping event notifications.');
      return;
    }

    const daysBefore = smtpSettings.days_before_event || 7;
    console.log(`Checking for events ${daysBefore} days in advance...`);
    console.log(`Today's date (server): ${dayjs().format('YYYY-MM-DD')}`);

    const events = await getUpcomingEvents(daysBefore);
    console.log(`Found ${events.length} events to notify about`);

    if (events.length === 0) {
      console.log('No events require notifications today.');
      return;
    }

    const today = dayjs().format('YYYY-MM-DD');
    let totalSent = 0;
    let totalFailed = 0;

    for (const event of events) {
      console.log(`Processing event: ${event.title} (ID: ${event.id})`);

      const eventDate = getEventDateForNotification(event);
      const userIds = await getEventRecipientUserIds(rule, event.branch_id || null);
      if (userIds.length === 0) {
        console.log(`No recipients for event ${event.title}, skipping.`);
        continue;
      }

      const userIdToEmployeeId = await getUserIdToEmployeeIdMap(userIds);

      // Filter: only users we have not already sent to today (for employees we check event_notification_log)
      const toNotify: string[] = [];
      for (const uid of userIds) {
        const employeeId = userIdToEmployeeId.get(uid);
        if (employeeId) {
          const alreadySent = await hasNotificationBeenSent(event.id, employeeId, today);
          if (!alreadySent) toNotify.push(uid);
        } else {
          toNotify.push(uid);
        }
      }

      if (toNotify.length === 0) {
        console.log(`All recipients already notified for event ${event.title}.`);
        continue;
      }

      const title = substituteEventVars(
        rule.subject_template || 'Upcoming event: {{event_title}}',
        event,
        eventDate
      );
      const message = substituteEventVars(
        rule.message_template || 'Reminder: {{event_title}} is scheduled for {{event_date}}.',
        event,
        eventDate
      );
      const actionUrl = '/events';

      const notificationsToInsert = toNotify.map(userId => ({
        user_id: userId,
        title,
        message,
        type: 'info',
        action_url: actionUrl,
        data: {
          event_id: event.id,
          event_title: event.title,
          event_date: eventDate,
          trigger_code: 'event_reminder',
          branch_id: event.branch_id || null,
        },
      }));

      const { error: insertError } = await supabaseAdmin.rpc('insert_notifications_for_users', {
        p_notifications: notificationsToInsert,
      });

      if (insertError) {
        console.error('[Event notifications] Failed to insert notifications:', insertError);
        totalFailed += toNotify.length;
        continue;
      }

      if (rule.channels.push) {
        const pushResult = await sendPushNotificationsToUsers(toNotify, {
          title,
          message,
          url: actionUrl,
        });
        totalSent += pushResult.success ?? 0;
        totalFailed += pushResult.failed ?? 0;
      }

      if (rule.channels.email) {
        let subject = title;
        let body = message;
        let htmlBodyOpt: { htmlBody?: string } | undefined;
        if (rule.email_template_id) {
          const template = await getEmailTemplateById(rule.email_template_id);
          if (template) {
            subject = substituteTemplateVars(template.subject, { title, message: body, action_url: actionUrl });
            const substitutedBody = substituteTemplateVars(template.body, { title, message: body, action_url: actionUrl });
            htmlBodyOpt = { htmlBody: substitutedBody };
          }
        }
        const emailResult = await sendNotificationEmails(toNotify, subject, body, actionUrl, htmlBodyOpt);
        totalSent += emailResult.sent;
        totalFailed += emailResult.failed;
      }

      if (rule.channels.sms) {
        const smsResult = await runSmsSender(toNotify, message);
        totalSent += smsResult.sent;
        totalFailed += smsResult.failed;
      }
      if (rule.channels.whatsapp) {
        const waResult = await runWhatsAppSender(toNotify, message);
        totalSent += waResult.sent;
        totalFailed += waResult.failed;
      }

      for (const userId of toNotify) {
        const employeeId = userIdToEmployeeId.get(userId);
        if (employeeId) {
          await logEventNotification(
            event.id,
            employeeId,
            today,
            eventDate,
            'sent',
            undefined
          );
        }
      }

      console.log(`✓ Event "${event.title}": notified ${toNotify.length} recipient(s).`);
      await new Promise(resolve => setTimeout(resolve, 100));
    }

    console.log(`Event notification process completed. Sent: ${totalSent}, Failed: ${totalFailed}`);
  } catch (error) {
    console.error('Error in sendEventNotifications:', error);
  }
}

