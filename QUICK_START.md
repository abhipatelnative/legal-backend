# Quick Start Guide - Low Stock Notification System

## Prerequisites

- Node.js installed
- PostgreSQL database with Supabase
- Backend server running
- Frontend application running

## Step 1: Install Dependencies

```bash
cd Backend
npm install
```

This installs `web-push` and `@types/web-push`.

## Step 2: Run Database Migrations

Execute these SQL files in order:

1. `migrations/20250203000001_restore_notification_functions.sql`
2. `migrations/20250203000002_add_low_stock_detection_function.sql`

You can run them via:
- Supabase SQL Editor
- psql command line
- Your migration tool

## Step 3: Configure Environment

Create/update `.env` in Backend folder:

```env
SUPABASE_URL=https://wcjcvevbeegkgomjkxbk.supabase.co
SUPABASE_ANON_KEY=your-anon-key-here
PORT=3001
```

For frontend, add to `.env`:

```env
VITE_BACKEND_URL=http://localhost:3001
```

## Step 4: Start Backend

```bash
cd Backend
npm run dev
```

The server will:
- Generate VAPID keys automatically (saved to `vapid-keys.json`)
- Start on port 3001
- Be ready to handle push notification subscriptions

## Step 5: Test the System

### Test 1: Subscribe to Push Notifications

1. Open your frontend app in Chrome
2. Log in as an Admin/Manager/HR user
3. The notification bell should appear in the header
4. Click it - you'll be prompted for notification permission
5. Grant permission
6. Check browser console for subscription success

### Test 2: Trigger Low Stock Notification

1. Go to Inventory → Employee Issuance
2. Find an item with quantity > min_threshold
3. Issue enough items so that: `new_quantity <= min_threshold`
4. Check:
   - Notification appears in the bell dropdown
   - Push notification appears (if browser is open)
   - Database has notification records for Admin/Manager/HR users

### Test 3: Verify API Endpoints

```bash
# Get VAPID key
curl http://localhost:3001/api/public-vapid-key

# Get notifications (replace USER_ID)
curl "http://localhost:3001/api/notifications?userId=USER_ID"
```

## Verification Checklist

- [ ] Backend server starts without errors
- [ ] VAPID keys file exists (`Backend/vapid-keys.json`)
- [ ] Database functions are created (check via SQL editor)
- [ ] Notification bell appears in header
- [ ] Push subscription works (check browser console)
- [ ] Low stock notification triggers correctly
- [ ] Notifications appear in bell dropdown
- [ ] Push notifications appear in browser

## Common Issues

### "VAPID key not found"
- The keys are auto-generated on first run
- Check `Backend/vapid-keys.json` exists

### "Permission denied" for push notifications
- User must grant permission in browser
- Only works on HTTPS (or localhost)

### "No notifications appearing"
- Check user has Admin/Manager/HR role
- Verify database functions exist
- Check backend logs for errors
- Verify inventory item quantity <= min_threshold

### "Push notifications not working"
- Ensure service worker is registered (`sw.js` exists)
- Check browser supports web push (Chrome/Edge/Firefox)
- Verify subscription is saved in `push_subscriptions` table
- Check backend logs for push errors

## Next Steps

1. Test with multiple users
2. Verify notifications are not duplicated
3. Test mark as read functionality
4. Test navigation from notifications
5. Configure production VAPID keys (keep private key secure!)

## Production Deployment

1. **Set environment variables** in production
2. **Use HTTPS** (required for push notifications)
3. **Secure VAPID keys** - never commit private key
4. **Monitor logs** for push notification failures
5. **Set up error alerts** for notification failures

## Support

See `LOW_STOCK_NOTIFICATION_SYSTEM.md` for detailed documentation.

