import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from './config/credentials';
const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
(async () => {
  const { data } = await sb
    .from('notification_auto_rules')
    .select('trigger_type, template_variable_samples')
    .order('trigger_type');
  for (const r of (data || [])) {
    const samples = r.template_variable_samples;
    const keys = Array.isArray(samples) ? samples.map((s: any) => s.key).join(', ') : '(none)';
    console.log(`${r.trigger_type}: ${keys}`);
  }
  process.exit(0);
})();
