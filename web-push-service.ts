import webpush from "web-push";
import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';

dotenv.config();

// Supabase client


const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// VAPID keys file path
const VAPID_KEYS_PATH = path.join(__dirname, 'vapid-keys.json');

interface VapidKeys {
    publicKey: string;
    privateKey: string;
}

interface PushSubscriptionRow {
    id: string;
    user_id: string;
    endpoint: string;
    p256dh: string;
    auth: string;
    created_at: string;
}

// Initialize VAPID keys
function initializeVapidKeys(): VapidKeys {
    let keys: VapidKeys;

    // Try to load existing keys
    if (fs.existsSync(VAPID_KEYS_PATH)) {
        try {
            const keysData = fs.readFileSync(VAPID_KEYS_PATH, 'utf-8');
            keys = JSON.parse(keysData);
            console.log('Loaded existing VAPID keys');
        } catch (error) {
            console.error('Error reading VAPID keys file, generating new keys...', error);
            keys = generateVapidKeys();
        }
    } else {
        console.log('VAPID keys file not found, generating new keys...');
        keys = generateVapidKeys();
    }

    // Set VAPID details for web-push
    webpush.setVapidDetails(
        'mailto:admin@parikhassociates.in',
        keys.publicKey,
        keys.privateKey
    );

    return keys;
}

// Generate new VAPID keys
function generateVapidKeys(): VapidKeys {
    const vapidKeys = webpush.generateVAPIDKeys();
    const keys = {
        publicKey: vapidKeys.publicKey,
        privateKey: vapidKeys.privateKey
    };

    // Save keys to file
    try {
        fs.writeFileSync(VAPID_KEYS_PATH, JSON.stringify(keys, null, 2));
        console.log('VAPID keys generated and saved to', VAPID_KEYS_PATH);
    } catch (error) {
        console.error('Error saving VAPID keys:', error);
    }

    return keys;
}

// Initialize on module load
const vapidKeys = initializeVapidKeys();

// Get public VAPID key
export function getPublicVapidKey(): string {
    return vapidKeys.publicKey;
}

// Subscribe a user to push notifications
export async function subscribeUser(
    userId: string,
    subscription: webpush.PushSubscription,
    deviceInfo?: any
): Promise<{ success: boolean; message: string; id?: string }> {
    try {
        // Validate userId is provided
        if (!userId) {
            return {
                success: false,
                message: 'User ID is required'
            };
        }

        // Call the database function to upsert subscription
        // The database function will validate that user_id exists in auth.users
        const { data, error } = await supabase.rpc('upsert_push_subscription', {
            p_endpoint: subscription.endpoint,
            p_p256dh: (subscription.keys as any).p256dh,
            p_auth: (subscription.keys as any).auth,
            p_user_id: userId,
            p_device_info: deviceInfo || null
        });

        if (error) {
            console.error('Error subscribing user:', error);
            // Provide more specific error message for foreign key violations and user validation errors
            if (error.message?.includes('foreign key constraint') ||
                error.message?.includes('does not exist in auth.users') ||
                error.message?.includes('violates foreign key constraint')) {
                return {
                    success: false,
                    message: `User ID ${userId} is invalid or does not exist. The user may have been deleted. Please sign in again.`
                };
            }
            return {
                success: false,
                message: error.message || 'Failed to subscribe user'
            };
        }

        return {
            success: true,
            message: 'User subscribed successfully',
            id: data
        };
    } catch (error: any) {
        console.error('Error in subscribeUser:', error);
        return {
            success: false,
            message: error.message || 'Failed to subscribe user'
        };
    }
}

// Unsubscribe a user from push notifications
export async function unsubscribeUser(endpoint: string): Promise<{ success: boolean; message: string }> {
    try {
        const { error } = await supabase
            .from('push_subscriptions')
            .delete()
            .eq('endpoint', endpoint);

        if (error) {
            console.error('Error unsubscribing user:', error);
            return {
                success: false,
                message: error.message || 'Failed to unsubscribe user'
            };
        }

        return {
            success: true,
            message: 'User unsubscribed successfully'
        };
    } catch (error: any) {
        console.error('Error in unsubscribeUser:', error);
        return {
            success: false,
            message: error.message || 'Failed to unsubscribe user'
        };
    }
}

// Send push notification to a single subscription
export async function sendPushNotification(
    subscription: webpush.PushSubscription,
    payload: { title: string; message: string; url?: string; icon?: string; badge?: string }
): Promise<{ success: boolean; message: string }> {
    try {
        const notificationPayload = JSON.stringify({
            title: payload.title,
            message: payload.message,
            url: payload.url || '/',
            icon: payload.icon || '/logo.png',
            badge: payload.badge || '/logo.png'
        });

        await webpush.sendNotification(subscription, notificationPayload);

        return {
            success: true,
            message: 'Push notification sent successfully'
        };
    } catch (error: any) {
        const token = subscription.endpoint.split('/').pop() ?? subscription.endpoint;
        const shortEndpoint = token.substring(0, 24) + '...';

        // If subscription is invalid (expired/unsubscribed), remove it
        if (error.statusCode === 410 || error.statusCode === 404) {
            try {
                await supabase
                    .from('push_subscriptions')
                    .delete()
                    .eq('endpoint', subscription.endpoint);
                console.log(`[Push] Sub expired/gone (${error.statusCode}), removed — token: ...${shortEndpoint}`);
            } catch (deleteError: any) {
                console.warn(`[Push] Failed to remove stale sub: ${deleteError?.message}`);
            }
        } else if (error.statusCode === 403) {
            console.log(`[Push] VAPID mismatch (403), skipped — token: ...${shortEndpoint}`);
        } else {
            console.warn(`[Push] Send failed (${error.statusCode ?? 'unknown'}): ${(error.body as string)?.trim() || error.message}`);
        }

        return {
            success: false,
            message: error.message || 'Failed to send push notification'
        };
    }
}

// Send push notifications to multiple users
export async function sendPushNotificationsToUsers(
    userIds: string[],
    payload: { title: string; message: string; url?: string; icon?: string; badge?: string }
): Promise<{ success: number; failed: number; errors: string[] }> {
    try {
        // Get push subscriptions for the users
        const { data: subscriptions, error } = await supabase.rpc('get_push_subscriptions_for_admin_users', {
            p_admin_user_ids: userIds
        });

        if (error) {
            console.error('Error fetching push subscriptions:', error);
            return {
                success: 0,
                failed: userIds.length,
                errors: [error.message || 'Failed to fetch push subscriptions']
            };
        }

        if (!subscriptions || subscriptions.length === 0) {
            console.log(`   ⚠️  No push subscriptions found for ${userIds.length} user(s)`);
            console.log(`   💡 Users need to allow push notifications in their browser to receive push notifications`);

            // Show which users don't have subscriptions
            const subscribedUserIds = new Set<string>();
            const usersWithoutSubscriptions = userIds.filter(userId => !subscribedUserIds.has(userId));

            if (usersWithoutSubscriptions.length > 0) {
                console.log(`   📋 Users without push subscriptions: ${usersWithoutSubscriptions.join(', ')}`);
            }

            return {
                success: 0,
                failed: 0,
                errors: []
            };
        }

        // Group subscriptions by user_id
        const subscriptionsByUser = new Map<string, PushSubscriptionRow[]>();
        subscriptions.forEach((sub: PushSubscriptionRow) => {
            if (!subscriptionsByUser.has(sub.user_id)) {
                subscriptionsByUser.set(sub.user_id, []);
            }
            subscriptionsByUser.get(sub.user_id)!.push(sub);
        });

        console.log(`   📱 Found ${subscriptions.length} push subscription(s) for ${subscriptionsByUser.size} user(s)`);

        // Check which users have subscriptions and which don't
        const usersWithSubscriptions = Array.from(subscriptionsByUser.keys());
        const usersWithoutSubscriptions = userIds.filter(userId => !usersWithSubscriptions.includes(userId));

        if (usersWithoutSubscriptions.length > 0) {
            console.log(`   ⚠️  ${usersWithoutSubscriptions.length} user(s) without push subscriptions: ${usersWithoutSubscriptions.join(', ')}`);
        }

        let successCount = 0;
        let failedCount = 0;
        const errors: string[] = [];
        const successUsers: string[] = [];
        const failedUsers: string[] = [];

        // Send notification to each subscription
        for (const sub of subscriptions as PushSubscriptionRow[]) {
            try {
                const subscription: webpush.PushSubscription = {
                    endpoint: sub.endpoint,
                    keys: {
                        p256dh: sub.p256dh,
                        auth: sub.auth
                    }
                };

                const result = await sendPushNotification(subscription, payload);
                if (result.success) {
                    successCount++;
                    if (!successUsers.includes(sub.user_id)) {
                        successUsers.push(sub.user_id);
                    }
                } else {
                    failedCount++;
                    if (!failedUsers.includes(sub.user_id)) {
                        failedUsers.push(sub.user_id);
                    }
                    errors.push(`User ${sub.user_id}: ${result.message}`);
                }
            } catch (error: any) {
                failedCount++;
                if (!failedUsers.includes(sub.user_id)) {
                    failedUsers.push(sub.user_id);
                }
                errors.push(`User ${sub.user_id}: ${error.message}`);
            }
        }

        // Log summary
        if (successUsers.length > 0) {
            console.log(`   ✅ Push sent successfully to ${successUsers.length} user(s): ${successUsers.join(', ')}`);
        }
        if (failedUsers.length > 0) {
            console.log(`   ❌ Push failed for ${failedUsers.length} user(s): ${failedUsers.join(', ')}`);
        }

        return {
            success: successCount,
            failed: failedCount,
            errors
        };
    } catch (error: any) {
        console.error('Error in sendPushNotificationsToUsers:', error);
        return {
            success: 0,
            failed: userIds.length,
            errors: [error.message || 'Failed to send push notifications']
        };
    }
}

// Get all push subscriptions for a user
export async function getUserSubscriptions(userId: string): Promise<webpush.PushSubscription[]> {
    try {
        const { data, error } = await supabase
            .from('push_subscriptions')
            .select('endpoint, p256dh, auth')
            .eq('user_id', userId);

        if (error) {
            console.error('Error fetching user subscriptions:', error);
            return [];
        }

        if (!data || data.length === 0) {
            return [];
        }

        return data.map(sub => ({
            endpoint: sub.endpoint,
            keys: {
                p256dh: sub.p256dh,
                auth: sub.auth
            }
        }));
    } catch (error) {
        console.error('Error in getUserSubscriptions:', error);
        return [];
    }
}

