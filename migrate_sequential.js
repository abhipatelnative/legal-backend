const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

// ============================================
// CONFIGURATION
// ============================================
const SUPABASE_URL = 'http://192.168.29.125:8002';
const SUPABASE_SERVICE_ROLE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJzZXJ2aWNlX3JvbGUiLAogICAgImlzcyI6ICJzdXBhYmFzZS1kZW1vIiwKICAgICJpYXQiOiAxNjQxNzY5MjAwLAogICAgImV4cCI6IDE3OTk1MzU2MDAKfQ.DaYlNEoUrrEn2Ig7tqibS-PHK5vgusbcbo7X36XVt4Q';

// Initialize Supabase Client
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false }
});

const MIGRATION_MD_PATH = path.join(__dirname, 'migration.md');
const LOG_FILE_PATH = path.join(__dirname, '..', 'migration_log.md');
const BACKEND_MIGRATIONS_DIR = path.join(__dirname, 'migrations');
const FRONTEND_MIGRATIONS_DIR = path.join(__dirname, '..', 'Frontend', 'supabase', 'migrations');

// ============================================
// LOGGING & LOG-BASED RESUME
// ============================================

function log(message, isError = false) {
    const timestamp = new Date().toISOString();
    const formattedMsg = `[${timestamp}] ${isError ? '❌ ERROR:' : '✅ INFO:'} ${message}\n`;
    console.log(formattedMsg);
    fs.appendFileSync(LOG_FILE_PATH, formattedMsg);
}

function getAppliedFromLog() {
    if (!fs.existsSync(LOG_FILE_PATH)) {
        return new Set();
    }

    const logContent = fs.readFileSync(LOG_FILE_PATH, 'utf8');
    // Regex to find: "Successfully applied [filename]"
    const regex = /Successfully applied (\d{14}_[^`\r\n]+\.sql)/g;
    const matches = [];
    let match;

    while ((match = regex.exec(logContent)) !== null) {
        matches.push(match[1].trim());
    }

    return new Set(matches);
}

function parseMigrationMd() {
    if (!fs.existsSync(MIGRATION_MD_PATH)) {
        throw new Error(`Migration list not found at ${MIGRATION_MD_PATH}`);
    }
    const content = fs.readFileSync(MIGRATION_MD_PATH, 'utf8');
    const regex = /\d{14}_[^`\r\n]+\.sql/g;
    const matches = content.match(regex);
    if (!matches) throw new Error('No migration files found in migration.md');
    return [...new Set(matches.map(m => m.trim()))];
}

function findMigrationFile(filename) {
    const backendPath = path.join(BACKEND_MIGRATIONS_DIR, filename);
    if (fs.existsSync(backendPath)) return backendPath;
    const frontendPath = path.join(FRONTEND_MIGRATIONS_DIR, filename);
    if (fs.existsSync(frontendPath)) return frontendPath;
    return null;
}

// ============================================
// MAIN EXECUTION
// ============================================

async function runMigrations() {
    // We explicitly NOT clear the log file anymore to preserve history
    if (!fs.existsSync(LOG_FILE_PATH)) {
        fs.writeFileSync(LOG_FILE_PATH, `# Migration Log - Starting Fresh\n\n`);
    } else {
        fs.appendFileSync(LOG_FILE_PATH, `\n# Resume Migration Session - ${new Date().toLocaleString()}\n\n`);
    }

    try {
        log('Starting log-based migration process...');

        const appliedFiles = getAppliedFromLog();
        log(`Log-file reports ${appliedFiles.size} migrations already successfully applied.`);

        const migrationFiles = parseMigrationMd();
        const sortedFiles = [...migrationFiles].sort((a, b) => a.localeCompare(b));

        for (const file of sortedFiles) {
            if (appliedFiles.has(file)) {
                log(`Skipping ${file} (Found in log)`);
                continue;
            }

            const filePath = findMigrationFile(file);
            if (!filePath) {
                log(`Migration file NOT FOUND: ${file}. stopping execution.`, true);
                process.exit(1);
            }

            log(`Applying ${file}...`);
            const sqlContent = fs.readFileSync(filePath, 'utf8');

            // Execute via the bridge function
            const { error } = await supabase.rpc('exec_sql', { query: sqlContent });

            if (error) {
                log(`FAILED to apply ${file}: ${error.message}`, true);
                // Handle the case where log file might be out of sync with DB
                if (error.message.includes('already exists')) {
                    log(`HINT: This migration exists in DB but not in your log. Add 'Successfully applied ${file}' to migration_log.md manually to skip it.`, true);
                }
                process.exit(1);
            }

            log(`Successfully applied ${file}`);
        }

        log('All pending migrations applied successfully!');

    } catch (err) {
        log(`Fatal error during migration: ${err.message}`, true);
        process.exit(1);
    }
}

runMigrations();
