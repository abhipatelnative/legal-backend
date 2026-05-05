
import { createClient } from "@supabase/supabase-js";
import dayjs from "dayjs";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';
import { sendPushNotificationsToUsers } from "./web-push-service";
// import { sendEventNotificationEmail } from "./email-service"; // Will need adaptation for generic notifications

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export class ScheduledNotificationService {
    private isRunning: boolean = false;
    private checkInterval: NodeJS.Timeout | null = null;
    private readonly BATCH_SIZE = 50;

    constructor() {
        // Bind methods
        this.processDueNotifications = this.processDueNotifications.bind(this);
    }

    /**
     * Start the scheduler to check for due notifications every minute
     */
    public startScheduler(intervalMs: number = 60000) {
        if (this.isRunning) {
            console.log("ScheduledNotificationService is already running.");
            return;
        }

        console.log("Starting ScheduledNotificationService...");
        this.isRunning = true;

        // Run immediately on start
        this.processDueNotifications();

        this.checkInterval = setInterval(this.processDueNotifications, intervalMs);
    }

    /**
     * Stop the scheduler
     */
    public stopScheduler() {
        if (this.checkInterval) {
            clearInterval(this.checkInterval);
            this.checkInterval = null;
        }
        this.isRunning = false;
        console.log("ScheduledNotificationService stopped.");
    }

    /**
     * Process notifications that are due
     */
    private async processDueNotifications() {
        try {
            const now = new Date().toISOString();
            console.log(`Checking for scheduled notifications due before ${now}...`);

            // 1. Fetch pending notifications due now or in the past
            const { data: notifications, error } = await supabase
                .from('notifications')
                .select('*')
                .eq('status', 'pending')
                .lte('scheduled_for', now)
                .limit(this.BATCH_SIZE);

            if (error) {
                console.error("Error fetching scheduled notifications:", error);
                return;
            }

            if (!notifications || notifications.length === 0) {
                // console.log("No due notifications found."); 
                return;
            }

            console.log(`Found ${notifications.length} due notifications. Processing...`);

            // 2. Process each notification
            for (const notification of notifications) {
                await this.processNotification(notification);
            }

        } catch (error) {
            console.error("Error in processDueNotifications:", error);
        }
    }

    /**
     * Process a single notification
     */
    private async processNotification(notification: any) {
        try {
            const { id, user_id, title, message, action_url, type, channels } = notification;
            const channelConfig = typeof channels === 'string' ? JSON.parse(channels) : (channels || {});

            // Default to in-app only if channels not specified (but since it's in DB, in-app is implicitly done)
            // We mainly care about Push and Email here.

            const results: string[] = [];
            let isSuccess = true;

            // --- SEND PUSH ---
            if (channelConfig.push) {
                try {
                    // We need to pass an array of userIds
                    const pushResult = await sendPushNotificationsToUsers([user_id], {
                        title,
                        message,
                        url: action_url || '/',
                        // icon, badge
                    });

                    if (pushResult.success > 0) {
                        results.push("Push: Sent");
                    } else if (pushResult.failed > 0) {
                        results.push(`Push: Failed (${pushResult.errors.join(', ')})`);
                        // We don't mark the whole notification as failed if just push failed, 
                        // as it exists in-app.
                    } else {
                        results.push("Push: No subscription");
                    }
                } catch (e: any) {
                    console.error(`Failed to send push for notification ${id}:`, e);
                    results.push(`Push: Error (${e.message})`);
                    // isSuccess = false; // Optional: mark partial failure?
                }
            }

            // --- SEND EMAIL ---
            if (channelConfig.email) {
                // TODO: Implement generic email sending logic reusing email-service
                // For now just log
                results.push("Email: Skipped (Not implemented)");
            }

            // --- UPDATE STATUS ---
            // Mark as 'sent' so it shows up in the user's list (if we filter pending)
            // and so we don't process it again.
            const { error: updateError } = await supabase
                .from('notifications')
                .update({
                    status: 'sent',
                    // Appending to data or a log column could be useful
                })
                .eq('id', id);

            if (updateError) {
                console.error(`Failed to update status for notification ${id}:`, updateError);
            } else {
                console.log(`Successfully processed notification ${id}. Results: ${results.join(', ')}`);
            }

        } catch (error) {
            console.error(`Critical error processing notification ${notification.id}:`, error);

            // Mark as failed to avoid infinite loop
            await supabase
                .from('notifications')
                .update({ status: 'failed' })
                .eq('id', notification.id);
        }
    }
}

// Export a singleton instance
export const scheduledNotificationService = new ScheduledNotificationService();
