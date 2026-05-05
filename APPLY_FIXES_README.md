# How to Apply the Fixes

## Step 1: Update `process_daily_attendance` Function

1. Open Supabase Dashboard → SQL Editor
2. Copy the entire contents of `updated_process_daily_attendance.sql`
3. Paste and run in SQL Editor
4. Verify: You should see "Success. No rows returned"

## Step 2: Update `backfill_attendance_counting` Function

1. In Supabase SQL Editor
2. Copy the entire contents of `updated_backfill_attendance_counting.sql`
3. Paste and run in SQL Editor
4. Verify: You should see "Success. No rows returned"

## Step 3: Test with the Reported Employee

Run this SQL query to backfill the employee's attendance:

```sql
SELECT * FROM backfill_attendance_counting(
    '3559e059-048f-44df-9094-1ce198f9050e'::UUID,
    '2025-12-01'::DATE
);
```

Expected result: Should show total days counted, current counter, and leaves earned.

## Step 4: Verify December 24th Now Exists

```sql
SELECT counting_date, is_counted, reason
FROM attendance_day_counting
WHERE employee_id = '3559e059-048f-44df-9094-1ce198f9050e'
  AND counting_date BETWEEN '2025-12-01' AND '2025-12-31'
ORDER BY counting_date ASC;
```

**Expected**: You should now see ALL dates from Dec 1-31, including December 24th with appropriate status (absent/weekoff/holiday).

## Step 5: Test the API Endpoint

Make the same API request:
```
GET /rest/v1/attendance_day_counting?select=counting_date,is_counted,reason&employee_id=eq.3559e059-048f-44df-9094-1ce198f9050e&counting_date=gte.2025-12-01&counting_date=lte.2025-12-31&order=counting_date.asc
```

**Expected**: Response should include all 31 days with no gaps.

## Key Changes Made

### `process_daily_attendance`:
- Added `attendance_day_counting` insert after each status determination
- Now populates both `employee_attendance` AND `attendance_day_counting` tables
- Maintains 4 AM cutoff logic for midnight punches

### `backfill_attendance_counting`:
- Uses `generate_series()` to create records for EVERY day from start date to current date
- Categorizes each day based on priority: punch → leave → holiday → weekoff → absent
- Maintains 4 AM cutoff logic for midnight punches
- No longer skips days without punches

## Notes

- No table schema changes required
- Both functions maintain the existing 4 AM cutoff logic for midnight punches
- The `is_counted` field is TRUE only for 'present' days
- All other statuses (leave, holiday, weekoff, absent) have `is_counted = FALSE`
