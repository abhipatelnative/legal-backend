import dotenv from "dotenv";
import { sendEventNotifications } from "./event-notification-service";

dotenv.config();

console.log('=== Testing Event Notification System ===\n');

sendEventNotifications()
  .then(() => {
    console.log('\n✓ Event notification test completed!');
    process.exit(0);
  })
  .catch((error) => {
    console.error('\n✗ Error during event notification test:', error);
    process.exit(1);
  });



