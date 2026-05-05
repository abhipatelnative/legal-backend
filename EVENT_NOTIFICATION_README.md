# Event Notification System

This system automatically sends email notifications to employees about upcoming company events.

## Features

- **Configurable Notification Timing**: Set how many days before an event to send notifications (default: 7 days)
- **Recurring Event Support**: Handles recurring events without creating duplicate entries
- **Branch-Specific Events**: Only notifies employees from the relevant branch (if event is branch-specific)
- **Duplicate Prevention**: Tracks sent notifications to prevent duplicate emails
- **Email Logging**: Logs all sent notifications for audit purposes

## Setup

### 1. Database Migration

Run the migration file to add the necessary columns and tables:

```sql
-- Backend/migrations/20250115000000_add_event_notification_settings.sql
-- Frontend/supabase/migrations/20250115000000_add_event_notification_settings.sql
```

This migration:
- Adds `days_before_event` column to `smtp_settings` table
- Creates `event_notification_log` table to track sent notifications

### 2. Configure SMTP Settings

1. Go to Settings → SMTP Settings in the frontend
2. Configure your SMTP server details:
   - Host (e.g., smtp.gmail.com)
   - Port (e.g., 587)
   - Username
   - Password
   - Encryption (TLS/SSL)
   - From Email
   - From Name
   - **Days Before Event** (default: 7 days)

### 3. Install Dependencies

The backend already includes `nodemailer` for sending emails. If needed:

```bash
cd Backend
npm install nodemailer @types/nodemailer
```

## How It Works

### Automatic Notification

A cron job runs daily at 9:00 AM to check for upcoming events:

```typescript
// Runs daily at 9 AM
cron.schedule('0 9 * * *', () => {
  sendEventNotifications();
});
```

### Event Processing Logic

1. **Fetch SMTP Settings**: Retrieves active SMTP configuration including `days_before_event`
2. **Get Upcoming Events**: Finds events that are exactly `days_before_event` days away
3. **Handle Recurring Events**: 
   - For recurring events, calculates the next occurrence date
   - Does NOT create duplicate event entries
   - Sends notifications for the calculated date
4. **Get Employees**: 
   - If event has `branch_id`, only notifies employees from that branch
   - If `branch_id` is null, notifies all active employees
5. **Send Emails**: 
   - Checks if notification was already sent (prevents duplicates)
   - Sends formatted HTML email to each employee
   - Logs the notification in `event_notification_log` table

### Recurring Events

Recurring events are handled intelligently:

- The system calculates the next occurrence date based on the original event date
- If the event date has passed this year, it uses next year's date
- No duplicate event entries are created in the database
- Notifications are sent for the calculated date

Example:
- Event: "New Year's Day" (recurring, January 1st)
- Original date: 2024-01-01
- In 2025, notification will be sent for 2025-01-01
- In 2026, notification will be sent for 2026-01-01

## Email Template

The system sends beautifully formatted HTML emails with:
- Event title and type
- Formatted event date
- Event description (if available)
- Professional styling

## Startup Testing

When the server starts, it automatically tests the SMTP configuration:

- **Connection Test**: Verifies SMTP connection without sending email
- **Test Email** (optional): Set `SEND_TEST_EMAIL_ON_STARTUP=true` in `.env` to send a test email

The test will show:
- ✓ Success message if SMTP is configured correctly
- ✗ Error message if SMTP needs configuration

## Manual Testing

You can manually trigger the notification process:

```typescript
import { sendEventNotifications } from './event-notification-service';

// Run manually
sendEventNotifications();
```

Or test SMTP connection only:

```typescript
import { testSmtpConnection } from './email-service';

// Test connection only
const result = await testSmtpConnection(false);

// Test connection and send test email
const result = await testSmtpConnection(true);
console.log(result.message);
```

## Database Tables

### `smtp_settings`
- Added column: `days_before_event` (INTEGER, default: 7)

### `event_notification_log` (new table)
- `id`: UUID primary key
- `event_id`: References `company_events.id`
- `employee_id`: References `employees.id`
- `notification_date`: Date when notification was sent
- `event_date`: The actual event date
- `email_sent_at`: Timestamp of email send
- `email_status`: 'sent', 'failed', or 'pending'
- `error_message`: Error details if failed

## Troubleshooting

### Emails Not Sending

1. **Check SMTP Settings**: Verify SMTP configuration is correct
2. **Check Logs**: Review backend console logs for errors
3. **Verify Events**: Ensure events exist and are active
4. **Check Employees**: Verify employees have valid email addresses
5. **Test SMTP**: Use the "Test Connection" button in Settings

### Duplicate Emails

The system prevents duplicates by checking `event_notification_log`. If you need to resend:
- Delete the log entry for that event/employee/date combination
- Or wait for the next occurrence (for recurring events)

### Recurring Events Not Working

- Ensure `is_recurring` is set to `true` in the event
- The system calculates dates based on month/day of original event
- Check that the original `start_date` is valid

## Configuration

### Change Notification Timing

Update `days_before_event` in SMTP Settings:
- Minimum: 0 days (same day)
- Maximum: 365 days (1 year in advance)
- Default: 7 days

### Change Cron Schedule

Edit `Backend/index.ts`:

```typescript
// Current: Daily at 9 AM
cron.schedule('0 9 * * *', () => {
  sendEventNotifications();
});

// Example: Daily at 8 AM
cron.schedule('0 8 * * *', () => {
  sendEventNotifications();
});
```

## Files Modified/Created

### Backend
- `Backend/email-service.ts` - Email sending functionality
- `Backend/event-notification-service.ts` - Event notification logic
- `Backend/index.ts` - Added cron job
- `Backend/migrations/20250115000000_add_event_notification_settings.sql` - Database migration

### Frontend
- `Frontend/src/pages/Settings.tsx` - Added `days_before_event` field
- `Frontend/supabase/migrations/20250115000000_add_event_notification_settings.sql` - Database migration

## Future Enhancements

Possible improvements:
- Email templates customization
- Multiple notification reminders (e.g., 7 days and 1 day before)
- SMS notifications
- Calendar integration (iCal attachments)
- Notification preferences per employee
- Event-specific notification settings

