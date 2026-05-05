-- ============================================================================
-- Create punch_records_archive table and archive_and_clear_punches_for_date RPC
-- ============================================================================
-- When a same-day leave is approved with "Allow Punch Deletion" enabled, the
-- employee's punches for that day are moved from punch_records into this
-- archive instead of being permanently deleted. The calendar then renders
-- archived punches in a distinct color so the override is visible.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.punch_records_archive (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_punch_id     uuid NOT NULL,
  enroll_number       integer NOT NULL,
  employee_id         uuid NULL,
  punch_time          timestamp with time zone NOT NULL,
  verify_mode         varchar NULL,
  in_out_mode         integer NULL,
  is_manual           boolean DEFAULT false,
  metadata_id         uuid NULL,
  archived_at         timestamp with time zone NOT NULL DEFAULT now(),
  archived_by         uuid NULL REFERENCES auth.users(id),
  archive_reason      varchar NOT NULL DEFAULT 'leave_approval',
  leave_request_id    uuid NULL,
  attendance_date     date NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_punch_archive_enroll_date
  ON public.punch_records_archive(enroll_number, attendance_date);

CREATE INDEX IF NOT EXISTS idx_punch_archive_employee_date
  ON public.punch_records_archive(employee_id, attendance_date);

CREATE INDEX IF NOT EXISTS idx_punch_archive_punch_time
  ON public.punch_records_archive(punch_time);

COMMENT ON TABLE public.punch_records_archive IS 'Snapshot of punch_records removed from the live table due to a leave approval. Read-only reference used by the calendar to show overridden punches.';
COMMENT ON COLUMN public.punch_records_archive.source_punch_id IS 'Original punch_records.id before deletion.';
COMMENT ON COLUMN public.punch_records_archive.archive_reason IS 'Why the punch was archived (currently only ''leave_approval'').';
COMMENT ON COLUMN public.punch_records_archive.attendance_date IS 'Calendar day the punch belongs to (4 AM cutoff).';

-- ----------------------------------------------------------------------------
-- RPC: archive_and_clear_punches_for_date
-- Copies matching punches into the archive, then hard-deletes them from
-- punch_records. Returns the count archived.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.archive_and_clear_punches_for_date(
  p_employee_id uuid,
  p_attendance_date date,
  p_leave_request_id uuid DEFAULT NULL,
  p_archived_by uuid DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
  v_biometric_code text;
  v_enroll_number integer;
  v_archived_count integer := 0;
  v_start timestamptz;
  v_end   timestamptz;
BEGIN
  -- Resolve biometric enroll number via employees -> user_profiles
  SELECT e.user_id INTO v_user_id
  FROM public.employees e
  WHERE e.id = p_employee_id;

  IF v_user_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT up.biometric_code INTO v_biometric_code
  FROM public.user_profiles up
  WHERE up.id = v_user_id;

  IF v_biometric_code IS NULL OR v_biometric_code = '' THEN
    RETURN 0;
  END IF;

  BEGIN
    v_enroll_number := v_biometric_code::integer;
  EXCEPTION WHEN others THEN
    RETURN 0;
  END;

  -- 4 AM cutoff to match calendar semantics: 04:00:00 of the date through 03:59:59 of the next day
  v_start := p_attendance_date::timestamptz + INTERVAL '4 hours';
  v_end   := p_attendance_date::timestamptz + INTERVAL '1 day 3 hours 59 minutes 59 seconds';

  INSERT INTO public.punch_records_archive
    (source_punch_id, enroll_number, employee_id, punch_time, verify_mode,
     in_out_mode, is_manual, metadata_id, archived_by, archive_reason,
     leave_request_id, attendance_date)
  SELECT pr.id, pr.enroll_number, p_employee_id, pr.punch_time, pr.verify_mode,
         pr.in_out_mode, pr.is_manual, pr.metadata_id, p_archived_by, 'leave_approval',
         p_leave_request_id, p_attendance_date
  FROM public.punch_records pr
  WHERE pr.enroll_number = v_enroll_number
    AND pr.punch_time >= v_start
    AND pr.punch_time <= v_end
    AND COALESCE(pr.is_deleted, false) = false;

  GET DIAGNOSTICS v_archived_count = ROW_COUNT;

  DELETE FROM public.punch_records
  WHERE enroll_number = v_enroll_number
    AND punch_time >= v_start
    AND punch_time <= v_end;

  RETURN v_archived_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.archive_and_clear_punches_for_date(uuid, date, uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.archive_and_clear_punches_for_date(uuid, date, uuid, uuid)
  IS 'Archives and deletes the employee punches for a single day. Called from the Leaves approval flow when Allow Punch Deletion is enabled.';
