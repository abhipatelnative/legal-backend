import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';
import { sendPushNotificationsToUsers } from "./web-push-service";

dotenv.config();

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

interface ExpenseNotificationData {
    expenseId: string;
    expenseNumber: string;
    amount: number;
    description: string;
    categoryName?: string;
    status: 'submitted' | 'approved' | 'rejected';
    submittedBy?: string;
    approvedBy?: string;
    rejectedBy?: string;
    rejectionReason?: string;
    branchId?: string | null;
}

/**
 * Send expense notifications to HR Manager, Manager, and Admin users
 */
export async function sendExpenseNotifications(
    notificationData: ExpenseNotificationData
): Promise<{ success: boolean; message: string; notificationsCreated: number; pushSent: number }> {
    try {
        const {
            expenseId,
            expenseNumber,
            amount,
            description,
            categoryName,
            status,
            submittedBy,
            approvedBy,
            rejectedBy,
            rejectionReason,
            branchId
        } = notificationData;

        // Get Admin, Manager, and HR user IDs
        const { data: adminUserIds, error: userError } = await supabase.rpc(
            'get_admin_user_ids_for_notifications'
        );

        if (userError) {
            console.error('Error fetching admin user IDs:', userError);
            return {
                success: false,
                message: `Failed to fetch admin user IDs: ${userError.message}`,
                notificationsCreated: 0,
                pushSent: 0
            };
        }

        if (!adminUserIds || adminUserIds.length === 0) {
            console.log('⚠️  No admin/manager/HR users found - notifications will not be sent');
            return {
                success: true,
                message: 'No admin/manager/HR users found',
                notificationsCreated: 0,
                pushSent: 0
            };
        }

        // Log which users are eligible to receive notifications
        console.log(`\n📋 Found ${adminUserIds.length} eligible user(s) for expense notifications:`);
        const userIds = adminUserIds.map((row: any) => row.user_id);
        console.log(`   User IDs: ${userIds.join(', ')}`);

        // Get company logo URL
        let logoUrl = '/logo.png'; // fallback
        try {
            const { data: companySettings } = await supabase
                .from('company_settings')
                .select('logo_url')
                .single();

            if (companySettings?.logo_url) {
                logoUrl = companySettings.logo_url;
            }
        } catch (logoError) {
            console.log('Could not fetch company logo, using fallback');
        }

        // Try to get user details (email/name) for better logging
        try {
            const { data: userDetails } = await supabase
                .from('user_profiles')
                .select('id, first_name, last_name')
                .in('id', userIds);

            if (userDetails && userDetails.length > 0) {
                console.log(`\n👥 Eligible users details:`);
                userDetails.forEach((user: any) => {
                    const fullName = `${user.first_name || ''} ${user.last_name || ''}`.trim();
                    console.log(`   - ${fullName || user.id}`);
                });
            }
        } catch (detailError) {
            console.log('   (Could not fetch user details for logging)');
        }

        // Prepare notification message and title based on status
        let title = '';
        let message = '';
        let actionUrl = '';
        let referenceType = '';

        switch (status) {
            case 'submitted':
                title = 'New Expense Submitted';
                message = `💰 New expense ${expenseNumber} submitted: ${formatCurrency(amount)} - ${description.substring(0, 50)}${description.length > 50 ? '...' : ''}`;
                actionUrl = `/expenses?expense=${expenseId}`;
                referenceType = 'expense_submitted';
                break;
            case 'approved':
                title = 'Expense Approved';
                message = `✅ Expense ${expenseNumber} has been approved: ${formatCurrency(amount)} - ${description.substring(0, 50)}${description.length > 50 ? '...' : ''}`;
                actionUrl = `/expenses?expense=${expenseId}`;
                referenceType = 'expense_approved';
                break;
            case 'rejected':
                title = 'Expense Rejected';
                message = `❌ Expense ${expenseNumber} has been rejected: ${formatCurrency(amount)} - ${description.substring(0, 50)}${description.length > 50 ? '...' : ''}`;
                if (rejectionReason) {
                    message += ` Reason: ${rejectionReason.substring(0, 30)}${rejectionReason.length > 30 ? '...' : ''}`;
                }
                actionUrl = `/expenses?expense=${expenseId}`;
                referenceType = 'expense_rejected';
                break;
        }

        // Prepare notification data for database
        const notificationsToInsert = adminUserIds.map((row: any) => ({
            user_id: row.user_id,
            title: title,
            message: message,
            type: 'expense',
            action_url: actionUrl,
            data: {
                expense_id: expenseId,
                expense_number: expenseNumber,
                amount: amount,
                description: description,
                category_name: categoryName,
                status: status,
                submitted_by: submittedBy,
                approved_by: approvedBy,
                rejected_by: rejectedBy,
                rejection_reason: rejectionReason,
                branch_id: branchId,
                reference_type: referenceType
            }
        }));

        // Insert notifications into database
        const { data: insertedNotifications, error: insertError } = await supabase.rpc(
            'insert_notifications_for_users',
            {
                p_notifications: notificationsToInsert
            }
        );

        if (insertError) {
            console.error('Error inserting notifications:', insertError);
            return {
                success: false,
                message: `Failed to insert notifications: ${insertError.message}`,
                notificationsCreated: 0,
                pushSent: 0
            };
        }

        const notificationsCreated = insertedNotifications?.length || 0;
        console.log(`\n✅ Created ${notificationsCreated} notification(s) in database for expense ${status}`);

        if (notificationsCreated === 0) {
            console.log(`   ⚠️  WARNING: No notifications were created in database!`);
        } else if (notificationsCreated < userIds.length) {
            console.log(`   ⚠️  WARNING: Expected ${userIds.length} notifications but only ${notificationsCreated} were created`);
        }

        // Send push notifications
        console.log(`\n📲 Sending push notifications to ${userIds.length} user(s)...`);
        const pushResult = await sendPushNotificationsToUsers(userIds, {
            title: title,
            message: message,
            url: actionUrl,
            icon: logoUrl,
            badge: logoUrl
        });

        console.log(`\n📊 Push Notification Summary:`);
        console.log(`   ✅ Successfully sent: ${pushResult.success}`);
        console.log(`   ❌ Failed: ${pushResult.failed}`);

        if (pushResult.errors && pushResult.errors.length > 0) {
            console.log(`\n   ❌ Push notification errors:`);
            pushResult.errors.forEach((error, index) => {
                console.log(`      ${index + 1}. ${error}`);
            });
        }

        if (pushResult.success === 0 && userIds.length > 0) {
            console.log(`\n   ⚠️  WARNING: No push notifications were sent!`);
            console.log(`   Possible reasons:`);
            console.log(`   - Users have not subscribed to push notifications`);
            console.log(`   - Push subscriptions are invalid or expired`);
            console.log(`   - VAPID keys are not configured correctly`);
        }

        return {
            success: true,
            message: `Notifications created and push notifications sent`,
            notificationsCreated: notificationsCreated,
            pushSent: pushResult.success
        };
    } catch (error: any) {
        console.error('Error in sendExpenseNotifications:', error);
        return {
            success: false,
            message: error.message || 'Failed to send expense notifications',
            notificationsCreated: 0,
            pushSent: 0
        };
    }
}

/**
 * Send notification when an expense is submitted/added
 */
export async function notifyExpenseSubmitted(
    expenseId: string,
    expenseNumber: string,
    amount: number,
    description: string,
    categoryName?: string,
    submittedBy?: string,
    branchId?: string | null
): Promise<{ success: boolean; message: string; notificationSent: boolean }> {
    try {
        const result = await sendExpenseNotifications({
            expenseId,
            expenseNumber,
            amount,
            description,
            categoryName,
            status: 'submitted',
            submittedBy,
            branchId
        });

        return {
            success: result.success,
            message: result.message,
            notificationSent: result.notificationsCreated > 0
        };
    } catch (error: any) {
        console.error('Error in notifyExpenseSubmitted:', error);
        return {
            success: false,
            message: error.message || 'Failed to notify expense submission',
            notificationSent: false
        };
    }
}

/**
 * Send notification when an expense is approved
 */
export async function notifyExpenseApproved(
    expenseId: string,
    expenseNumber: string,
    amount: number,
    description: string,
    categoryName?: string,
    approvedBy?: string,
    branchId?: string | null
): Promise<{ success: boolean; message: string; notificationSent: boolean }> {
    try {
        const result = await sendExpenseNotifications({
            expenseId,
            expenseNumber,
            amount,
            description,
            categoryName,
            status: 'approved',
            approvedBy,
            branchId
        });

        return {
            success: result.success,
            message: result.message,
            notificationSent: result.notificationsCreated > 0
        };
    } catch (error: any) {
        console.error('Error in notifyExpenseApproved:', error);
        return {
            success: false,
            message: error.message || 'Failed to notify expense approval',
            notificationSent: false
        };
    }
}

/**
 * Send notification when an expense is rejected
 */
export async function notifyExpenseRejected(
    expenseId: string,
    expenseNumber: string,
    amount: number,
    description: string,
    rejectionReason?: string,
    categoryName?: string,
    rejectedBy?: string,
    branchId?: string | null
): Promise<{ success: boolean; message: string; notificationSent: boolean }> {
    try {
        const result = await sendExpenseNotifications({
            expenseId,
            expenseNumber,
            amount,
            description,
            categoryName,
            status: 'rejected',
            rejectedBy,
            rejectionReason,
            branchId
        });

        return {
            success: result.success,
            message: result.message,
            notificationSent: result.notificationsCreated > 0
        };
    } catch (error: any) {
        console.error('Error in notifyExpenseRejected:', error);
        return {
            success: false,
            message: error.message || 'Failed to notify expense rejection',
            notificationSent: false
        };
    }
}

/**
 * Helper function to format currency
 */
function formatCurrency(amount: number): string {
    return new Intl.NumberFormat('en-IN', {
        style: 'currency',
        currency: 'INR',
        maximumFractionDigits: 0
    }).format(amount);
}

