# Low Stock Notification System

Complete implementation of an Inventory Low-Stock Notification System with Chrome Web-Push Notifications.

## Overview

This system automatically sends notifications to Admin, Manager, and HR users when inventory items reach low stock levels (quantity <= minimum threshold) after an employee issues items.

## Features

- ✅ Automatic low stock detection when items are issued
- ✅ Chrome Web Push Notifications
- ✅ Database notifications stored in `notifications` table
- ✅ Real-time notification updates via Supabase subscriptions
- ✅ Notification bell UI with unread count badge
- ✅ Prevents duplicate notifications for the same stock level
- ✅ Role-based notification targeting (Admin, Manager, HR)

## Architecture

### Backend Components

1. **web-push-service.ts** - Handles Web Push subscription management and sending
2. **low-stock-notification-service.ts** - Core logic for low stock detection and notification sending
3. **API Endpoints** - RESTful endpoints for push subscriptions and notifications

### Database Components

1. **push_subscriptions** table - Stores browser push notification subscriptions
2. **notifications** table - Stores all notifications
3. **Database Functions**:
   - `get_admin_user_ids_for_notifications()` - Gets Admin/Manager/HR user IDs
   - `insert_notifications_for_users()` - Inserts notifications for multiple users
   - `get_push_subscriptions_for_admin_users()` - Gets push subscriptions for users
   - `upsert_push_subscription()` - Creates/updates push subscriptions

### Frontend Components

1. **NotificationBell.tsx** - Notification bell icon with dropdown
2. **Service Worker (sw.js)** - Handles push notifications in the browser
3. **useEmployeeIssuance.ts** - Hook updated to trigger low stock checks

## Setup Instructions

### 1. Install Dependencies

```bash
cd Backend
npm install
```

This will install `web-push` and `@types/web-push`.

### 2. Run Database Migrations

Run the migration files in order:

```bash
# Run migrations
psql -U your_user -d your_database -f migrations/20250203000001_restore_notification_functions.sql
psql -U your_user -d your_database -f migrations/20250203000002_add_low_stock_detection_function.sql
```

Or use your migration runner if you have one.

### 3. Configure Environment Variables

Add to your `.env` file:

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
VITE_BACKEND_URL=http://localhost:3001  # For frontend
```

### 4. Start Backend Server

```bash
cd Backend
npm run dev
```

The server will:
- Generate VAPID keys automatically if they don't exist
- Start on port 3001 (or PORT from env)

### 5. Frontend Setup

The frontend components are already integrated. Make sure:

1. Service worker is registered (already in `public/sw.js`)
2. `NotificationBell` component is added to `Layout.tsx` (already done)
3. Environment variable `VITE_BACKEND_URL` is set

## API Endpoints

### Push Notification Endpoints

#### GET `/api/public-vapid-key`
Get the public VAPID key for push notification subscription.

**Response:**
```json
{
  "success": true,
  "publicKey": "BObKg28Fh7EjrJFdAHcQXs-BdLW0A9e0UDEq5s2PT7U_p9hMwdzquN7IUtEaHgD3gNfWs7jwzsqofrvgLMamX30"
}
```

#### POST `/api/subscribe`
Subscribe a user to push notifications.

**Request:**
```json
{
  "userId": "uuid",
  "subscription": {
    "endpoint": "https://fcm.googleapis.com/...",
    "keys": {
      "p256dh": "base64-encoded-key",
      "auth": "base64-encoded-key"
    }
  },
  "deviceInfo": {
    "userAgent": "...",
    "platform": "..."
  }
}
```

#### POST `/api/unsubscribe`
Unsubscribe a user from push notifications.

**Request:**
```json
{
  "endpoint": "https://fcm.googleapis.com/..."
}
```

### Notification Endpoints

#### GET `/api/notifications`
Get notifications for a user.

**Query Parameters:**
- `userId` (required) - User ID
- `limit` (optional, default: 50) - Number of notifications to return
- `offset` (optional, default: 0) - Pagination offset
- `unreadOnly` (optional, default: false) - Only return unread notifications

**Response:**
```json
{
  "success": true,
  "notifications": [...],
  "unreadCount": 5
}
```

#### PATCH `/api/notifications/mark-read`
Mark a notification as read.

**Request:**
```json
{
  "notificationId": "uuid",
  "userId": "uuid"
}
```

#### PATCH `/api/notifications/mark-all-read`
Mark all notifications as read for a user.

**Request:**
```json
{
  "userId": "uuid"
}
```

### Inventory Endpoints

#### POST `/api/inventory/check-low-stock`
Manually trigger low stock check (for testing).

**Request:**
```json
{
  "inventoryItemId": "uuid",
  "branchId": "uuid" // optional
}
```

## How It Works

### 1. Inventory Issue Flow

When an employee issues inventory items:

1. Frontend creates the issue via `useEmployeeIssuance` hook
2. After successful creation, the hook checks each item for low stock
3. If `newQuantity <= minThreshold`, it calls `/api/inventory/check-low-stock`
4. Backend checks if notification was already sent for this quantity
5. If not, it:
   - Fetches Admin/Manager/HR user IDs
   - Creates notification records in database
   - Sends push notifications to subscribed users

### 2. Push Notification Flow

1. User grants notification permission
2. Service worker registers
3. Frontend subscribes to push notifications
4. Subscription is saved to database
5. When low stock is detected:
   - Backend fetches user subscriptions
   - Sends push notification via web-push
   - Service worker receives and displays notification
   - Frontend updates notification bell count

### 3. Notification Bell

- Shows unread count badge
- Dropdown lists all notifications
- Real-time updates via Supabase subscriptions
- Click to mark as read and navigate to action URL
- "Mark all read" functionality

## Preventing Duplicate Notifications

The system prevents duplicate notifications by:

1. Checking if a notification was sent in the last 24 hours
2. Comparing the inventory item ID and quantity
3. Only sending if the quantity has changed or no recent notification exists

## Database Schema

### push_subscriptions
- `id` (UUID)
- `user_id` (UUID) - References auth.users
- `endpoint` (TEXT) - Unique push subscription endpoint
- `p256dh` (TEXT) - Public key
- `auth` (TEXT) - Auth secret
- `device_info` (JSONB) - Optional device information
- `created_at`, `updated_at`

### notifications
- `id` (UUID)
- `user_id` (UUID) - References auth.users
- `title` (VARCHAR)
- `message` (TEXT)
- `type` (VARCHAR) - 'inventory' for low stock
- `action_url` (VARCHAR) - URL to navigate when clicked
- `data` (JSONB) - Additional data including inventory_item_id, quantity, etc.
- `reference_type` (VARCHAR) - 'low_stock' for low stock notifications
- `is_read` (BOOLEAN)
- `read_at` (TIMESTAMPTZ)
- `branch_id` (UUID)
- `created_at`, `updated_at`

## Testing

### Test Low Stock Notification

1. Create an inventory item with `min_threshold = 10` and `quantity = 15`
2. Issue 6 items to an employee (quantity becomes 9, which is <= 10)
3. Check that:
   - Notification appears in database for Admin/Manager/HR users
   - Push notification is sent (if users are subscribed)
   - Notification bell shows the notification

### Test Push Notifications

1. Open the app in Chrome
2. Grant notification permission when prompted
3. Check browser console for subscription success
4. Trigger a low stock event
5. Verify push notification appears

## Troubleshooting

### Push Notifications Not Working

1. **Check browser support**: Only Chrome, Edge, and Firefox support web push
2. **Check HTTPS**: Push notifications require HTTPS (except localhost)
3. **Check service worker**: Verify `sw.js` is registered
4. **Check VAPID keys**: Ensure keys are generated and valid
5. **Check subscription**: Verify subscription is saved in database

### Notifications Not Appearing

1. **Check user roles**: Ensure users have Admin, Manager, or HR roles
2. **Check database functions**: Verify migrations ran successfully
3. **Check backend logs**: Look for errors in console
4. **Check RLS policies**: Ensure functions have SECURITY DEFINER

### Duplicate Notifications

1. Check the `hasNotificationBeenSent` function logic
2. Verify the 24-hour window is appropriate
3. Check if quantity is being compared correctly

## Security Considerations

1. **VAPID Keys**: Keep private key secure, never expose it
2. **RLS Policies**: Database functions use SECURITY DEFINER to bypass RLS
3. **User Validation**: Always validate userId in API endpoints
4. **HTTPS**: Required for production push notifications

## Future Enhancements

- [ ] Email notifications as fallback
- [ ] Notification preferences per user
- [ ] Notification grouping
- [ ] Sound customization
- [ ] Notification history/archive
- [ ] Bulk notification actions

## Support

For issues or questions, check:
- Backend logs: `Backend/index.ts` console output
- Browser console: Frontend errors
- Database logs: Supabase logs
- Network tab: API request/response details

