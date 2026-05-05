import mysql from 'mysql2/promise';
import { createClient } from '@supabase/supabase-js';
import { RowDataPacket } from 'mysql2';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } from './config/credentials';
import { createMysqlPool } from './mysql-connection';

dayjs.extend(utc);

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

// ─── Types ────────────────────────────────────────────────────────────────────

export interface BiometricConfig {
  db_host: string;
  db_port: number;
  db_user: string;
  db_password: string;
  db_name: string;
  table_name: string;
  col_id: string;
  col_user_id: string;
  col_timestamp: string;
  col_direction: string;
  col_verify_mode: string;
  in_value: string;
  out_value: string;
  sync_batch_limit: number;
}

interface BiometricDevice extends BiometricConfig {
  id: string;         // UUID from biometric_devices table
  device_name: string;
  device_brand: string;
}

interface DynamicRow extends RowDataPacket {
  [key: string]: any;
}

// ─── Pool Cache (one pool per device, keyed by device UUID) ──────────────────

interface PoolEntry { pool: mysql.Pool; connKey: string; }
const _pools = new Map<string, PoolEntry>();

// Single-device config cache (legacy: from company_settings)
let _legacyConfig: BiometricConfig | null = null;
let _legacyConfigFetchedAt = 0;
const CONFIG_TTL_MS = 60_000;

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Strip everything except alphanumeric + underscore to prevent SQL injection in identifiers. */
function safeId(name: string): string {
  return name.replace(/[^a-zA-Z0-9_]/g, '');
}

/** Backtick-quote a db and table name: `db`.`table` */
function tableRef(config: BiometricConfig): string {
  return `\`${safeId(config.db_name)}\`.\`${safeId(config.table_name)}\``;
}

/** Get or create a MySQL pool for a given device/config, keyed by cacheKey. */
function getOrCreatePool(cacheKey: string, config: BiometricConfig): mysql.Pool {
  const connKey = `${config.db_host}:${config.db_port}:${config.db_user}:${config.db_name}`;
  const entry = _pools.get(cacheKey);
  if (entry && entry.connKey === connKey) return entry.pool;

  // Config changed or first time — close old pool and create a new one
  if (entry) {
    try { (entry.pool as any).end(); } catch { /* ignore */ }
  }
  const pool = createMysqlPool({
    host:     config.db_host,
    port:     config.db_port,
    user:     config.db_user,
    password: config.db_password,
    database: config.db_name,
  });
  _pools.set(cacheKey, { pool, connKey });
  return pool;
}

/** Map raw direction value → 1 (in) / 0 (out) / null. */
function mapDirection(raw: any, config: BiometricConfig): number | null {
  if (raw === null || raw === undefined) return null;
  const str = String(raw);
  if (str === config.in_value)  return 1;
  if (str === config.out_value) return 0;
  const num = Number(raw);
  return isNaN(num) ? null : num;
}

/** Transform a raw device DB row into a punch_records row. */
function mapRow(row: DynamicRow, config: BiometricConfig, deviceId?: string) {
  return {
    mysql_id:             row[config.col_id],
    enroll_number:        Number(row[config.col_user_id]) || 0,
    punch_time:           dayjs(row[config.col_timestamp]).format('YYYY-MM-DD HH:mm:ss'),
    in_out_mode:          mapDirection(row[config.col_direction], config),
    verify_mode:          row[config.col_verify_mode] ?? null,
    ...(deviceId ? { biometric_device_id: deviceId } : {}),
  };
}

// ─── Device Fetching ──────────────────────────────────────────────────────────

/**
 * Fetch all active biometric devices from the biometric_devices table.
 * Returns an empty array if the table doesn't exist yet (pre-migration).
 */
async function fetchActiveDevices(): Promise<BiometricDevice[]> {
  try {
    const { data, error } = await supabaseAdmin
      .from('biometric_devices')
      .select('*')
      .eq('is_active', true)
      .eq('is_deleted', false)
      .order('created_at', { ascending: true });

    if (error) {
      // Table may not exist yet on older deployments
      console.warn('Could not fetch biometric_devices:', error.message);
      return [];
    }

    return (data || []).map((d: any) => ({
      id:               d.id,
      device_name:      d.device_name,
      device_brand:     d.device_brand || 'Custom',
      db_host:          d.db_host          || '',
      db_port:          Number(d.db_port)  || 3306,
      db_user:          d.db_user          || '',
      db_password:      d.db_password      || '',
      db_name:          d.db_name          || 'dmps',
      table_name:       d.table_name       || 'DeviceLogs',
      col_id:           d.col_id           || 'Id',
      col_user_id:      d.col_user_id      || 'UserId',
      col_timestamp:    d.col_timestamp    || 'IOTime',
      col_direction:    d.col_direction    || 'IOMode',
      col_verify_mode:  d.col_verify_mode  || 'VerifyMode',
      in_value:         d.in_value         ?? 'in',
      out_value:        d.out_value        ?? 'out',
      sync_batch_limit: Number(d.sync_batch_limit) || 10,
    }));
  } catch {
    return [];
  }
}

/**
 * Legacy fallback: read single-device config from company_settings.
 * Used when biometric_devices table has no active entries.
 */
async function fetchLegacyConfig(): Promise<BiometricConfig | null> {
  const now = Date.now();
  if (_legacyConfig && now - _legacyConfigFetchedAt < CONFIG_TTL_MS) return _legacyConfig;

  const { data: _data, error } = await (supabase as any)
    .from('company_settings')
    .select(
      'biometric_db_host,biometric_db_port,biometric_db_user,biometric_db_password,' +
      'biometric_db_name,biometric_table_name,biometric_col_id,biometric_col_user_id,' +
      'biometric_col_timestamp,biometric_col_direction,biometric_col_verify_mode,' +
      'biometric_in_value,biometric_out_value,biometric_sync_batch_limit'
    )
    .eq('is_active', true)
    .eq('is_deleted', false)
    .maybeSingle();

  const data = _data as any;
  if (error || !data?.biometric_db_host) return null;

  _legacyConfig = {
    db_host:          data.biometric_db_host,
    db_port:          Number(data.biometric_db_port)          || 3306,
    db_user:          data.biometric_db_user                  || '',
    db_password:      data.biometric_db_password              || '',
    db_name:          data.biometric_db_name                  || 'dmps',
    table_name:       data.biometric_table_name               || 'DeviceLogs',
    col_id:           data.biometric_col_id                   || 'Id',
    col_user_id:      data.biometric_col_user_id              || 'UserId',
    col_timestamp:    data.biometric_col_timestamp            || 'IOTime',
    col_direction:    data.biometric_col_direction            || 'IOMode',
    col_verify_mode:  data.biometric_col_verify_mode          || 'VerifyMode',
    in_value:         data.biometric_in_value                 ?? 'in',
    out_value:        data.biometric_out_value                ?? 'out',
    sync_batch_limit: Number(data.biometric_sync_batch_limit) || 10,
  };
  _legacyConfigFetchedAt = now;
  return _legacyConfig;
}

// ─── Core Sync (per device) ───────────────────────────────────────────────────

/** Incremental sync for one device: pulls records with ID > last synced ID. */
async function syncDevice(
  config: BiometricConfig,
  deviceId?: string,
  label = 'legacy'
) {
  const pid = process.pid;
  console.log(`[PID:${pid}] Syncing device "${label}"...`);

  const pool = getOrCreatePool(deviceId ?? '_legacy', config);

  // Verify connection is alive
  const conn = await pool.getConnection();
  conn.release();

  // Watermark: last mysql_id already synced for THIS device
  const watermarkQuery = supabaseAdmin
    .from('punch_records')
    .select('mysql_id')
    .not('mysql_id', 'is', null)
    .order('mysql_id', { ascending: false })
    .limit(1);

  if (deviceId) {
    watermarkQuery.eq('biometric_device_id', deviceId);
  } else {
    watermarkQuery.is('biometric_device_id', null);
  }

  const { data: latestPunch } = await watermarkQuery;
  let lastMysqlId = latestPunch?.[0]?.mysql_id || 0;

  // If this device has never synced before, fall back to the global max mysql_id
  // so we don't re-import records already synced under the legacy (null device) path.
  if (lastMysqlId === 0 && deviceId) {
    const { data: globalLatest } = await supabaseAdmin
      .from('punch_records')
      .select('mysql_id')
      .not('mysql_id', 'is', null)
      .order('mysql_id', { ascending: false })
      .limit(1);
    lastMysqlId = globalLatest?.[0]?.mysql_id || 0;
    if (lastMysqlId > 0) {
      console.log(`[PID:${pid}] [${label}] New device — using global watermark: ${lastMysqlId}`);
    }
  }
  console.log(`[PID:${pid}] [${label}] Last synced MySQL ID: ${lastMysqlId}`);

  const idCol     = safeId(config.col_id);
  const userCol   = safeId(config.col_user_id);
  const timeCol   = safeId(config.col_timestamp);
  const dirCol    = safeId(config.col_direction);
  const verifyCol = safeId(config.col_verify_mode);
  const tbl       = tableRef(config);
  const limit     = config.sync_batch_limit;

  const [rows] = await pool.execute<DynamicRow[]>(
    `SELECT \`${idCol}\`, \`${userCol}\`, \`${timeCol}\`, \`${dirCol}\`, \`${verifyCol}\`
     FROM ${tbl}
     WHERE \`${idCol}\` > ?
     ORDER BY \`${idCol}\` ASC
     LIMIT ${limit}`,
    [lastMysqlId]
  );

  if (rows.length === 0) {
    console.log(`[PID:${pid}] [${label}] No new records`);
    return;
  }

  console.log(`[PID:${pid}] [${label}] Found ${rows.length} new records (IDs ${rows[0][idCol]}–${rows[rows.length - 1][idCol]})`);

  const punchRecords = rows.map(row => mapRow(row, config, deviceId));
  // Device records dedup on (biometric_device_id, mysql_id) constraint.
  // Legacy (no device) has no unique constraint on mysql_id alone after migration — use ignoreDuplicates.
  const upsertOptions = deviceId
    ? { onConflict: 'biometric_device_id,mysql_id' }
    : { ignoreDuplicates: true };

  const { error } = await supabaseAdmin
    .from('punch_records')
    .upsert(punchRecords, upsertOptions);

  if (error) {
    console.error(`[PID:${pid}] [${label}] Upsert error:`, error);
  } else {
    console.log(`[PID:${pid}] [${label}] Synced ${punchRecords.length} records`);
  }
}

// ─── Public Sync Functions ────────────────────────────────────────────────────

/**
 * Incremental sync — called every minute by the cron job.
 * Iterates over all active biometric_devices; falls back to company_settings
 * single-device config if no devices are configured yet.
 */
export async function syncPunchRecords() {
  const startTime = Date.now();
  let totalSynced = 0;
  let totalErrors = 0;

  try {
    const devices = await fetchActiveDevices();

    if (devices.length > 0) {
      // Multi-device path
      for (const device of devices) {
        if (!device.db_host) {
          console.warn(`Device "${device.device_name}" has no DB host configured — skipping`);
          continue;
        }
        try {
          const before = Date.now();
          await syncDevice(device, device.id, device.device_name);
          console.log(`[SUMMARY] Device "${device.device_name}" synced in ${Date.now() - before}ms`);
          totalSynced++;
        } catch (err: any) {
          console.error(`Error syncing device "${device.device_name}":`, err.message);
          totalErrors++;
        }
      }
    } else {
      // Legacy single-device path (company_settings)
      const config = await fetchLegacyConfig();
      if (!config) {
        console.log('No biometric devices configured and no legacy config found — skipping sync');
        return;
      }
      await syncDevice(config, undefined, 'company_settings');
      totalSynced++;
    }
  } catch (error: any) {
    if (error.code === 'ER_ACCESS_DENIED_ERROR') {
      console.log('MySQL access denied — skipping punch sync');
    } else {
      console.error('Punch sync error:', error.message);
    }
    totalErrors++;
  } finally {
    const elapsed = Date.now() - startTime;
    console.log(`[SYNC SUMMARY] Completed in ${elapsed}ms | Devices synced: ${totalSynced} | Errors: ${totalErrors}`);
  }
}

/**
 * Bulk sync — pulls ALL records from MySQL for a specific device (by UUID)
 * or for the legacy company_settings config if no deviceId given.
 * Use for initial import or full backfill.
 */
export async function syncAllPunchRecords(deviceId?: string) {
  try {
    let config: BiometricConfig;
    let label: string;

    if (deviceId) {
      const devices = await fetchActiveDevices();
      const device = devices.find(d => d.id === deviceId);
      if (!device) throw new Error(`Device ${deviceId} not found or inactive`);
      config = device;
      label  = device.device_name;
    } else {
      const legacy = await fetchLegacyConfig();
      if (!legacy) throw new Error('No biometric config found in company_settings');
      config = legacy;
      label  = 'company_settings';
    }

    console.log(`[BULK] Starting bulk sync for "${label}"...`);
    const pool = getOrCreatePool(deviceId ?? '_legacy', config);

    const conn = await pool.getConnection();
    conn.release();

    const idCol     = safeId(config.col_id);
    const userCol   = safeId(config.col_user_id);
    const timeCol   = safeId(config.col_timestamp);
    const dirCol    = safeId(config.col_direction);
    const verifyCol = safeId(config.col_verify_mode);
    const tbl       = tableRef(config);

    const [rows] = await pool.execute<DynamicRow[]>(
      `SELECT \`${idCol}\`, \`${userCol}\`, \`${timeCol}\`, \`${dirCol}\`, \`${verifyCol}\`
       FROM ${tbl}
       ORDER BY \`${idCol}\` ASC`
    );

    console.log(`[BULK] [${label}] Total records: ${rows.length}`);
    if (rows.length === 0) return;

    const upsertOptions = deviceId ? { onConflict: 'biometric_device_id,mysql_id' } : { ignoreDuplicates: true };
    const batchSize     = 1000;
    let processed       = 0;

    for (let i = 0; i < rows.length; i += batchSize) {
      const batch = rows.slice(i, i + batchSize).map(row => mapRow(row, config, deviceId));
      const { error } = await supabase
        .from('punch_records')
        .upsert(batch, upsertOptions);

      if (error) {
        console.error(`[BULK] Batch ${Math.floor(i / batchSize) + 1} error:`, error);
      } else {
        processed += batch.length;
        console.log(`[BULK] [${label}] ${processed}/${rows.length}`);
      }
    }
    console.log(`[BULK] [${label}] Done — synced ${processed} records`);
  } catch (error: any) {
    console.error('Bulk sync error:', error.message);
  }
}

/**
 * Date-range sync for a specific device or legacy config.
 * Useful for re-syncing a date window after correcting data.
 */
export async function syncPunchRecordsByDateRange(
  startDate: string,
  endDate: string,
  deviceId?: string
) {
  try {
    let config: BiometricConfig;
    let label: string;

    if (deviceId) {
      const devices = await fetchActiveDevices();
      const device  = devices.find(d => d.id === deviceId);
      if (!device) throw new Error(`Device ${deviceId} not found or inactive`);
      config = device;
      label  = device.device_name;
    } else {
      const legacy = await fetchLegacyConfig();
      if (!legacy) throw new Error('No biometric config found in company_settings');
      config = legacy;
      label  = 'company_settings';
    }

    console.log(`=== DATE RANGE SYNC [${label}]: ${startDate} → ${endDate} ===`);
    const pool = getOrCreatePool(deviceId ?? '_legacy', config);

    const conn = await pool.getConnection();
    conn.release();

    const idCol     = safeId(config.col_id);
    const userCol   = safeId(config.col_user_id);
    const timeCol   = safeId(config.col_timestamp);
    const dirCol    = safeId(config.col_direction);
    const verifyCol = safeId(config.col_verify_mode);
    const tbl       = tableRef(config);

    const [rows] = await pool.execute<DynamicRow[]>(
      `SELECT \`${idCol}\`, \`${userCol}\`, \`${timeCol}\`, \`${dirCol}\`, \`${verifyCol}\`
       FROM ${tbl}
       WHERE \`${timeCol}\` >= ? AND \`${timeCol}\` <= ?
       ORDER BY \`${idCol}\` ASC`,
      [`${startDate} 00:00:00`, `${endDate} 23:59:59`]
    );

    if (rows.length === 0) { console.log('No records in date range'); return; }

    const upsertOptions = deviceId ? { onConflict: 'biometric_device_id,mysql_id' } : { ignoreDuplicates: true };
    const batchSize     = 1000;
    let processed       = 0;

    for (let i = 0; i < rows.length; i += batchSize) {
      const batch = rows.slice(i, i + batchSize).map(row => mapRow(row, config, deviceId));
      const { error } = await supabase
        .from('punch_records')
        .upsert(batch, upsertOptions);
      if (!error) processed += batch.length;
      else console.error(`Batch ${Math.floor(i / batchSize) + 1} error:`, error);
    }
    console.log(`=== DATE RANGE SYNC DONE — ${processed} records ===`);
  } catch (error: any) {
    console.error('Date range sync error:', error.message);
  }
}

/**
 * Date-range + employee sync for a specific device or legacy config.
 */
export async function syncPunchRecordsByDateRangeAndUserId(
  startDate: string,
  endDate: string,
  userId: number,
  deviceId?: string
) {
  try {
    let config: BiometricConfig;
    let label: string;

    if (deviceId) {
      const devices = await fetchActiveDevices();
      const device  = devices.find(d => d.id === deviceId);
      if (!device) throw new Error(`Device ${deviceId} not found or inactive`);
      config = device;
      label  = device.device_name;
    } else {
      const legacy = await fetchLegacyConfig();
      if (!legacy) throw new Error('No biometric config found in company_settings');
      config = legacy;
      label  = 'company_settings';
    }

    console.log(`=== USER SYNC [${label}] User:${userId} ${startDate}→${endDate} ===`);
    const pool = getOrCreatePool(deviceId ?? '_legacy', config);

    const conn = await pool.getConnection();
    conn.release();

    const idCol     = safeId(config.col_id);
    const userCol   = safeId(config.col_user_id);
    const timeCol   = safeId(config.col_timestamp);
    const dirCol    = safeId(config.col_direction);
    const verifyCol = safeId(config.col_verify_mode);
    const tbl       = tableRef(config);

    const [rows] = await pool.execute<DynamicRow[]>(
      `SELECT \`${idCol}\`, \`${userCol}\`, \`${timeCol}\`, \`${dirCol}\`, \`${verifyCol}\`
       FROM ${tbl}
       WHERE \`${timeCol}\` >= ? AND \`${timeCol}\` <= ? AND \`${userCol}\` = ?
       ORDER BY \`${idCol}\` ASC`,
      [`${startDate} 00:00:00`, `${endDate} 23:59:59`, userId]
    );

    if (rows.length === 0) { console.log(`No records for User ${userId} in range`); return; }

    const punchRecords = rows.map(row => mapRow(row, config, deviceId));
    // Device records dedup on (biometric_device_id, mysql_id) constraint.
  // Legacy (no device) has no unique constraint on mysql_id alone after migration — use ignoreDuplicates.
  const upsertOptions = deviceId
    ? { onConflict: 'biometric_device_id,mysql_id' }
    : { ignoreDuplicates: true };

    const { error } = await supabase
      .from('punch_records')
      .upsert(punchRecords, upsertOptions);

    if (error) console.error('Upsert error:', error);
    else console.log(`=== USER SYNC DONE — ${punchRecords.length} records ===`);
  } catch (error: any) {
    console.error('User sync error:', error.message);
  }
}

// ─── Test Connection ─────────────────────────────────────────────────────────

/**
 * Test MySQL connection for a device config without syncing any records.
 * Returns connection status and a sample record count.
 */
export async function testDeviceConnection(config: BiometricConfig, label = 'test'): Promise<{ success: boolean; message: string; recordCount?: number }> {
  try {
    const pool = getOrCreatePool(`_test_${Date.now()}`, config);
    const conn = await pool.getConnection();
    conn.release();

    // Try a sample query
    const tbl = tableRef(config);
    const idCol = safeId(config.col_id);
    const [rows] = await pool.execute<DynamicRow[]>(`SELECT COUNT(*) as cnt FROM ${tbl}`);
    const count = (rows[0] as any).cnt;

    return { success: true, message: `Connected successfully. ${count} records in ${config.table_name}.`, recordCount: count };
  } catch (err: any) {
    return { success: false, message: err.message || 'Connection failed' };
  }
}

// ─── Sync Request Queue Processor ─────────────────────────────────────────────

/**
 * Process pending sync requests from the biometric_sync_requests table.
 * Called by the cron job every minute alongside the regular sync.
 */
export async function processSyncRequests() {
  try {
    const { data: requests, error } = await supabaseAdmin
      .from('biometric_sync_requests')
      .select('*')
      .eq('status', 'pending')
      .order('created_at', { ascending: true })
      .limit(10);

    if (error || !requests?.length) return;

    for (const req of requests) {
      // Mark as processing
      await supabaseAdmin
        .from('biometric_sync_requests')
        .update({ status: 'processing' })
        .eq('id', req.id);

      try {
        if (req.device_id) {
          // Sync specific device
          const devices = await fetchActiveDevices();
          const device = devices.find(d => d.id === req.device_id);
          if (!device) throw new Error('Device not found or inactive');
          await syncDevice(device, device.id, device.device_name);
        } else {
          // Sync all
          await syncPunchRecords();
        }

        await supabaseAdmin
          .from('biometric_sync_requests')
          .update({ status: 'done', result: { synced: true }, completed_at: new Date().toISOString() })
          .eq('id', req.id);
      } catch (err: any) {
        await supabaseAdmin
          .from('biometric_sync_requests')
          .update({ status: 'error', result: { error: err.message }, completed_at: new Date().toISOString() })
          .eq('id', req.id);
      }
    }
  } catch (err: any) {
    console.error('Error processing sync requests:', err.message);
  }
}
