-- ============================================================
-- Multi-Device Biometric Attendance Support
-- Creates a biometric_devices table so each physical machine
-- can have its own DB connection + column-mapping config.
-- ============================================================

CREATE TABLE IF NOT EXISTS biometric_devices (
  id                  uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  device_name         text        NOT NULL,                   -- human label e.g. "Main Gate", "Branch 2"
  device_brand        text        DEFAULT 'Biomax',           -- Biomax | ZKTeco | eSSL | HikVision | Custom
  is_active           boolean     DEFAULT true,               -- toggle per device without deleting

  -- Connection
  db_host             text        DEFAULT '',
  db_port             integer     DEFAULT 3306,
  db_user             text        DEFAULT '',
  db_password         text        DEFAULT '',
  db_name             text        DEFAULT 'dmps',

  -- Table & column mapping (varies by brand / firmware)
  table_name          text        DEFAULT 'DeviceLogs',
  col_id              text        DEFAULT 'Id',               -- primary key / auto-increment ID
  col_user_id         text        DEFAULT 'UserId',           -- biometric enroll number
  col_timestamp       text        DEFAULT 'IOTime',           -- punch timestamp
  col_direction       text        DEFAULT 'IOMode',           -- check-in vs check-out flag
  col_verify_mode     text        DEFAULT 'VerifyMode',       -- fingerprint / card / face

  -- Direction value mapping
  in_value            text        DEFAULT 'in',               -- e.g. 'in', '0', 'C', '1'
  out_value           text        DEFAULT 'out',              -- e.g. 'out', '1', 'O', '0'

  -- Sync tuning
  sync_batch_limit    integer     DEFAULT 10,                 -- records per incremental sync cycle

  notes               text        DEFAULT '',                 -- free-form admin notes

  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),
  created_by          uuid        REFERENCES auth.users(id),
  updated_by          uuid        REFERENCES auth.users(id),
  is_deleted          boolean     DEFAULT false
);

-- Add device reference to punch_records for per-device deduplication
ALTER TABLE punch_records
  ADD COLUMN IF NOT EXISTS biometric_device_id uuid REFERENCES biometric_devices(id);

-- Drop the old single-column unique constraint on mysql_id — it conflicts when multiple
-- devices share the same auto-increment ID sequence (e.g. both start at 1).
ALTER TABLE punch_records
  DROP CONSTRAINT IF EXISTS punch_records_mysql_id_key;

-- New unique constraint: dedup per (device, mysql_id) so PostgREST can use ON CONFLICT.
-- NULL device_id rows (legacy) are excluded — Postgres treats (NULL, 1) != (NULL, 1).
ALTER TABLE punch_records
  ADD CONSTRAINT punch_records_device_mysql_uq
  UNIQUE (biometric_device_id, mysql_id);


-- ── Brand reference (column defaults per brand) ──────────────────────────────
--
--  Biomax / eSSL eBioserver (default)
--    table=DeviceLogs  col_id=Id  col_user_id=UserId  col_timestamp=IOTime
--    col_direction=IOMode  in_value='in'  out_value='out'
--
--  ZKTeco (CHECKINOUT table)
--    table=CHECKINOUT  col_id=SLOGID  col_user_id=USERID  col_timestamp=CHECKTIME
--    col_direction=CHECKTYPE  in_value='0'  out_value='1'
--
--  eSSL (newer firmware, inverted direction)
--    table=DeviceLogs  col_id=Id  col_user_id=UserId  col_timestamp=IOTime
--    col_direction=IOMode  in_value='1'  out_value='0'
--
--  HikVision
--    table=att_log  col_id=id  col_user_id=pin  col_timestamp=time
--    col_direction=inout_type  col_verify_mode=verify_type  in_value='0'  out_value='1'
--
--  Realand / Anviz / Generic
--    Use 'Custom' brand and fill in columns manually
