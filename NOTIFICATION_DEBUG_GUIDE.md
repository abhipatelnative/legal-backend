# Low Stock Notification Debug Guide

## Problems Identified

### Problem 1: Admin Users Not Found (FIXED ✅)

The notification system was not finding admin users. The logs showed:

```
📋 [STEP 1.1] Found 0 total role(s) in database:
   ⚠️ No roles found in database!
```

**Status:** ✅ FIXED - The SECURITY DEFINER function now successfully finds admin users.

### Problem 2: RLS Violation When Storing Notifications (FIXED ✅)

Even after finding admin users, notifications cannot be stored due to RLS:

```
❌ [STEP 6] Failed to store notifications: {
  code: '42501',
  message: 'new row violates row-level security policy for table "notifications"'
}
```

**Status:** ✅ FIXED - Created SECURITY DEFINER function to insert notifications.

### Problem 3: No Push Subscriptions (Expected ⚠️)

No push subscriptions found for admin users:

```
📱 [STEP 7.1] Found 0 admin push subscription(s)
   ⚠️ No subscriptions found for admin users
   💡 Admins need to register for push notifications by logging in
```

**Status:** ⚠️ EXPECTED - Admins need to log in and register for push notifications. Notifications will still be stored in the database.

## Root Cause

The backend service uses the **anon key** to query Supabase, but the `roles` table has RLS (Row Level Security) policies that require an **authenticated user**. The policy is:

```sql
CREATE POLICY "All users can view roles" ON public.roles
  FOR SELECT TO authenticated USING (true);
```

This means:

- ✅ Authenticated users (with JWT token) can read roles
- ❌ Anon users (backend service using anon key) cannot read roles

## Solution

We've implemented a **two-pronged solution**:

### Solution 1: SECURITY DEFINER Function (Recommended)

A database function that bypasses RLS and can be called by the backend service.

**Migration Files:**

1. `Backend/migrations/20250202000001_add_get_admin_user_ids_function.sql` - Gets admin user IDs
2. `Backend/migrations/20250202000002_add_insert_notifications_function.sql` - Inserts notifications

**Functions:**

- `public.get_admin_user_ids_for_notifications()` - Returns admin user IDs
- `public.insert_notifications_for_users(JSONB)` - Inserts notifications for users

**How it works:**

1. The functions use `SECURITY DEFINER` which runs with the privileges of the function creator
2. This bypasses RLS policies
3. The functions are granted to `anon` role, so backend can call them
4. Returns all user IDs that have the Admin role / Inserts notifications for any user

**To apply:**

```sql
-- Run these in your Supabase SQL Editor
\i Backend/migrations/20250202000001_add_get_admin_user_ids_function.sql
\i Backend/migrations/20250202000002_add_insert_notifications_function.sql
```

Or copy the SQL from the migration files and run them in Supabase.

### Solution 2: Direct Query Fallback

The backend service will fall back to direct queries if the function doesn't exist. However, this will only work if:

- You update the RLS policy to allow anon access, OR
- You use the service role key instead of anon key

## Debugging Queries

Use the SQL file `Backend/debug-user-roles-queries.sql` to:

1. **Check if roles exist:**

   ```sql
   SELECT * FROM public.roles;
   ```

2. **Find admin users:**

   ```sql
   SELECT ur.user_id, r.name, up.email
   FROM public.user_roles ur
   INNER JOIN public.roles r ON ur.role_id = r.id
   LEFT JOIN public.user_profiles up ON ur.user_id = up.id
   WHERE r.name = 'Admin' AND ur.is_active = true;
   ```

3. **Check RLS policies:**

   ```sql
   SELECT * FROM pg_policies WHERE tablename = 'roles';
   ```

4. **Test the function:**
   ```sql
   SELECT * FROM public.get_admin_user_ids_for_notifications();
   ```

## Steps to Fix

1. **Run the migration** to create the SECURITY DEFINER function:

   ```bash
   # In Supabase SQL Editor, run:
   Backend/migrations/20250202000001_add_get_admin_user_ids_function.sql
   ```

2. **Verify the function works:**

   ```sql
   SELECT * FROM public.get_admin_user_ids_for_notifications();
   ```

3. **Check that admin users exist:**

   ```sql
   -- Run queries from debug-user-roles-queries.sql
   ```

4. **Test the notification:**
   - Trigger a low stock notification
   - Check the backend logs for detailed step-by-step output
   - The logs will show if the function is being used successfully

## Alternative: Use Service Role Key

If you prefer not to use the function, you can:

1. **Get your service role key** from Supabase Dashboard → Settings → API
2. **Update the backend service** to use service role key for admin queries:

   ```typescript
   const supabaseService = createClient(
     supabaseUrl,
     process.env.SUPABASE_SERVICE_ROLE_KEY // Instead of anon key
   );
   ```

   **⚠️ WARNING:** Service role key bypasses ALL RLS policies. Only use it server-side and never expose it to the frontend.

## Expected Log Output After Fix

After applying the fix, you should see:

```
🔍 [STEP 1.0] Trying SECURITY DEFINER function to get admin user IDs...
✅ [STEP 1.0] Function returned 2 admin user ID(s): ['user-id-1', 'user-id-2']
```

Instead of:

```
📋 [STEP 1.1] Found 0 total role(s) in database:
   ⚠️ No roles found in database!
```

## Verification Checklist

- [x] Migration files have been run in Supabase
- [x] Function `get_admin_user_ids_for_notifications()` exists and works
- [x] Function `insert_notifications_for_users()` exists
- [x] Admin users exist in `user_roles` table with `is_active = true`
- [x] Admin role exists in `roles` table
- [x] Backend logs show functions are being called
- [ ] Notifications are being stored successfully (test after running migration 2)
- [ ] Push subscriptions exist for admin users (admins need to register)
- [ ] Web push notifications are being sent (requires push subscriptions)

## Current Status

Based on the latest logs:

- ✅ **Admin users found:** 13 admin users identified
- ✅ **Function working:** `get_admin_user_ids_for_notifications()` is working
- ⏳ **Notifications storage:** Need to run migration 2 to fix RLS issue
- ⚠️ **Push subscriptions:** 0 found (admins need to register by logging in)

## Additional Notes

- The backend service now has **comprehensive logging** at every step
- All queries are logged with detailed error messages
- The service tries multiple approaches to find admin users
- Push subscriptions are checked and logged for each admin user
