import { syncAllPunchRecords } from './punch-sync';

async function runBulkSync() {
  console.log('Starting bulk sync of all punch records...');
  await syncAllPunchRecords();
  console.log('Bulk sync completed!');
  process.exit(0);
}

runBulkSync().catch(console.error);