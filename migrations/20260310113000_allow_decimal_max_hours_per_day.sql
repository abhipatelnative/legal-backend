-- Allow fractional hourly leave limits such as 2.5 hours/day.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'leave_types'
      AND column_name = 'max_hours_per_day'
  ) THEN
    ALTER TABLE public.leave_types
      ALTER COLUMN max_hours_per_day TYPE numeric(5,2)
      USING max_hours_per_day::numeric(5,2);

    ALTER TABLE public.leave_types
      DROP CONSTRAINT IF EXISTS leave_types_max_hours_per_day_check;

    ALTER TABLE public.leave_types
      ADD CONSTRAINT leave_types_max_hours_per_day_check
      CHECK (
        max_hours_per_day IS NULL
        OR (max_hours_per_day > 0 AND max_hours_per_day <= 24)
      );
  END IF;
END $$;

