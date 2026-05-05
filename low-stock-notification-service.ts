import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";
import { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } from './config/credentials';
import { sendPushNotificationsToUsers } from "./web-push-service";
import { sendNotificationEmails, getEmailTemplateById, substituteTemplateVars } from "./email-service";
import { runSmsSender, runWhatsAppSender } from "./notification-senders";

dotenv.config();

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

/** Low stock auto-rule config */
interface LowStockRule {
  id: string;
  is_active: boolean;
  channels: { push?: boolean; email?: boolean; sms?: boolean; whatsapp?: boolean };
  subject_template: string | null;
  message_template: string | null;
  email_template_id: string | null;
  recipient_role_ids: string[];
}

async function getLowStockRule(): Promise<LowStockRule | null> {
  try {
    const { data: rule, error: ruleError } = await supabaseAdmin
      .from('notification_auto_rules')
      .select('id, is_active, channels, subject_template, message_template, email_template_id')
      .eq('trigger_type', 'low_stock')
      .maybeSingle();

    if (ruleError || !rule) return null;

    const { data: roleRows } = await supabaseAdmin
      .from('notification_auto_rule_roles')
      .select('role_id')
      .eq('rule_id', rule.id);

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
    console.error('[Low stock] Error fetching rule:', err);
    return null;
  }
}

/** Resolve recipient user IDs from rule roles, or fallback to get_admin_user_ids_for_notifications */
async function getRecipientUserIds(rule: LowStockRule | null): Promise<string[]> {
  if (rule && rule.recipient_role_ids.length > 0) {
    const { data: userRoles, error } = await supabaseAdmin
      .from('user_roles')
      .select('user_id')
      .in('role_id', rule.recipient_role_ids)
      .eq('is_active', true);

    if (!error && userRoles?.length) {
      const userIds = [...new Set(userRoles.map((r: { user_id: string }) => r.user_id).filter(Boolean))];
      console.log(`[Low stock] Resolved ${userIds.length} recipient(s) from rule roles`);
      return userIds;
    }
  }

  const { data: adminUserIds, error } = await supabaseAdmin.rpc('get_admin_user_ids_for_notifications');
  if (error || !adminUserIds?.length) return [];
  const fallback = adminUserIds.map((row: { user_id: string }) => row.user_id).filter(Boolean);
  console.log(`[Low stock] Using fallback admin/HR/Manager recipients: ${fallback.length}`);
  return fallback;
}

function substituteLowStockVars(template: string, itemName: string, quantity: number, minThreshold: number): string {
  return template
    .replace(/\{\{item_name\}\}/g, itemName)
    .replace(/\{\{quantity\}\}/g, String(quantity))
    .replace(/\{\{min_threshold\}\}/g, String(minThreshold));
}

interface LowStockNotificationData {
    inventoryItemId: string;
    itemName: string;
    currentQuantity: number;
    minThreshold: number;
    branchId?: string | null;
}

/**
 * Check if a notification was already sent for this item recently
 * This prevents duplicate notifications, but allows re-notification if:
 * 1. Quantity has changed significantly (dropped further), OR
 * 2. More than 24 hours have passed since last notification
 */
async function hasNotificationBeenSent(
    inventoryItemId: string,
    currentQuantity: number
): Promise<boolean> {
    try {
        // Check if there's a recent notification for THIS SPECIFIC item in the last 24 hours
        const { data: recentNotifications, error } = await supabase
            .from('notifications')
            .select('id, data, created_at')
            .eq('type', 'inventory')
            .eq('is_deleted', false)
            .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()) // Last 24 hours
            .order('created_at', { ascending: false });

        if (error) {
            console.error('Error checking existing notifications:', error);
            return false; // If error, allow notification to proceed
        }

        if (!recentNotifications || recentNotifications.length === 0) {
            return false; // No recent notifications found
        }

        // Find notifications for this specific inventory item
        const itemNotifications = recentNotifications.filter(notif => {
            if (!notif.data) return false;
            const notificationInfo = notif.data as any;
            return notificationInfo.inventory_item_id === inventoryItemId;
        });

        if (itemNotifications.length === 0) {
            return false; // No recent notification for this item
        }

        // Get the most recent notification for this item
        const mostRecent = itemNotifications[0];
        const notificationInfo = mostRecent.data as any;
        const previousQuantity = notificationInfo.quantity;

        // Allow notification if:
        // 1. Quantity has dropped further (more urgent)
        // 2. More than 24 hours have passed
        // 3. This is a different stock level
        if (currentQuantity < previousQuantity) {
            console.log(`Quantity dropped from ${previousQuantity} to ${currentQuantity}, allowing new notification`);
            return false; // Quantity dropped, allow notification
        }

        // If quantity is the same or higher, check if enough time has passed
        const notificationTime = new Date(mostRecent.created_at).getTime();
        const timeSinceNotification = Date.now() - notificationTime;
        const hoursSinceNotification = timeSinceNotification / (1000 * 60 * 60);

        // Allow re-notification after 24 hours even if quantity is same
        if (hoursSinceNotification >= 24) {
            console.log(`${hoursSinceNotification.toFixed(1)} hours since last notification, allowing re-notification`);
            return false;
        }

        // Same item, same or higher quantity, within 24 hours - don't send duplicate
        console.log(`Notification already sent for item ${inventoryItemId} at quantity ${currentQuantity} (previous: ${previousQuantity}) ${hoursSinceNotification.toFixed(1)} hours ago`);
        return true;
    } catch (error) {
        console.error('Error in hasNotificationBeenSent:', error);
        return false; // If error, allow notification to proceed
    }
}

/**
 * Send low stock notifications to Admin, HR Manager, Manager, and HR users
 */
export async function sendLowStockNotifications(
    notificationData: LowStockNotificationData
): Promise<{ success: boolean; message: string; notificationsCreated: number; pushSent: number }> {
    try {
        const { inventoryItemId, itemName, currentQuantity, minThreshold, branchId } = notificationData;

        // Check if notification was already sent for this quantity
        const alreadySent = await hasNotificationBeenSent(inventoryItemId, currentQuantity);
        if (alreadySent) {
            console.log(`Notification already sent for item ${itemName} at quantity ${currentQuantity}`);
            return {
                success: true,
                message: 'Notification already sent for this stock level',
                notificationsCreated: 0,
                pushSent: 0
            };
        }

        const rule = await getLowStockRule();
        if (!rule || !rule.is_active) {
            console.log('[Low stock] No active low_stock rule; using fallback admin recipients and push only.');
        }

        const userIds = await getRecipientUserIds(rule);
        if (!userIds.length) {
            console.log('[Low stock] No recipients found.');
            return { success: true, message: 'No recipients configured', notificationsCreated: 0, pushSent: 0 };
        }

        const subjectTemplate = rule?.subject_template ?? 'Low stock: {{item_name}}';
        const messageTemplate = rule?.message_template ?? "Stock alert: '{{item_name}}' has only {{quantity}} units remaining (minimum required: {{min_threshold}}).";
        const title = substituteLowStockVars(subjectTemplate, itemName, currentQuantity, minThreshold);
        const message = substituteLowStockVars(messageTemplate, itemName, currentQuantity, minThreshold);
        const actionUrl = '/inventory?tab=alerts';

        const notificationsToInsert = userIds.map((uid) => ({
            user_id: uid,
            title,
            message,
            type: 'inventory',
            action_url: actionUrl,
            data: {
                inventory_item_id: inventoryItemId,
                item_name: itemName,
                quantity: currentQuantity,
                min_threshold: minThreshold,
                branch_id: branchId,
                reference_type: 'low_stock',
            },
        }));

        const { error: insertError } = await supabaseAdmin.rpc('insert_notifications_for_users', {
            p_notifications: notificationsToInsert,
        });

        if (insertError) {
            console.error('[Low stock] Insert notifications error:', insertError);
            return { success: false, message: String(insertError.message), notificationsCreated: 0, pushSent: 0 };
        }

        const notificationsCreated = userIds.length;
        let pushSent = 0;

        if (!rule || rule.channels.push !== false) {
            const pushResult = await sendPushNotificationsToUsers(userIds, { title, message, url: actionUrl });
            pushSent = pushResult.success ?? 0;
        }

        if (rule?.channels.email) {
            let subject = title;
            let body = message;
            let htmlBodyOpt: { htmlBody?: string } | undefined;
            if (rule.email_template_id) {
                const template = await getEmailTemplateById(rule.email_template_id);
                if (template) {
                    subject = substituteTemplateVars(template.subject, { title, message: body, action_url: actionUrl });
                    body = substituteTemplateVars(template.body, { title, message: body, action_url: actionUrl });
                    htmlBodyOpt = { htmlBody: body };
                }
            }
            await sendNotificationEmails(userIds, subject, message, actionUrl, htmlBodyOpt);
        }

        if (rule?.channels.sms) {
            const smsResult = await runSmsSender(userIds, message);
            if (smsResult.sent > 0 || smsResult.failed > 0) {
                console.log(`[Low stock] SMS: sent=${smsResult.sent}, failed=${smsResult.failed}`);
            }
        }
        if (rule?.channels.whatsapp) {
            const waResult = await runWhatsAppSender(userIds, message);
            if (waResult.sent > 0 || waResult.failed > 0) {
                console.log(`[Low stock] WhatsApp: sent=${waResult.sent}, failed=${waResult.failed}`);
            }
        }

        console.log(`[Low stock] Sent to ${userIds.length} recipient(s), push=${pushSent}`);
        return {
            success: true,
            message: 'Notifications created and sent',
            notificationsCreated,
            pushSent,
        };
    } catch (error: any) {
        console.error('Error in sendLowStockNotifications:', error);
        return {
            success: false,
            message: error.message || 'Failed to send low stock notifications',
            notificationsCreated: 0,
            pushSent: 0
        };
    }
}

/**
 * Check inventory item after issuance and send notification if low stock
 * This should be called after an inventory item is issued
 */
export async function checkAndNotifyLowStock(
    inventoryItemId: string,
    branchId?: string | null,
    providedQuantity?: number,
    providedItemName?: string,
    providedMinThreshold?: number
): Promise<{ success: boolean; message: string; notificationSent: boolean }> {
    try {
        let item: { id: string; name: string; quantity: number; min_threshold: number; status: string } | null = null;

        // If quantity and item details are provided, use them (avoids RLS issues and timing problems)
        if (providedQuantity !== undefined && providedItemName && providedMinThreshold !== undefined) {
            item = {
                id: inventoryItemId,
                name: providedItemName,
                quantity: providedQuantity,
                min_threshold: providedMinThreshold,
                status: 'active'
            };
            console.log(`Using provided item data for ${providedItemName}: quantity=${providedQuantity}, threshold=${providedMinThreshold}`);
        } else {
            // Otherwise, fetch from database (with retry for timing issues)
            let retries = 3;
            let itemError: any = null;

            while (retries > 0) {
                const { data, error } = await supabase
                    .from('inventory_items')
                    .select('id, name, quantity, min_threshold, status')
                    .eq('id', inventoryItemId)
                    .maybeSingle();

                if (!error && data) {
                    item = data;
                    break;
                }

                itemError = error;
                retries--;

                if (retries > 0) {
                    // Wait a bit for database trigger to complete
                    await new Promise(resolve => setTimeout(resolve, 500));
                }
            }

            if (itemError) {
                console.error('Error fetching inventory item:', itemError);
                return {
                    success: false,
                    message: `Failed to fetch inventory item: ${itemError.message}`,
                    notificationSent: false
                };
            }

            if (!item) {
                console.error('Inventory item not found after retries:', inventoryItemId);
                return {
                    success: false,
                    message: `Inventory item not found: ${inventoryItemId}`,
                    notificationSent: false
                };
            }
        }

        // Check if quantity is at or below minimum threshold
        if (item.quantity <= item.min_threshold) {
            console.log(`Low stock detected for item ${item.name}: ${item.quantity} <= ${item.min_threshold}`);

            const result = await sendLowStockNotifications({
                inventoryItemId: item.id,
                itemName: item.name,
                currentQuantity: item.quantity,
                minThreshold: item.min_threshold,
                branchId: branchId
            });

            return {
                success: result.success,
                message: result.message,
                notificationSent: result.notificationsCreated > 0
            };
        }

        return {
            success: true,
            message: 'Stock level is above threshold',
            notificationSent: false
        };
    } catch (error: any) {
        console.error('Error in checkAndNotifyLowStock:', error);
        return {
            success: false,
            message: error.message || 'Failed to check low stock',
            notificationSent: false
        };
    }
}

