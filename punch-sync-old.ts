import { mysqlPool } from './mysql-connection';
import { createClient } from '@supabase/supabase-js';
import { RowDataPacket } from 'mysql2';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';
import dotenv from 'dotenv';

dotenv.config();
dayjs.extend(utc);


const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

interface MySQLPunchRecord extends RowDataPacket {
  Id: number;
  UserId: number;
  IOTime: string;
  IOMode: any;
  VerifyMode: any;
}

export async function syncPunchRecords() {
  try {
    console.log('Starting punch sync...');

    const connection = await mysqlPool.getConnection();
    connection.release();

    // Get the latest MySQL ID that was synced to avoid duplicates
    const { data: latestPunch } = await supabase
      .from('punch_records')
      .select('mysql_id')
      .order('mysql_id', { ascending: false })
      .limit(1);

    const lastMysqlId = latestPunch?.[0]?.mysql_id || 0;
    console.log(`Last synced MySQL ID: ${lastMysqlId}`);

    // Query MySQL for new punch records using ID instead of timestamp
    const [rows] = await mysqlPool.execute<MySQLPunchRecord[]>(
      `SELECT Id, UserId, IOTime, IOMode, VerifyMode 
       FROM dmps.DeviceLogs 
       WHERE Id > ?
       ORDER BY Id ASC
       LIMIT 10`,
      [lastMysqlId]
    );

    console.log(`Found ${rows.length} new MySQL records`);

    if (rows.length === 0) {
      console.log('No new punch records found');
      return;
    }

    // Transform MySQL data to Supabase format
    const punchRecords = rows.map(row => ({
      mysql_id: row.Id,
      enroll_number: Number(row.UserId) || 0,
      punch_time: dayjs(row.IOTime).add(5, 'hour').add(30, 'minute').format('YYYY-MM-DD HH:mm:ss'),
      in_out_mode: row.IOMode === 'in' ? 1 : (row.IOMode === 'out' ? 0 : (Number(row.IOMode) || null)),
      verify_mode: row.VerifyMode || null
    }));

    // Insert into Supabase with upsert to handle duplicates
    const { error } = await supabase
      .from('punch_records')
      .upsert(punchRecords, { onConflict: 'mysql_id' });

    if (error) {
      console.error('Error inserting punch records:', error);
    } else {
      console.log(`Successfully synced ${punchRecords.length} punch records`);
    }

  } catch (error: any) {
    if (error.code === 'ER_ACCESS_DENIED_ERROR') {
      console.log('MySQL access denied - skipping punch sync');
    } else {
      console.error('Punch sync error:', error.message);
    }
  }
}

export async function syncAllPunchRecords() {
  try {
    console.log('Starting bulk punch sync for all records...');

    const connection = await mysqlPool.getConnection();
    connection.release();

    // Get all punch records from MySQL
    const [rows] = await mysqlPool.execute<MySQLPunchRecord[]>(
      `SELECT Id, UserId, IOTime, IOMode, VerifyMode 
       FROM dmps.DeviceLogs 
       ORDER BY Id ASC`
    );

    console.log(`Found ${rows.length} total MySQL records`);

    if (rows.length === 0) {
      console.log('No punch records found in MySQL');
      return;
    }

    // Process in batches of 1000
    const batchSize = 1000;
    let processed = 0;

    for (let i = 0; i < rows.length; i += batchSize) {
      const batch = rows.slice(i, i + batchSize);

      const punchRecords = batch.map(row => ({
        mysql_id: row.Id,
        enroll_number: Number(row.UserId) || 0,
        punch_time: dayjs(row.IOTime).add(5, 'hour').add(30, 'minute').format('YYYY-MM-DD HH:mm:ss'),
        in_out_mode: row.IOMode === 'in' ? 1 : (row.IOMode === 'out' ? 0 : (Number(row.IOMode) || null)),
        verify_mode: row.VerifyMode || null
      }));

      const { error } = await supabase
        .from('punch_records')
        .upsert(punchRecords, { onConflict: 'mysql_id' });

      if (error) {
        console.error(`Error inserting batch ${i / batchSize + 1}:`, error);
      } else {
        processed += batch.length;
        console.log(`Processed ${processed}/${rows.length} records`);
      }
    }

    console.log(`Successfully synced all ${processed} punch records`);

  } catch (error: any) {
    console.error('Bulk punch sync error:', error.message);
  }
}
export async function syncCurrentMonthPunchRecords() {
  try {
    console.log('=== STARTING CURRENT MONTH PUNCH SYNC ===');

    const connection = await mysqlPool.getConnection();
    connection.release();

    // Get current month date range
    const currentMonth = dayjs().format('YYYY-MM');
    const startDate = `${currentMonth}-01 00:00:00`;
    const endDate = dayjs().add(1, 'month').startOf('month').format('YYYY-MM-DD HH:mm:ss');

    console.log(`Syncing punch records from ${startDate} to ${endDate}`);

    // Get punch records from MySQL for current month
    const [rows] = await mysqlPool.execute<MySQLPunchRecord[]>(
      `SELECT Id, UserId, IOTime, IOMode, VerifyMode 
       FROM dmps.DeviceLogs 
       WHERE IOTime >= ? AND IOTime < ?
       ORDER BY Id ASC`,
      [startDate, endDate]
    );

    console.log(`Found ${rows.length} current month MySQL records`);

    if (rows.length === 0) {
      console.log('No punch records found for current month');
      return;
    }

    // Process in batches of 1000
    const batchSize = 1000;
    let processed = 0;

    for (let i = 0; i < rows.length; i += batchSize) {
      const batch = rows.slice(i, i + batchSize);

      const punchRecords = batch.map(row => ({
        mysql_id: row.Id,
        enroll_number: Number(row.UserId) || 0,
        punch_time: dayjs(row.IOTime).add(5, 'hour').add(30, 'minute').format('YYYY-MM-DD HH:mm:ss'),
        in_out_mode: row.IOMode === 'in' ? 1 : (row.IOMode === 'out' ? 0 : (Number(row.IOMode) || null)),
        verify_mode: row.VerifyMode || null
      }));

      const { error } = await supabase
        .from('punch_records')
        .upsert(punchRecords, { onConflict: 'mysql_id' });

      if (error) {
        console.error(`Error inserting batch ${i / batchSize + 1}:`, error);
      } else {
        processed += batch.length;
        console.log(`Processed ${processed}/${rows.length} current month records`);
      }
    }

    console.log(`=== SUCCESSFULLY SYNCED ${processed} CURRENT MONTH PUNCH RECORDS ===`);

  } catch (error: any) {
    console.error('Current month punch sync error:', error.message);
  }
}