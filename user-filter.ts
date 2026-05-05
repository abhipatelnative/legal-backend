/**
 * Filters users before sending notifications.
 * A user receives notifications only if ALL of the following are true:
 *   1. They have at least one active, non-deleted role in user_roles
 *   2. If they exist in employees: is_active=true AND is_deleted=false
 * Users with no role assigned are always skipped.
 */

import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from "./config/credentials";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

/**
 * Returns only the user IDs that should receive notifications.
 * Conditions: has an active role + (not in employees OR employee is active & not deleted).
 */
export async function filterActiveUserIds(userIds: string[], context = "notification"): Promise<string[]> {
    if (!userIds?.length) return [];

    const unique = [...new Set(userIds.filter(Boolean))];

    // 1. Fetch employee status
    const { data: empRows, error: empError } = await supabase
        .from("employees")
        .select("user_id, is_active, is_deleted, company_email")
        .in("user_id", unique);

    if (empError) {
        console.warn(`[UserFilter][${context}] Could not query employees: ${empError.message}. Skipping all for safety.`);
        return [];
    }

    const employeeMap = new Map<string, { is_active: boolean; is_deleted: boolean; company_email: string | null }>();
    for (const row of empRows || []) {
        employeeMap.set(row.user_id, {
            is_active: row.is_active,
            is_deleted: row.is_deleted,
            company_email: row.company_email,
        });
    }

    // 2. Fetch active role assignments
    const { data: roleRows, error: roleError } = await supabase
        .from("user_roles")
        .select("user_id")
        .in("user_id", unique)
        .eq("is_active", true)
        .eq("is_deleted", false);

    if (roleError) {
        console.warn(`[UserFilter][${context}] Could not query user_roles: ${roleError.message}. Skipping all for safety.`);
        return [];
    }

    const usersWithRole = new Set((roleRows || []).map((r: any) => r.user_id));

    const activeIds: string[] = [];
    const details: string[] = [];

    for (const uid of unique) {
        const emp = employeeMap.get(uid);
        const hasRole = usersWithRole.has(uid);
        const label = emp?.company_email ?? uid.substring(0, 8) + "…";

        if (!hasRole) {
            details.push(`${label} [no role] ✗`);
            continue;
        }

        if (emp && (!emp.is_active || emp.is_deleted)) {
            details.push(`${label} [active=${emp.is_active}, deleted=${emp.is_deleted}] ✗`);
            continue;
        }

        activeIds.push(uid);
        const empStatus = emp ? `active=${emp.is_active}, deleted=${emp.is_deleted}` : "non-employee";
        details.push(`${label} [${empStatus}, has role] ✓`);
    }

    const skipped = unique.length - activeIds.length;
    console.log(`[UserFilter][${context}] ${unique.length} requested → ${activeIds.length} eligible, ${skipped} skipped`);
    console.log(`[UserFilter][${context}] ${details.join(" | ")}`);

    return activeIds;
}
