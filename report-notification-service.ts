import dayjs from "dayjs";
import { createClient } from "@supabase/supabase-js";
import { SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "./config/credentials";
import { getEmailTemplateById, substituteTemplateVarsGeneric } from "./email-service";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

export interface ReportDefinition {
    key: string;
    label: string;
    description: string;
    defaultActionUrl: string | null;
    defaultRuleName: string;
}

export interface ReportDateRangePreset {
    key: string;
    label: string;
    group: "quick" | "week" | "month" | "quarter" | "year";
}

export interface ReportDateRange {
    startDate: string;
    endDate: string;
    label: string;
}

export interface ReportNotificationRuleConfig {
    triggerType: string;
    reportKey: string;
    reportDateRangeKey: string;
    subjectTemplate: string;
    messageTemplate: string;
    emailTemplateId: string | null;
}

export interface ReportNotificationPayload {
    title: string;
    message: string;
    htmlBody?: string;
    textBody: string;
    attachments: Array<{
        filename: string;
        content: Buffer;
        contentType: string;
    }>;
}

const REPORT_DEFINITIONS: ReportDefinition[] = [
    {
        key: "daily_absentee_summary",
        label: "Daily Absentee Summary",
        description: "Attendance summary with absent, present, and late counts for the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Daily absentee summary",
    },
    {
        key: "weekly_overtime_report",
        label: "Weekly Overtime Report",
        description: "Overtime hours logged by employees for the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Weekly overtime report",
    },
    {
        key: "monthly_issuance_report",
        label: "Monthly Issuance Report",
        description: "Employee inventory issuance and return activity for the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Monthly issuance report",
    },
    {
        key: "monthly_spending_audit",
        label: "Monthly Spending Report",
        description: "Expense activity for the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Monthly spending audit",
    },
    {
        key: "monthly_net_revenue",
        label: "Monthly Net Revenue Report",
        description: "Service order billing and collections for the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Monthly net revenue report",
    },
    {
        key: "pending_matters_ageing",
        label: "Pending Matters Ageing Report",
        description: "Open service orders and their ageing for the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Pending matters ageing report",
    },
    {
        key: "next_day_court_list",
        label: "Court Hearing List",
        description: "Scheduled hearings within the selected date range.",
        defaultActionUrl: null,
        defaultRuleName: "Next day court list",
    },
    {
        key: "expiring_contracts_30d",
        label: "Expiring Contracts Report",
        description: "Employee contracts ending within the selected period.",
        defaultActionUrl: null,
        defaultRuleName: "Expiring contracts report",
    },
];

const REPORT_DATE_RANGE_PRESETS: ReportDateRangePreset[] = [
    { key: "last_7_days", label: "Last 7 Days", group: "week" },
    { key: "this_week", label: "This Week", group: "week" },
    { key: "last_week", label: "Last Week", group: "week" },
    { key: "last_30_days", label: "Last 30 Days", group: "month" },
    { key: "this_month", label: "Current Month", group: "month" },
    { key: "last_month", label: "Last Month", group: "month" },
    { key: "last_quarter", label: "Last Quarter", group: "quarter" },
    { key: "this_year", label: "This Year", group: "year" },
    { key: "last_year", label: "Last Year", group: "year" },
];

export function getReportDefinitions() {
    return REPORT_DEFINITIONS;
}

export function getReportDateRangePresets() {
    return REPORT_DATE_RANGE_PRESETS;
}

export function getReportDefinitionByKey(reportKey: string): ReportDefinition | undefined {
    return REPORT_DEFINITIONS.find((report) => report.key === reportKey);
}

function getWeekRange(reference: dayjs.Dayjs) {
    const day = reference.day();
    const diffToMonday = day === 0 ? 6 : day - 1;
    const start = reference.subtract(diffToMonday, "day").startOf("day");
    const end = start.add(6, "day").endOf("day");
    return { start, end };
}

function getQuarterRange(reference: dayjs.Dayjs) {
    const month = reference.month();
    const quarterStartMonth = Math.floor(month / 3) * 3;
    const start = reference.month(quarterStartMonth).startOf("month").startOf("day");
    const end = start.add(3, "month").subtract(1, "day").endOf("day");
    return { start, end };
}

export function computeReportDateRange(rangeKey: string, now = dayjs()): ReportDateRange {
    switch (rangeKey) {
        case "last_7_days":
            return {
                startDate: now.subtract(7, "day").startOf("day").format("YYYY-MM-DD"),
                endDate: now.endOf("day").format("YYYY-MM-DD"),
                label: "Last 7 Days",
            };
        case "this_week": {
            const { start, end } = getWeekRange(now);
            return {
                startDate: start.format("YYYY-MM-DD"),
                endDate: end.format("YYYY-MM-DD"),
                label: "This Week",
            };
        }
        case "last_week": {
            const ref = now.subtract(1, "week");
            const { start, end } = getWeekRange(ref);
            return {
                startDate: start.format("YYYY-MM-DD"),
                endDate: end.format("YYYY-MM-DD"),
                label: "Last Week",
            };
        }
        case "last_30_days":
            return {
                startDate: now.subtract(30, "day").startOf("day").format("YYYY-MM-DD"),
                endDate: now.endOf("day").format("YYYY-MM-DD"),
                label: "Last 30 Days",
            };
        case "this_month":
            return {
                startDate: now.startOf("month").format("YYYY-MM-DD"),
                endDate: now.endOf("month").format("YYYY-MM-DD"),
                label: "Current Month",
            };
        case "last_quarter": {
            const ref = now.subtract(3, "month");
            const { start, end } = getQuarterRange(ref);
            return {
                startDate: start.format("YYYY-MM-DD"),
                endDate: end.format("YYYY-MM-DD"),
                label: "Last Quarter",
            };
        }
        case "this_year":
            return {
                startDate: now.startOf("year").format("YYYY-MM-DD"),
                endDate: now.endOf("year").format("YYYY-MM-DD"),
                label: "This Year",
            };
        case "last_year": {
            const ref = now.subtract(1, "year");
            return {
                startDate: ref.startOf("year").format("YYYY-MM-DD"),
                endDate: ref.endOf("year").format("YYYY-MM-DD"),
                label: "Last Year",
            };
        }
        case "last_month":
        default: {
            const ref = now.subtract(1, "month");
            return {
                startDate: ref.startOf("month").format("YYYY-MM-DD"),
                endDate: ref.endOf("month").format("YYYY-MM-DD"),
                label: "Last Month",
            };
        }
    }
}

function formatDisplayDate(date: string) {
    return dayjs(date).format("DD MMM YYYY");
}

function formatCurrency(amount: number | null | undefined) {
    return new Intl.NumberFormat("en-IN", {
        style: "currency",
        currency: "INR",
        maximumFractionDigits: 2,
    }).format(Number(amount || 0));
}

function escapeHtml(value: string | number | null | undefined) {
    return String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

async function renderPdfFromHtml(html: string): Promise<Buffer> {
    // PDF rendering disabled - Playwright dependency removed
    // To re-enable, install a PDF library like puppeteer or pdfkit
    throw new Error("PDF rendering is currently disabled. Please install a PDF library to enable this feature.");
}

function buildBaseReportHtml(title: string, range: ReportDateRange, headers: string[], rows: string, emptyMessage: string) {
    const bodyRows = rows || `
        <tr>
            <td colspan="${headers.length}" style="padding: 18px; text-align: center; color: #6b7280;">
                ${escapeHtml(emptyMessage)}
            </td>
        </tr>
    `;

    return `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <style>
        body { font-family: Arial, sans-serif; color: #1f2937; margin: 0; }
        .page { padding: 0; }
        .header { margin-bottom: 18px; border-bottom: 2px solid #111827; padding-bottom: 10px; }
        .title { font-size: 24px; font-weight: 700; margin: 0 0 4px; }
        .meta { font-size: 12px; color: #4b5563; margin: 0; }
        table { width: 100%; border-collapse: collapse; font-size: 12px; }
        th { text-align: left; padding: 10px; background: #f3f4f6; border-bottom: 1px solid #d1d5db; }
        td { padding: 10px; border-bottom: 1px solid #e5e7eb; vertical-align: top; }
        .footer { margin-top: 18px; font-size: 11px; color: #6b7280; }
        .muted { color: #6b7280; }
    </style>
</head>
<body>
    <div class="page">
        <div class="header">
            <h1 class="title">${escapeHtml(title)}</h1>
            <p class="meta">${escapeHtml(range.label)} | ${escapeHtml(formatDisplayDate(range.startDate))} to ${escapeHtml(formatDisplayDate(range.endDate))}</p>
            <p class="meta">Generated on ${escapeHtml(dayjs().format("DD MMM YYYY HH:mm"))}</p>
        </div>
        <table>
            <thead>
                <tr>${headers.map((header) => `<th>${escapeHtml(header)}</th>`).join("")}</tr>
            </thead>
            <tbody>${bodyRows}</tbody>
        </table>
        <p class="footer">This report was generated automatically by LegalPrime.</p>
    </div>
</body>
</html>`;
}

async function buildIssuanceReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("employee_inventory_summary")
        .select("issue_number, issue_date, employee_name, status, total_quantity, total_returned")
        .gte("issue_date", range.startDate)
        .lte("issue_date", range.endDate)
        .order("issue_date", { ascending: false });

    if (error) throw new Error(`Failed to load issuance report data: ${error.message}`);

    const rows = (data ?? []).map((row: any) => `
        <tr>
            <td>${escapeHtml(row.issue_number || "N/A")}</td>
            <td>${escapeHtml(formatDisplayDate(row.issue_date))}</td>
            <td>${escapeHtml(row.employee_name || "N/A")}</td>
            <td>${escapeHtml(row.status || "N/A")}</td>
            <td>${escapeHtml(row.total_quantity ?? 0)}</td>
            <td>${escapeHtml(row.total_returned ?? 0)}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Monthly Issuance Report",
        range,
        ["Issue #", "Issue Date", "Employee", "Status", "Issued Qty", "Returned Qty"],
        rows,
        "No issuance records were found for this date range."
    );
}

async function buildDailyAbsenteeSummaryReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("attendance_records")
        .select("attendance_date, status, late_arrival_minutes")
        .gte("attendance_date", range.startDate)
        .lte("attendance_date", range.endDate)
        .eq("is_active", true)
        .eq("is_deleted", false)
        .order("attendance_date", { ascending: true });

    if (error) throw new Error(`Failed to load absentee summary data: ${error.message}`);

    const grouped = new Map<string, { absent: number; present: number; late: number; total: number }>();
    (data ?? []).forEach((row: any) => {
        const dateKey = row.attendance_date;
        const current = grouped.get(dateKey) ?? { absent: 0, present: 0, late: 0, total: 0 };
        current.total += 1;
        if (row.status === "absent") current.absent += 1;
        if (row.status === "present") current.present += 1;
        if (Number(row.late_arrival_minutes || 0) > 0) current.late += 1;
        grouped.set(dateKey, current);
    });

    const rows = Array.from(grouped.entries()).map(([dateKey, summary]) => `
        <tr>
            <td>${escapeHtml(formatDisplayDate(dateKey))}</td>
            <td>${escapeHtml(summary.total)}</td>
            <td>${escapeHtml(summary.present)}</td>
            <td>${escapeHtml(summary.absent)}</td>
            <td>${escapeHtml(summary.late)}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Daily Absentee Summary",
        range,
        ["Date", "Total Marked", "Present", "Absent", "Late"],
        rows,
        "No attendance records were found for this date range."
    );
}

async function buildWeeklyOvertimeReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("attendance_records")
        .select("attendance_date, overtime_hours, user_profile_id")
        .gte("attendance_date", range.startDate)
        .lte("attendance_date", range.endDate)
        .gt("overtime_hours", 0)
        .eq("is_active", true)
        .eq("is_deleted", false)
        .order("attendance_date", { ascending: false });

    if (error) throw new Error(`Failed to load overtime report data: ${error.message}`);

    const profileIds = [...new Set((data ?? []).map((row: any) => row.user_profile_id).filter(Boolean))];
    let profileMap = new Map<string, string>();
    if (profileIds.length) {
        const { data: profiles, error: profileError } = await supabase
            .from("user_profiles")
            .select("id, first_name, last_name")
            .in("id", profileIds)
            .eq("is_active", true)
            .eq("is_deleted", false);

        if (profileError) throw new Error(`Failed to load overtime report user profiles: ${profileError.message}`);
        profileMap = new Map((profiles ?? []).map((profile: any) => [
            profile.id,
            [profile.first_name, profile.last_name].filter(Boolean).join(" ").trim() || "Unknown",
        ]));
    }

    const rows = (data ?? []).map((row: any) => `
        <tr>
            <td>${escapeHtml(formatDisplayDate(row.attendance_date))}</td>
            <td>${escapeHtml(profileMap.get(row.user_profile_id) || "Unknown")}</td>
            <td>${escapeHtml(Number(row.overtime_hours || 0).toFixed(2))}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Weekly Overtime Report",
        range,
        ["Attendance Date", "Employee", "Overtime Hours"],
        rows,
        "No overtime records were found for this date range."
    );
}

async function buildSpendingReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("expenses")
        .select("expense_number, expense_date, description, vendor_name, total_amount, status")
        .gte("expense_date", range.startDate)
        .lte("expense_date", range.endDate)
        .order("expense_date", { ascending: false });

    if (error) throw new Error(`Failed to load spending report data: ${error.message}`);

    const rows = (data ?? []).map((row: any) => `
        <tr>
            <td>${escapeHtml(row.expense_number || "N/A")}</td>
            <td>${escapeHtml(formatDisplayDate(row.expense_date))}</td>
            <td>${escapeHtml(row.vendor_name || "N/A")}</td>
            <td>${escapeHtml(row.description || "-")}</td>
            <td>${escapeHtml(formatCurrency(row.total_amount))}</td>
            <td>${escapeHtml(row.status || "N/A")}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Monthly Spending Report",
        range,
        ["Expense #", "Expense Date", "Vendor", "Description", "Total", "Status"],
        rows,
        "No expense records were found for this date range."
    );
}

async function buildRevenueReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("service_orders")
        .select("order_number, created_at, status, total_amount, paid_amount, balance_amount")
        .gte("created_at", `${range.startDate}T00:00:00`)
        .lte("created_at", `${range.endDate}T23:59:59.999`)
        .order("created_at", { ascending: false });

    if (error) throw new Error(`Failed to load net revenue report data: ${error.message}`);

    const rows = (data ?? []).map((row: any) => `
        <tr>
            <td>${escapeHtml(row.order_number || "N/A")}</td>
            <td>${escapeHtml(formatDisplayDate(String(row.created_at).slice(0, 10)))}</td>
            <td>${escapeHtml(row.status || "N/A")}</td>
            <td>${escapeHtml(formatCurrency(row.total_amount))}</td>
            <td>${escapeHtml(formatCurrency(row.paid_amount))}</td>
            <td>${escapeHtml(formatCurrency(row.balance_amount))}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Monthly Net Revenue Report",
        range,
        ["Order #", "Created On", "Status", "Total", "Paid", "Balance"],
        rows,
        "No service orders were found for this date range."
    );
}

async function buildPendingMattersAgeingReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("service_orders")
        .select("order_number, created_at, status, total_amount, balance_amount")
        .gte("created_at", `${range.startDate}T00:00:00`)
        .lte("created_at", `${range.endDate}T23:59:59.999`)
        .not("status", "in", '("Completed","Closed","Cancelled")')
        .order("created_at", { ascending: true });

    if (error) throw new Error(`Failed to load pending matters report data: ${error.message}`);

    const rows = (data ?? []).map((row: any) => {
        const createdDate = String(row.created_at).slice(0, 10);
        const ageDays = dayjs().startOf("day").diff(dayjs(createdDate).startOf("day"), "day");
        return `
            <tr>
                <td>${escapeHtml(row.order_number || "N/A")}</td>
                <td>${escapeHtml(formatDisplayDate(createdDate))}</td>
                <td>${escapeHtml(row.status || "N/A")}</td>
                <td>${escapeHtml(ageDays)}</td>
                <td>${escapeHtml(formatCurrency(row.total_amount))}</td>
                <td>${escapeHtml(formatCurrency(row.balance_amount))}</td>
            </tr>
        `;
    }).join("");

    return buildBaseReportHtml(
        "Pending Matters Ageing Report",
        range,
        ["Order #", "Created On", "Status", "Age (Days)", "Total", "Balance"],
        rows,
        "No pending service orders were found for this date range."
    );
}

async function buildCourtListReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("case_hearings")
        .select(`
            hearing_date,
            hearing_time,
            status,
            purpose,
            courts(court_name),
            order_cases(case_title, service_orders(order_number))
        `)
        .gte("hearing_date", range.startDate)
        .lte("hearing_date", range.endDate)
        .order("hearing_date", { ascending: true })
        .order("hearing_time", { ascending: true });

    if (error) throw new Error(`Failed to load court hearing report data: ${error.message}`);

    const rows = (data ?? []).map((row: any) => `
        <tr>
            <td>${escapeHtml(formatDisplayDate(row.hearing_date))}</td>
            <td>${escapeHtml(row.hearing_time || "-")}</td>
            <td>${escapeHtml(row.order_cases?.service_orders?.order_number || "N/A")}</td>
            <td>${escapeHtml(row.order_cases?.case_title || "N/A")}</td>
            <td>${escapeHtml(row.courts?.court_name || "N/A")}</td>
            <td>${escapeHtml(row.purpose || "-")}</td>
            <td>${escapeHtml(row.status || "N/A")}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Court Hearing List",
        range,
        ["Hearing Date", "Time", "Order #", "Case", "Court", "Purpose", "Status"],
        rows,
        "No hearings were found for this date range."
    );
}

async function buildExpiringContractsReport(range: ReportDateRange) {
    const { data, error } = await supabase
        .from("contracts")
        .select("employee_id, start_date, end_date, status")
        .gte("end_date", range.startDate)
        .lte("end_date", range.endDate)
        .eq("is_active", true)
        .eq("is_deleted", false)
        .order("end_date", { ascending: true });

    if (error) throw new Error(`Failed to load expiring contracts report data: ${error.message}`);

    const employeeIds = [...new Set((data ?? []).map((row: any) => row.employee_id).filter(Boolean))];
    let employeeMap = new Map<string, string>();
    if (employeeIds.length) {
        const { data: employees, error: employeeError } = await supabase
            .from("employees")
            .select("id, user_id")
            .in("id", employeeIds)
            .eq("is_active", true)
            .eq("is_deleted", false);

        if (employeeError) throw new Error(`Failed to load employees for contracts report: ${employeeError.message}`);

        const userIds = [...new Set((employees ?? []).map((employee: any) => employee.user_id).filter(Boolean))];
        const { data: profiles, error: profileError } = await supabase
            .from("user_profiles")
            .select("id, first_name, last_name")
            .in("id", userIds)
            .eq("is_active", true)
            .eq("is_deleted", false);

        if (profileError) throw new Error(`Failed to load user profiles for contracts report: ${profileError.message}`);

        const profileMap = new Map((profiles ?? []).map((profile: any) => [
            profile.id,
            [profile.first_name, profile.last_name].filter(Boolean).join(" ").trim() || "Unknown",
        ]));

        employeeMap = new Map((employees ?? []).map((employee: any) => [
            employee.id,
            profileMap.get(employee.user_id) || "Unknown",
        ]));
    }

    const rows = (data ?? []).map((row: any) => `
        <tr>
            <td>${escapeHtml(employeeMap.get(row.employee_id) || "Unknown")}</td>
            <td>${escapeHtml(formatDisplayDate(row.start_date))}</td>
            <td>${escapeHtml(formatDisplayDate(row.end_date))}</td>
            <td>${escapeHtml(row.status || "N/A")}</td>
        </tr>
    `).join("");

    return buildBaseReportHtml(
        "Expiring Contracts Report",
        range,
        ["Employee", "Start Date", "End Date", "Status"],
        rows,
        "No contracts were found with end dates in this range."
    );
}

async function buildReportHtml(reportKey: string, range: ReportDateRange) {
    switch (reportKey) {
        case "daily_absentee_summary":
            return buildDailyAbsenteeSummaryReport(range);
        case "weekly_overtime_report":
            return buildWeeklyOvertimeReport(range);
        case "monthly_issuance_report":
            return buildIssuanceReport(range);
        case "monthly_spending_audit":
            return buildSpendingReport(range);
        case "monthly_net_revenue":
            return buildRevenueReport(range);
        case "pending_matters_ageing":
            return buildPendingMattersAgeingReport(range);
        case "next_day_court_list":
            return buildCourtListReport(range);
        case "expiring_contracts_30d":
            return buildExpiringContractsReport(range);
        default:
            throw new Error(`Unsupported report key: ${reportKey}`);
    }
}

export async function prepareReportNotification(rule: ReportNotificationRuleConfig): Promise<ReportNotificationPayload> {
    const definition = getReportDefinitionByKey(rule.reportKey);
    if (!definition) {
        throw new Error(`Unknown report definition for key "${rule.reportKey}"`);
    }

    const range = computeReportDateRange(rule.reportDateRangeKey || "last_month");
    const variables = {
        report_name: definition.label,
        range_label: range.label,
        start_date: formatDisplayDate(range.startDate),
        end_date: formatDisplayDate(range.endDate),
    };

    const title = substituteTemplateVarsGeneric(rule.subjectTemplate || `${definition.label} - {{range_label}}`, variables);
    const message = substituteTemplateVarsGeneric(
        rule.messageTemplate || `Your ${definition.label.toLowerCase()} for {{range_label}} is attached.`,
        variables
    );

    const reportHtml = await buildReportHtml(rule.reportKey, range);
    const pdfBuffer = await renderPdfFromHtml(reportHtml);

    let htmlBody: string | undefined;
    if (rule.emailTemplateId) {
        const template = await getEmailTemplateById(rule.emailTemplateId);
        if (template) {
            htmlBody = substituteTemplateVarsGeneric(template.body, {
                title,
                message,
                ...variables,
            });
        }
    }

    return {
        title,
        message,
        htmlBody,
        textBody: `${message}\n\nPeriod: ${variables.start_date} to ${variables.end_date}`,
        attachments: [
            {
                filename: `${definition.label.replace(/\s+/g, "_")}_${dayjs(range.startDate).format("YYYY_MM")}.pdf`,
                content: pdfBuffer,
                contentType: "application/pdf",
            },
        ],
    };
}
