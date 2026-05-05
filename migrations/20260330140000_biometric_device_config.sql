-- ============================================================
-- Biometric Device Dynamic Configuration
-- Adds all connection + column-mapping settings to company_settings
-- so MySQL credentials and table schema can be configured from the UI
-- without changing any code.
-- ============================================================

ALTER TABLE company_settings
  ADD COLUMN IF NOT EXISTS biometric_db_host          text    DEFAULT '',
  ADD COLUMN IF NOT EXISTS biometric_db_port          integer DEFAULT 3306,
  ADD COLUMN IF NOT EXISTS biometric_db_user          text    DEFAULT '',
  ADD COLUMN IF NOT EXISTS biometric_db_password      text    DEFAULT '',
  ADD COLUMN IF NOT EXISTS biometric_db_name          text    DEFAULT 'dmps',

  -- Table and column mapping (varies by device brand)
  ADD COLUMN IF NOT EXISTS biometric_table_name       text    DEFAULT 'DeviceLogs',
  ADD COLUMN IF NOT EXISTS biometric_col_id           text    DEFAULT 'Id',
  ADD COLUMN IF NOT EXISTS biometric_col_user_id      text    DEFAULT 'UserId',
  ADD COLUMN IF NOT EXISTS biometric_col_timestamp    text    DEFAULT 'IOTime',
  ADD COLUMN IF NOT EXISTS biometric_col_direction    text    DEFAULT 'IOMode',
  ADD COLUMN IF NOT EXISTS biometric_col_verify_mode  text    DEFAULT 'VerifyMode',

  -- Direction value mapping (e.g. 'in'/'out', '0'/'1', 'C'/'O')
  ADD COLUMN IF NOT EXISTS biometric_in_value         text    DEFAULT 'in',
  ADD COLUMN IF NOT EXISTS biometric_out_value        text    DEFAULT 'out',

  -- How many records to pull per incremental sync cycle
  ADD COLUMN IF NOT EXISTS biometric_sync_batch_limit integer DEFAULT 10;

-- Column reference for common device brands:
--
-- Biomax / eSSL eBioserver (default):
--   table: DeviceLogs  |  id: Id  |  user: UserId  |  time: IOTime
--   direction: IOMode  |  in: 'in'  |  out: 'out'
--
-- ZKTeco (CHECKINOUT table):
--   table: CHECKINOUT  |  id: SLOGID  |  user: USERID  |  time: CHECKTIME
--   direction: CHECKTYPE  |  in: '0'  |  out: '1'
--
-- eSSL newer firmware:
--   table: DeviceLogs  |  direction: IOMode  |  in: '1'  |  out: '0'
--
-- HikVision / generic:
--   Adjust column names to match your device's exported schema
