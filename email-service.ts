import nodemailer from 'nodemailer';
import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from './config/credentials';

dotenv.config();

// Use service role so server can read smtp_settings and employees (RLS would block anon)
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface SmtpSettings {
    host: string;
    port: number;
    username: string;
    password: string;
    encryption: string;
    from_email: string;
    from_name: string;
    days_before_event: number;
    enable_event_notifications: boolean;
}

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

export interface EmailAttachment {
    filename: string;
    content: Buffer | string;
    contentType?: string;
}

interface NotificationEmailOptions {
    htmlBody?: string;
    textBody?: string;
    attachments?: EmailAttachment[];
    recipientMode?: 'individual' | 'bcc';
}

/**
 * Get active SMTP settings from database
 */
export async function getSmtpSettings(): Promise<SmtpSettings | null> {
    try {
        const { data, error } = await supabase
            .from('smtp_settings')
            .select('*')
            .eq('is_deleted', false)
            .eq('is_active', true)
            .maybeSingle();

        if (error) {
            console.error('Error fetching SMTP settings:', error);
            return null;
        }

        if (!data) {
            console.log('No active SMTP settings found');
            return null;
        }

        return {
            host: data.host,
            port: data.port,
            username: data.username,
            password: data.password,
            encryption: data.encryption || 'tls',
            from_email: data.from_email,
            from_name: data.from_name || 'Company',
            days_before_event: data.days_before_event || 7,
            enable_event_notifications: data.enable_event_notifications !== false,
        };
    } catch (error) {
        console.error('Error in getSmtpSettings:', error);
        return null;
    }
}

/**
 * Convert raw SMTP error messages into user-friendly text.
 */
function friendlySmtpError(rawMessage: string): string {
    const msg = (rawMessage || '').toLowerCase();

    if (msg.includes('daily') && msg.includes('sending limit')) {
        return 'Email sending limit reached for today. Please try again after 24 hours.';
    }
    if (msg.includes('too many') && (msg.includes('recipient') || msg.includes('connection'))) {
        return 'Too many emails sent. Please wait a while and try again.';
    }
    if (msg.includes('authentication') || msg.includes('auth') && msg.includes('fail')) {
        return 'Email server authentication failed. Please check your SMTP credentials in Settings.';
    }
    if (msg.includes('connect') && (msg.includes('timeout') || msg.includes('refused'))) {
        return 'Unable to connect to the email server. Please check your SMTP host and port in Settings.';
    }
    if (msg.includes('invalid') && msg.includes('address')) {
        return 'The recipient email address is invalid.';
    }
    if (msg.includes('rate limit') || msg.includes('throttl')) {
        return 'Email rate limit exceeded. Please try again in a few minutes.';
    }

    return rawMessage;
}

/**
 * Create nodemailer transporter from SMTP settings
 */
function createTransporter(settings: SmtpSettings) {
    const config: any = {
        host: settings.host,
        port: settings.port,
        secure: settings.encryption === 'ssl',
        auth: {
            user: settings.username,
            pass: settings.password,
        },
    };

    if (settings.encryption === 'tls') {
        config.requireTLS = true;
    }

    return nodemailer.createTransport(config);
}

/**
 * Send event notification email to an employee
 */
export async function sendEventNotificationEmail(
    employee: Employee,
    event: CompanyEvent,
    smtpSettings: SmtpSettings
): Promise<boolean> {
    try {
        const transporter = createTransporter(smtpSettings);

        // Format event date
        const eventDate = new Date(event.start_date);
        const formattedDate = eventDate.toLocaleDateString('en-US', {
            weekday: 'long',
            year: 'numeric',
            month: 'long',
            day: 'numeric',
        });

        // Format event type
        const eventTypeLabels: { [key: string]: string } = {
            company: 'Company Event',
            holiday: 'Holiday',
            meeting: 'Meeting',
            celebration: 'Celebration',
            other: 'Event',
        };

        const eventTypeLabel = eventTypeLabels[event.event_type] || 'Event';

        // Create email subject
        const subject = `Upcoming ${eventTypeLabel}: ${event.title}`;

        // Create email body
        const htmlBody = `
      <!DOCTYPE html>
      <html>
      <head>
        <style>
          body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
          .container { max-width: 600px; margin: 0 auto; padding: 20px; }
          .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 5px 5px 0 0; }
          .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 5px 5px; }
          .event-card { background-color: white; padding: 20px; margin: 20px 0; border-left: 4px solid #4F46E5; border-radius: 4px; }
          .event-title { font-size: 24px; font-weight: bold; color: #1f2937; margin-bottom: 10px; }
          .event-date { font-size: 18px; color: #4F46E5; margin-bottom: 15px; }
          .event-description { color: #6b7280; margin-top: 10px; }
          .footer { text-align: center; margin-top: 30px; color: #9ca3af; font-size: 12px; }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>Upcoming ${eventTypeLabel}</h1>
          </div>
          <div class="content">
            <p>Dear Employee,</p>
            <p>This is a reminder about an upcoming ${eventTypeLabel.toLowerCase()}:</p>
            
            <div class="event-card">
              <div class="event-title">${event.title}</div>
              <div class="event-date">📅 ${formattedDate}</div>
              ${event.description ? `<div class="event-description">${event.description}</div>` : ''}
            </div>
            
            <p>Please mark your calendar and plan accordingly.</p>
            
            <div class="footer">
              <p>This is an automated notification from your HR system.</p>
              <p>Please do not reply to this email.</p>
            </div>
          </div>
        </div>
      </body>
      </html>
    `;

        const textBody = `
Upcoming ${eventTypeLabel}: ${event.title}

Date: ${formattedDate}
${event.description ? `Description: ${event.description}` : ''}

Please mark your calendar and plan accordingly.

This is an automated notification from your HR system.
    `;

        const mailOptions = {
            from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
            to: employee.company_email,
            subject: subject,
            text: textBody,
            html: htmlBody,
        };

        const info = await transporter.sendMail(mailOptions);
        console.log(`Email sent successfully to ${employee.company_email} for event ${event.id}:`, info.messageId);
        return true;
    } catch (error: any) {
        console.error(`Error sending email to ${employee.company_email} for event ${event.id}:`, error);
        return false;
    }
}

/**
 * Test SMTP connection and send a test email
 */
export async function testSmtpConnection(sendTestEmail: boolean = false): Promise<{ success: boolean; message: string }> {
    try {
        console.log('Testing SMTP configuration...');

        const smtpSettings = await getSmtpSettings();
        if (!smtpSettings) {
            return {
                success: false,
                message: 'No SMTP settings found. Please configure SMTP settings in the admin panel.'
            };
        }

        // Create transporter
        const transporter = createTransporter(smtpSettings);

        // Test connection
        console.log('Verifying SMTP connection...');
        await transporter.verify();
        console.log('✓ SMTP connection verified successfully');

        if (sendTestEmail) {
            // Get first active employee email for test
            const { data: employees } = await supabase
                .from('employees')
                .select('company_email')
                .eq('is_active', true)
                .eq('is_deleted', false)
                .limit(1);

            const testEmail = employees && employees.length > 0
                ? employees[0].company_email
                : smtpSettings.from_email;

            const testMailOptions = {
                from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
                to: testEmail,
                subject: 'Test Email - Event Notification System',
                text: 'This is a test email from the Event Notification System. If you receive this, the email configuration is working correctly.',
                html: `
          <!DOCTYPE html>
          <html>
          <head>
            <style>
              body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
              .container { max-width: 600px; margin: 0 auto; padding: 20px; }
              .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 5px 5px 0 0; }
              .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 5px 5px; }
              .success { color: #10b981; font-weight: bold; }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="header">
                <h1>✓ Email Test Successful</h1>
              </div>
              <div class="content">
                <p>This is a test email from the Event Notification System.</p>
                <p class="success">If you receive this email, your SMTP configuration is working correctly!</p>
                <p>The system will automatically send event notifications to employees based on your configured settings.</p>
                <p><strong>Notification Settings:</strong></p>
                <ul>
                  <li>Days before event: ${smtpSettings.days_before_event} days</li>
                  <li>From: ${smtpSettings.from_name} &lt;${smtpSettings.from_email}&gt;</li>
                </ul>
              </div>
            </div>
          </body>
          </html>
        `,
            };

            console.log(`Sending test email to ${testEmail}...`);
            const info = await transporter.sendMail(testMailOptions);
            console.log(`✓ Test email sent successfully! Message ID: ${info.messageId}`);

            return {
                success: true,
                message: `SMTP connection verified and test email sent successfully to ${testEmail}`
            };
        }

        return {
            success: true,
            message: 'SMTP connection verified successfully'
        };
    } catch (error: any) {
        console.error('✗ SMTP test failed:', error);
        return {
            success: false,
            message: `SMTP test failed: ${error.message || 'Unknown error'}`
        };
    }
}

/**
 * Send a test email to a specific email address
 */
export async function sendTestEmailToAddress(emailAddress: string): Promise<{ success: boolean; message: string }> {
    try {
        console.log(`Sending test email to ${emailAddress}...`);

        const smtpSettings = await getSmtpSettings();
        if (!smtpSettings) {
            return {
                success: false,
                message: 'No SMTP settings found. Please configure SMTP settings in the admin panel.'
            };
        }

        // Validate email address
        const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        if (!emailRegex.test(emailAddress)) {
            return {
                success: false,
                message: 'Invalid email address format.'
            };
        }

        // Create transporter
        const transporter = createTransporter(smtpSettings);

        // Test connection first
        console.log('Verifying SMTP connection...');
        await transporter.verify();
        console.log('✓ SMTP connection verified successfully');

        const testMailOptions = {
            from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
            to: emailAddress,
            subject: 'Test Email - Event Notification System',
            text: 'This is a test email from the Event Notification System. If you receive this, the email configuration is working correctly.',
            html: `
      <!DOCTYPE html>
      <html>
      <head>
        <style>
          body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
          .container { max-width: 600px; margin: 0 auto; padding: 20px; }
          .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 5px 5px 0 0; }
          .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 5px 5px; }
          .success { color: #10b981; font-weight: bold; }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>✓ Email Test Successful</h1>
          </div>
          <div class="content">
            <p>This is a test email from the Event Notification System.</p>
            <p class="success">If you receive this email, your SMTP configuration is working correctly!</p>
            <p>The system will automatically send event notifications to employees based on your configured settings.</p>
            <p><strong>Notification Settings:</strong></p>
            <ul>
              <li>Days before event: ${smtpSettings.days_before_event} days</li>
              <li>From: ${smtpSettings.from_name} &lt;${smtpSettings.from_email}&gt;</li>
              <li>Event notifications: ${smtpSettings.enable_event_notifications ? 'Enabled' : 'Disabled'}</li>
            </ul>
          </div>
        </div>
      </body>
      </html>
    `,
        };

        console.log(`Sending test email to ${emailAddress}...`);
        const info = await transporter.sendMail(testMailOptions);
        console.log(`✓ Test email sent successfully! Message ID: ${info.messageId}`);

        return {
            success: true,
            message: `Test email sent successfully to ${emailAddress}`
        };
    } catch (error: any) {
        console.error(`✗ Failed to send test email to ${emailAddress}:`, error);
        return {
            success: false,
            message: `Failed to send test email: ${error.message || 'Unknown error'}`
        };
    }
}

/**
 * Get a single email template by ID (for notification emails).
 */
export async function getEmailTemplateById(id: string): Promise<{ subject: string; body: string } | null> {
    try {
        const { data, error } = await supabase
            .from('email_templates')
            .select('subject, body')
            .eq('id', id)
            .eq('is_deleted', false)
            .maybeSingle();
        if (error || !data) return null;
        return { subject: data.subject || '', body: data.body || '' };
    } catch (e) {
        console.error('[Email] getEmailTemplateById error:', e);
        return null;
    }
}

/**
 * Substitute {{title}}, {{message}}, {{action_url}} in a string.
 */
export function substituteTemplateVars(
    text: string,
    vars: { title?: string; message?: string; action_url?: string }
): string {
    if (!text) return '';
    return text
        .replace(/\{\{title\}\}/g, vars.title ?? '')
        .replace(/\{\{message\}\}/g, vars.message ?? '')
        .replace(/\{\{action_url\}\}/g, vars.action_url ?? '');
}

/**
 * Substitute {{variable_name}} placeholders using any provided key/value map.
 */
export function substituteTemplateVarsGeneric(
    text: string,
    vars: Record<string, string | undefined>
): string {
    if (!text) return '';
    return text.replace(/\{\{(\w+)\}\}/g, (_, key: string) => vars[key] ?? '');
}

/**
 * Resolve user IDs to email addresses.
 * Tries (in order): employees.company_email → employees.personal_email →
 * auth.users.email (via supabase.auth.admin.getUserById). Users with no
 * email anywhere are skipped.
 */
export async function getEmailsForUserIds(userIds: string[]): Promise<Map<string, string>> {
    const result = new Map<string, string>();
    if (!userIds || userIds.length === 0) return result;

    const uniqueUserIds = [...new Set(userIds.filter(Boolean))];

    // 1) Prefer employees.company_email; fall back to employees.personal_email.
    const { data: employeeRows, error: employeeError } = await supabase
        .from('employees')
        .select('user_id, company_email, personal_email')
        .in('user_id', uniqueUserIds)
        .eq('is_active', true)
        .eq('is_deleted', false);

    if (employeeError) {
        console.error('[Email] Error fetching employee emails:', employeeError);
    } else {
        (employeeRows || []).forEach((row: any) => {
            const company = (row.company_email || '').trim();
            const personal = (row.personal_email || '').trim();
            const email = company || personal;
            if (email) result.set(row.user_id, email);
        });
    }

    // 2) For any user_id still without an email (not in employees, or both
    //    employee email columns blank), fall back to auth.users.email via the
    //    Supabase admin API. Catches admins/managers who exist as auth users
    //    but don't have an employees row.
    const stillMissing = uniqueUserIds.filter((id) => !result.has(id));
    if (stillMissing.length > 0) {
        await Promise.all(stillMissing.map(async (id) => {
            try {
                const { data, error } = await (supabase as any).auth.admin.getUserById(id);
                if (!error) {
                    const email = ((data as any)?.user?.email || '').trim();
                    if (email) result.set(id, email);
                }
            } catch {
                // Ignore per-user errors; totals are logged below.
            }
        }));
    }

    const noEmail = uniqueUserIds.filter((id) => !result.has(id));
    const emails = [...result.values()];
    console.log(`[Email] Resolved ${result.size}/${uniqueUserIds.length} emails` +
        (result.size > 0 ? ` (sample: ${emails.slice(0, 3).join(", ")}${emails.length > 3 ? "..." : ""})` : "") +
        (noEmail.length > 0 ? ` | ${noEmail.length} skipped (no company_email, personal_email, or auth email)` : ""));

    return result;
}

/**
 * Send notification emails via SMTP to a list of user IDs
 * (resolves via company_email, then personal_email, then auth email).
 * Used by the notification module when email channel is selected in auto rules.
 * When htmlBody is provided (e.g. from a custom email template), it is used as the email HTML; otherwise a default layout is built from message.
 */
export async function sendNotificationEmails(
    userIds: string[],
    subject: string,
    message: string,
    actionUrl?: string,
    options?: NotificationEmailOptions
): Promise<{ sent: number; failed: number; errors: string[] }> {
    const outcome = { sent: 0, failed: 0, errors: [] as string[] };

    const smtpSettings = await getSmtpSettings();
    if (!smtpSettings) {
        console.log("[Email] sendNotificationEmails: No SMTP settings in DB. Configure SMTP in Settings.");
        outcome.errors.push('No SMTP settings found. Configure SMTP in Settings.');
        return outcome;
    }
    console.log("[Email] SMTP configured: from=" + smtpSettings.from_email + " host=" + smtpSettings.host);

    const userToEmail = await getEmailsForUserIds(userIds);
    const emailsToSend = [...new Set(userToEmail.values())].filter(Boolean);

    if (emailsToSend.length === 0) {
        console.log("[Email] No recipient emails resolved for userIds (no company_email, personal_email, or auth email found).");
        outcome.errors.push('No valid recipient emails found for the given user IDs.');
        return outcome;
    }
    console.log("[Email] Sending to " + emailsToSend.length + " address(es)...");

    const htmlBody = options?.htmlBody ?? `
      <!DOCTYPE html>
      <html>
      <head>
        <style>
          body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
          .container { max-width: 600px; margin: 0 auto; padding: 20px; }
          .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 5px 5px 0 0; }
          .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 5px 5px; }
          .message { white-space: pre-wrap; margin: 16px 0; }
          .cta { margin-top: 24px; }
          .cta a { display: inline-block; background-color: #4F46E5; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; font-weight: bold; }
          .footer { text-align: center; margin-top: 30px; color: #9ca3af; font-size: 12px; }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>Notification</h1>
          </div>
          <div class="content">
            <div class="message">${(message || '').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\n/g, '<br/>')}</div>
            ${actionUrl ? `<div class="cta"><a href="${actionUrl}">View in app</a></div>` : ''}
            <div class="footer">
              <p>This is an automated notification from your HR system.</p>
            </div>
          </div>
        </div>
      </body>
      </html>
    `;

    const textBody = options?.textBody ?? (message || '') + (actionUrl ? `\n\nView in app: ${actionUrl}` : '');
    const attachments = options?.attachments ?? [];
    const recipientMode = options?.recipientMode ?? 'individual';

    try {
        const transporter = createTransporter(smtpSettings);

        if (recipientMode === 'bcc') {
            try {
                const info = await transporter.sendMail({
                    from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
                    to: smtpSettings.from_email,
                    bcc: emailsToSend,
                    subject: subject || 'Notification',
                    text: textBody,
                    html: htmlBody,
                    attachments,
                });
                outcome.sent = emailsToSend.length;
                console.log("[Email] Sent BCC email to " + emailsToSend.length + " recipient(s) messageId=" + (info.messageId || ""));
            } catch (err: any) {
                outcome.failed = emailsToSend.length;
                const errMsg = err.message || 'Send failed';
                outcome.errors.push(friendlySmtpError(errMsg));
                console.error("[Email] Failed BCC send:", errMsg);
            }
        } else {
            for (const to of emailsToSend) {
                try {
                    const info = await transporter.sendMail({
                        from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
                        to,
                        subject: subject || 'Notification',
                        text: textBody,
                        html: htmlBody,
                        attachments,
                    });
                    outcome.sent++;
                    console.log("[Email] Sent to " + to + " messageId=" + (info.messageId || ""));
                } catch (err: any) {
                    outcome.failed++;
                    const errMsg = err.message || 'Send failed';
                    outcome.errors.push(friendlySmtpError(errMsg));
                    console.error("[Email] Failed to send to " + to + ":", errMsg);
                }
            }
        }
        console.log("[Email] sendNotificationEmails finished: sent=" + outcome.sent + " failed=" + outcome.failed);
    } catch (err: any) {
        outcome.errors.push(friendlySmtpError(err.message || 'SMTP error'));
        console.error("[Email] sendNotificationEmails error:", err);
    }

    return outcome;
}

/**
 * Send emails directly to external addresses instead of resolving user IDs.
 */
export async function sendEmailsToAddresses(
    emailAddresses: string[],
    subject: string,
    message: string,
    actionUrl?: string,
    options?: NotificationEmailOptions
): Promise<{ sent: number; failed: number; errors: string[] }> {
    const outcome = { sent: 0, failed: 0, errors: [] as string[] };

    const smtpSettings = await getSmtpSettings();
    if (!smtpSettings) {
        outcome.errors.push('No SMTP settings found. Configure SMTP in Settings.');
        return outcome;
    }

    const validEmails = [...new Set((emailAddresses || []).map((email) => (email || '').trim()).filter(Boolean))];
    if (validEmails.length === 0) {
        outcome.errors.push('No valid recipient emails provided.');
        return outcome;
    }

    const htmlBody = options?.htmlBody ?? `
      <!DOCTYPE html>
      <html>
      <head>
        <style>
          body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
          .container { max-width: 600px; margin: 0 auto; padding: 20px; }
          .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 5px 5px 0 0; }
          .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 5px 5px; }
          .message { white-space: pre-wrap; margin: 16px 0; }
          .cta { margin-top: 24px; }
          .cta a { display: inline-block; background-color: #4F46E5; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; font-weight: bold; }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>Notification</h1>
          </div>
          <div class="content">
            <div class="message">${(message || '').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\n/g, '<br/>')}</div>
            ${actionUrl ? `<div class="cta"><a href="${actionUrl}">View details</a></div>` : ''}
          </div>
        </div>
      </body>
      </html>
    `;

    const textBody = options?.textBody ?? (message || '') + (actionUrl ? `\n\nView details: ${actionUrl}` : '');
    const attachments = options?.attachments ?? [];
    const recipientMode = options?.recipientMode ?? 'individual';

    try {
        const transporter = createTransporter(smtpSettings);

        if (recipientMode === 'bcc') {
            try {
                const info = await transporter.sendMail({
                    from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
                    to: smtpSettings.from_email,
                    bcc: validEmails,
                    subject: subject || 'Notification',
                    text: textBody,
                    html: htmlBody,
                    attachments,
                });
                outcome.sent = validEmails.length;
                console.log("[Email] Sent external BCC email to " + validEmails.length + " recipient(s) messageId=" + (info.messageId || ""));
            } catch (err: any) {
                outcome.failed = validEmails.length;
                const errMsg = err.message || 'Send failed';
                outcome.errors.push(friendlySmtpError(errMsg));
                console.error("[Email] Failed external BCC email:", errMsg);
            }
        } else {
            for (const to of validEmails) {
                try {
                    const info = await transporter.sendMail({
                        from: `"${smtpSettings.from_name}" <${smtpSettings.from_email}>`,
                        to,
                        subject: subject || 'Notification',
                        text: textBody,
                        html: htmlBody,
                        attachments,
                    });
                    outcome.sent++;
                    console.log("[Email] Sent external email to " + to + " messageId=" + (info.messageId || ""));
                } catch (err: any) {
                    outcome.failed++;
                    const errMsg = err.message || 'Send failed';
                    outcome.errors.push(friendlySmtpError(errMsg));
                    console.error("[Email] Failed external email to " + to + ":", errMsg);
                }
            }
        }
    } catch (err: any) {
        outcome.errors.push(friendlySmtpError(err.message || 'SMTP error'));
        console.error("[Email] sendEmailsToAddresses error:", err);
    }

    return outcome;
}

/**
 * Log event notification in database
 */
export async function logEventNotification(
    eventId: string,
    employeeId: string,
    notificationDate: string,
    eventDate: string,
    emailStatus: 'sent' | 'failed' | 'pending',
    errorMessage?: string
): Promise<void> {
    try {
        const { error } = await supabase
            .from('event_notification_log')
            .insert({
                event_id: eventId,
                employee_id: employeeId,
                notification_date: notificationDate,
                event_date: eventDate,
                email_status: emailStatus,
                error_message: errorMessage || null,
            });

        if (error) {
            console.error('Error logging event notification:', error);
        }
    } catch (error) {
        console.error('Error in logEventNotification:', error);
    }
}

/**
 * Check if notification was already sent for this event and employee
 */
export async function hasNotificationBeenSent(
    eventId: string,
    employeeId: string,
    notificationDate: string
): Promise<boolean> {
    try {
        const { data, error } = await supabase
            .from('event_notification_log')
            .select('id')
            .eq('event_id', eventId)
            .eq('employee_id', employeeId)
            .eq('notification_date', notificationDate)
            .eq('email_status', 'sent')
            .maybeSingle();

        if (error) {
            console.error('Error checking notification log:', error);
            return false;
        }

        return !!data;
    } catch (error) {
        console.error('Error in hasNotificationBeenSent:', error);
        return false;
    }
}

