/**
 * Resolve phone numbers for SMS / WhatsApp.
 * Prefer employees.work_phone; fallback to user_profiles.phone; if neither, user is skipped (no send).
 */

import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } from "./config/credentials";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

/** Strip spaces/dashes; if no leading + and defaultCountryCode provided (e.g. "91"), prefix +{code} */
export function normalizePhoneE164(raw: string, defaultCountryCode?: string): string | null {
    const s = (raw || "").trim().replace(/[\s\-()]/g, "");
    if (!s) return null;
    if (s.startsWith("+")) return s;
    const digits = s.replace(/\D/g, "");
    if (!digits) return null;
    if (defaultCountryCode) {
        const cc = defaultCountryCode.replace(/\D/g, "");
        return `+${cc}${digits}`;
    }
    return `+${digits}`;
}

export async function getWorkPhonesForUserIds(
    userIds: string[],
    defaultCountryCode?: string
): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    if (!userIds?.length) return map;

    // 1. Prefer employees.work_phone
    const { data: empData, error: empError } = await supabase
        .from("employees")
        .select("user_id, work_phone")
        .in("user_id", userIds)
        .eq("is_deleted", false);

    if (empError) {
        console.error("[messaging-recipients] getWorkPhonesForUserIds (employees):", empError);
    } else {
        for (const row of empData || []) {
            const uid = (row as any).user_id as string;
            const phone = (row as any).work_phone as string | null;
            const norm = phone ? normalizePhoneE164(phone, defaultCountryCode) : null;
            if (uid && norm) map.set(uid, norm);
        }
    }

    // 2. Fallback: user_profiles.phone for users still without a number
    const missing = userIds.filter((id) => !map.has(id));
    if (missing.length === 0) return map;

    const { data: profileData, error: profileError } = await supabase
        .from("user_profiles")
        .select("id, phone")
        .in("id", missing);

    if (profileError) {
        console.error("[messaging-recipients] getWorkPhonesForUserIds (user_profiles):", profileError);
        return map;
    }

    for (const row of profileData || []) {
        const uid = (row as any).id as string;
        const phone = (row as any).phone as string | null;
        const norm = phone ? normalizePhoneE164(phone, defaultCountryCode) : null;
        if (uid && norm) map.set(uid, norm);
    }

    // 3. Users still not in map: no notification sent (skip)
    const stillMissing = userIds.filter((id) => !map.has(id));
    if (stillMissing.length > 0) {
        console.warn(`[messaging-recipients] No phone found for ${stillMissing.length} user(s): ${stillMissing.join(", ")}`);
    }
    return map;
}
