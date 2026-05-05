-- COMMON LIVE MIGRATION (manual + idempotent)
-- Keep updating this same file for each live release.
-- Safe to run multiple times: all writes use upsert/reactivation logic.
-- Source of truth: PERMISSION_AUDIT_REPORTS_2026-03-06/module_page_permission_matrix.md
--
-- NOTE:
-- "update" permission in UI/business terms maps to "can_edit" in DB schema.
-- Role-permission assignment is additive for Admin and Sales Partner only.

BEGIN;

-- 1) Permission seeds (additive + idempotent)
-- Existing permission rows are preserved. Missing names are inserted.
-- Existing names are only reactivated (no CRUD/module/description overwrite).
WITH permission_seed AS (
  SELECT *
  FROM (
    VALUES
      -- permission_name, module_key, can_view, can_add, can_edit, can_delete, description
      (
        'Case Matter Clients (View)',
        'case_matter_clients',
        true,
        false,
        false,
        false,
        'View access for Case Matter > Clients page'
      ),
      (
        'Case Matter Clients (Add)',
        'case_matter_clients',
        false,
        true,
        false,
        false,
        'Add access for Case Matter > Clients page'
      ),
      (
        'Case Matter Clients (Edit)',
        'case_matter_clients',
        false,
        false,
        true,
        false,
        'Edit access for Case Matter > Clients page'
      ),
      (
        'Case Matter Clients (Delete)',
        'case_matter_clients',
        false,
        false,
        false,
        true,
        'Delete access for Case Matter > Clients page'
      ),
      (
        'Service Orders (View)',
        'service_orders',
        true,
        false,
        false,
        false,
        'View access for Service Orders pages'
      ),
      (
        'Service Orders (Add)',
        'service_orders',
        false,
        true,
        false,
        false,
        'Add access for Service Orders pages'
      ),
      (
        'Service Orders (Edit)',
        'service_orders',
        false,
        false,
        true,
        false,
        'Edit access for Service Orders pages'
      ),
      (
        'Service Orders (Delete)',
        'service_orders',
        false,
        false,
        false,
        true,
        'Delete access for Service Orders pages'
      ),
      (
        'Case Matter Hearings (View)',
        'case_matter_hearingss',
        true,
        false,
        false,
        false,
        'View access for Case Matter > Hearings page'
      ),
      (
        'Case Matter Hearings (Add)',
        'case_matter_hearingss',
        false,
        true,
        false,
        false,
        'Add access for Case Matter > Hearings page'
      ),
      (
        'Case Matter Hearings (Edit)',
        'case_matter_hearingss',
        false,
        false,
        true,
        false,
        'Edit access for Case Matter > Hearings page'
      ),
      (
        'Case Matter Hearings (Delete)',
        'case_matter_hearingss',
        false,
        false,
        false,
        true,
        'Delete access for Case Matter > Hearings page'
      ),
      (
        'Case Matter Tasks (View)',
        'case_matter_tasks',
        true,
        false,
        false,
        false,
        'View access for Case Matter > Tasks page'
      ),
      (
        'Case Matter Tasks (Add)',
        'case_matter_tasks',
        false,
        true,
        false,
        false,
        'Add access for Case Matter > Tasks page'
      ),
      (
        'Case Matter Tasks (Edit)',
        'case_matter_tasks',
        false,
        false,
        true,
        false,
        'Edit access for Case Matter > Tasks page'
      ),
      (
        'Case Matter Tasks (Delete)',
        'case_matter_tasks',
        false,
        false,
        false,
        true,
        'Delete access for Case Matter > Tasks page'
      ),
      (
        'Calendar (View)',
        'calendar',
        true,
        false,
        false,
        false,
        'View access for Calendar page'
      ),
      (
        'Calendar (Add)',
        'calendar',
        false,
        true,
        false,
        false,
        'Add access for Calendar page'
      ),
      (
        'Calendar (Edit)',
        'calendar',
        false,
        false,
        true,
        false,
        'Edit access for Calendar page'
      ),
      (
        'Calendar (Delete)',
        'calendar',
        false,
        false,
        false,
        true,
        'Delete access for Calendar page'
      ),
      (
        'Agent Payouts (View)',
        'agent_payouts',
        true,
        false,
        false,
        false,
        'View access for Case Matter > Agent Payments page'
      ),
      (
        'Agent Payouts (Add)',
        'agent_payouts',
        false,
        true,
        false,
        false,
        'Add access for Case Matter > Agent Payments page'
      ),
      (
        'Agent Payouts (Edit)',
        'agent_payouts',
        false,
        false,
        true,
        false,
        'Edit access for Case Matter > Agent Payments page'
      ),
      (
        'Agent Payouts (Delete)',
        'agent_payouts',
        false,
        false,
        false,
        true,
        'Delete access for Case Matter > Agent Payments page'
      ),
      (
        'Payroll (View)',
        'payroll',
        true,
        false,
        false,
        false,
        'View access for Payroll page'
      ),
      (
        'Payroll (Add)',
        'payroll',
        false,
        true,
        false,
        false,
        'Add access for Payroll page'
      ),
      (
        'Payroll (Edit)',
        'payroll',
        false,
        false,
        true,
        false,
        'Edit access for Payroll page'
      ),
      (
        'Payroll (Delete)',
        'payroll',
        false,
        false,
        false,
        true,
        'Delete access for Payroll page'
      ),
      (
        'Payroll Preview Calculation (Edit)',
        'payroll',
        false,
        false,
        true,
        false,
        'Edit access for Payroll Preview Calculation action'
      ),
      (
        'Payroll Finalize Period (Edit)',
        'payroll',
        false,
        false,
        true,
        false,
        'Edit access for Payroll Finalize Period action'
      ),
      (
        'Payroll Mark as Paid (Edit)',
        'payroll',
        false,
        false,
        true,
        false,
        'Edit access for Payroll Mark as Paid action'
      ),
      (
        'Payroll Visibility Toggle (Edit)',
        'payroll',
        false,
        false,
        true,
        false,
        'Edit access for Payroll Visibility Toggle action'
      ),
      (
        'Payroll Periods (View)',
        'payroll_periods',
        true,
        false,
        false,
        false,
        'View access for Payroll Periods page'
      ),
      (
        'Payroll Periods (Add)',
        'payroll_periods',
        false,
        true,
        false,
        false,
        'Add access for Payroll Periods page'
      ),
      (
        'Payroll Periods (Edit)',
        'payroll_periods',
        false,
        false,
        true,
        false,
        'Edit access for Payroll Periods page'
      ),
      (
        'Payroll Periods (Delete)',
        'payroll_periods',
        false,
        false,
        false,
        true,
        'Delete access for Payroll Periods page'
      ),
      (
        'Punch Requests (View)',
        'punch_edit_requests',
        true,
        false,
        false,
        false,
        'View access for Punch Requests page'
      ),
      (
        'Punch Requests (Add)',
        'punch_edit_requests',
        false,
        true,
        false,
        false,
        'Add access for Punch Requests page'
      ),
      (
        'Punch Requests (Edit)',
        'punch_edit_requests',
        false,
        false,
        true,
        false,
        'Edit access for Punch Requests page'
      ),
      (
        'Punch Requests (Delete)',
        'punch_edit_requests',
        false,
        false,
        false,
        true,
        'Delete access for Punch Requests page'
      ),
      (
        'Manual Attendance (View)',
        'manually_attendance_list',
        true,
        false,
        false,
        false,
        'View access for Manual Attendance page'
      ),
      (
        'Manual Attendance (Add)',
        'manually_attendance_list',
        false,
        true,
        false,
        false,
        'Add access for Manual Attendance page'
      ),
      (
        'Manual Attendance (Edit)',
        'manually_attendance_list',
        false,
        false,
        true,
        false,
        'Edit access for Manual Attendance page'
      ),
      (
        'Manual Attendance (Delete)',
        'manually_attendance_list',
        false,
        false,
        false,
        true,
        'Delete access for Manual Attendance page'
      ),
      (
        'Attendance (View)',
        'attendance',
        true,
        false,
        false,
        false,
        'View access for Attendance page'
      ),
      (
        'Attendance (Add)',
        'attendance',
        false,
        true,
        false,
        false,
        'Add access for Attendance page'
      ),
      (
        'Attendance (Edit)',
        'attendance',
        false,
        false,
        true,
        false,
        'Edit access for Attendance page'
      ),
      (
        'Attendance (Delete)',
        'attendance',
        false,
        false,
        false,
        true,
        'Delete access for Attendance page'
      ),
      (
        'PL Earning Days (View)',
        'pl_earning_days',
        true,
        false,
        false,
        false,
        'View access for PL Earning Days page'
      ),
      (
        'PL Earning Days (Add)',
        'pl_earning_days',
        false,
        true,
        false,
        false,
        'Add access for PL Earning Days page'
      ),
      (
        'PL Earning Days (Edit)',
        'pl_earning_days',
        false,
        false,
        true,
        false,
        'Edit access for PL Earning Days page'
      ),
      (
        'PL Earning Days (Delete)',
        'pl_earning_days',
        false,
        false,
        false,
        true,
        'Delete access for PL Earning Days page'
      ),
      (
        'HR Approvals (View)',
        'hr_approvals',
        true,
        false,
        false,
        false,
        'View access for HR Approvals page'
      ),
      (
        'HR Approvals (Add)',
        'hr_approvals',
        false,
        true,
        false,
        false,
        'Add access for HR Approvals page'
      ),
      (
        'HR Approvals (Edit)',
        'hr_approvals',
        false,
        false,
        true,
        false,
        'Edit access for HR Approvals page'
      ),
      (
        'HR Approvals (Delete)',
        'hr_approvals',
        false,
        false,
        false,
        true,
        'Delete access for HR Approvals page'
      ),
      (
        'Work Penalties (View)',
        'notice_penalties',
        true,
        false,
        false,
        false,
        'View access for Work Penalties pages'
      ),
      (
        'Work Penalties (Add)',
        'notice_penalties',
        false,
        true,
        false,
        false,
        'Add access for Work Penalties pages'
      ),
      (
        'Work Penalties (Edit)',
        'notice_penalties',
        false,
        false,
        true,
        false,
        'Edit access for Work Penalties pages'
      ),
      (
        'Work Penalties (Delete)',
        'notice_penalties',
        false,
        false,
        false,
        true,
        'Delete access for Work Penalties pages'
      ),
      (
        'Advance Salary (View)',
        'financial_management',
        true,
        false,
        false,
        false,
        'View access for Advance Salary page'
      ),
      (
        'Advance Salary (Add)',
        'financial_management',
        false,
        true,
        false,
        false,
        'Add access for Advance Salary page'
      ),
      (
        'Advance Salary (Edit)',
        'financial_management',
        false,
        false,
        true,
        false,
        'Edit access for Advance Salary page'
      ),
      (
        'Advance Salary (Delete)',
        'financial_management',
        false,
        false,
        false,
        true,
        'Delete access for Advance Salary page'
      ),
      (
        'Loans (View)',
        'employee_loans',
        true,
        false,
        false,
        false,
        'View access for Loans page'
      ),
      (
        'Loans (Add)',
        'employee_loans',
        false,
        true,
        false,
        false,
        'Add access for Loans page'
      ),
      (
        'Loans (Edit)',
        'employee_loans',
        false,
        false,
        true,
        false,
        'Edit access for Loans page'
      ),
      (
        'Loans (Delete)',
        'employee_loans',
        false,
        false,
        false,
        true,
        'Delete access for Loans page'
      ),
      (
        'Security Deposits (View)',
        'security_deposits',
        true,
        false,
        false,
        false,
        'View access for Security Deposits page'
      ),
      (
        'Security Deposits (Add)',
        'security_deposits',
        false,
        true,
        false,
        false,
        'Add access for Security Deposits page'
      ),
      (
        'Security Deposits (Edit)',
        'security_deposits',
        false,
        false,
        true,
        false,
        'Edit access for Security Deposits page'
      ),
      (
        'Security Deposits (Delete)',
        'security_deposits',
        false,
        false,
        false,
        true,
        'Delete access for Security Deposits page'
      ),
      (
        'Provident Fund (View)',
        'provident_fund',
        true,
        false,
        false,
        false,
        'View access for Provident Fund page'
      ),
      (
        'Provident Fund (Add)',
        'provident_fund',
        false,
        true,
        false,
        false,
        'Add access for Provident Fund page'
      ),
      (
        'Provident Fund (Edit)',
        'provident_fund',
        false,
        false,
        true,
        false,
        'Edit access for Provident Fund page'
      ),
      (
        'Provident Fund (Delete)',
        'provident_fund',
        false,
        false,
        false,
        true,
        'Delete access for Provident Fund page'
      ),
      (
        'Inventory List (View)',
        'inventory_manage',
        true,
        false,
        false,
        false,
        'View access for Inventory Management page'
      ),
      (
        'Inventory List (Add)',
        'inventory_manage',
        false,
        true,
        false,
        false,
        'Add access for Inventory Management page'
      ),
      (
        'Inventory List (Edit)',
        'inventory_manage',
        false,
        false,
        true,
        false,
        'Edit access for Inventory Management page'
      ),
      (
        'Inventory List (Delete)',
        'inventory_manage',
        false,
        false,
        false,
        true,
        'Delete access for Inventory Management page'
      ),
      (
        'Expense Categories (View)',
        'expenses_manage_categories',
        true,
        false,
        false,
        false,
        'View access for Expense Categories page'
      ),
      (
        'Expense Categories (Add)',
        'expenses_manage_categories',
        false,
        true,
        false,
        false,
        'Add access for Expense Categories page'
      ),
      (
        'Expense Categories (Edit)',
        'expenses_manage_categories',
        false,
        false,
        true,
        false,
        'Edit access for Expense Categories page'
      ),
      (
        'Expense Categories (Delete)',
        'expenses_manage_categories',
        false,
        false,
        false,
        true,
        'Delete access for Expense Categories page'
      ),
      (
        'Expenses (View)',
        'expenses_view',
        true,
        false,
        false,
        false,
        'View access for Expenses pages'
      ),
      (
        'Expenses (Add)',
        'expenses_view',
        false,
        true,
        false,
        false,
        'Add access for Expenses pages'
      ),
      (
        'Expenses (Edit)',
        'expenses_view',
        false,
        false,
        true,
        false,
        'Edit access for Expenses pages'
      ),
      (
        'Expenses (Delete)',
        'expenses_view',
        false,
        false,
        false,
        true,
        'Delete access for Expenses pages'
      ),
      (
        'Payments (View)',
        'expenses_pay',
        true,
        false,
        false,
        false,
        'View access for Expense Payments page'
      ),
      (
        'Payments (Add)',
        'expenses_pay',
        false,
        true,
        false,
        false,
        'Add access for Expense Payments page'
      ),
      (
        'Payments (Edit)',
        'expenses_pay',
        false,
        false,
        true,
        false,
        'Edit access for Expense Payments page'
      ),
      (
        'Payments (Delete)',
        'expenses_pay',
        false,
        false,
        false,
        true,
        'Delete access for Expense Payments page'
      ),
      (
        'Leaves (View)',
        'leaves',
        true,
        false,
        false,
        false,
        'View access for Leaves page'
      ),
      (
        'Leaves (Add)',
        'leaves',
        false,
        true,
        false,
        false,
        'Add/apply access for Leaves page'
      ),
      (
        'Leaves (Edit)',
        'leaves',
        false,
        false,
        true,
        false,
        'Edit/approve access for Leaves page'
      ),
      (
        'Leaves (Delete)',
        'leaves',
        false,
        false,
        false,
        true,
        'Cancel/delete access for Leaves page'
      ),
      (
        'Leaves All Employees (View)',
        'leaves_all_employees',
        true,
        false,
        false,
        false,
        'View all employees leave requests'
      ),
      (
        'Leaves All Employees (Add)',
        'leaves_all_employees',
        false,
        true,
        false,
        false,
        'Add leaves for employees'
      ),
      (
        'Leaves All Employees (Edit)',
        'leaves_all_employees',
        false,
        false,
        true,
        false,
        'Edit all employees leave requests'
      ),
      (
        'Leaves All Employees (Delete)',
        'leaves_all_employees',
        false,
        false,
        false,
        true,
        'Delete/cancel all employees leave requests'
      ),
      (
        'Inquiries (View)',
        'crm_inquiries',
        true,
        false,
        false,
        false,
        'View access for CRM > Inquiries page'
      ),
      (
        'Inquiries (Add)',
        'crm_inquiries',
        false,
        true,
        false,
        false,
        'Add access for CRM > Inquiries page'
      ),
      (
        'Inquiries (Edit)',
        'crm_inquiries',
        false,
        false,
        true,
        false,
        'Edit access for CRM > Inquiries page'
      ),
      (
        'Inquiries (Delete)',
        'crm_inquiries',
        false,
        false,
        false,
        true,
        'Delete access for CRM > Inquiries page'
      ),
      (
        'Leads (View)',
        'crm_leads',
        true,
        false,
        false,
        false,
        'View access for CRM > Leads page'
      ),
      (
        'Leads (Add)',
        'crm_leads',
        false,
        true,
        false,
        false,
        'Add access for CRM > Leads page'
      ),
      (
        'Leads (Edit)',
        'crm_leads',
        false,
        false,
        true,
        false,
        'Edit access for CRM > Leads page'
      ),
      (
        'Leads (Delete)',
        'crm_leads',
        false,
        false,
        false,
        true,
        'Delete access for CRM > Leads page'
      ),
      (
        'Employees (View)',
        'employees',
        true,
        false,
        false,
        false,
        'View access for Employees page'
      ),
      (
        'Employees (Add)',
        'employees',
        false,
        true,
        false,
        false,
        'Add access for Employees page'
      ),
      (
        'Employees (Edit)',
        'employees',
        false,
        false,
        true,
        false,
        'Edit access for Employees page'
      ),
      (
        'Employees (Delete)',
        'employees',
        false,
        false,
        false,
        true,
        'Delete access for Employees page'
      ),
      (
        'Employee Directory (View)',
        'employee_directory',
        true,
        false,
        false,
        false,
        'View access for Employee Directory page'
      ),
      (
        'Employee Directory (Add)',
        'employee_directory',
        false,
        true,
        false,
        false,
        'Add access for Employee Directory page'
      ),
      (
        'Employee Directory (Edit)',
        'employee_directory',
        false,
        false,
        true,
        false,
        'Edit access for Employee Directory page'
      ),
      (
        'Employee Directory (Delete)',
        'employee_directory',
        false,
        false,
        false,
        true,
        'Delete access for Employee Directory page'
      ),
      (
        'Contracts (View)',
        'contracts',
        true,
        false,
        false,
        false,
        'View access for Contracts pages'
      ),
      (
        'Contracts (Add)',
        'contracts',
        false,
        true,
        false,
        false,
        'Add access for Contracts pages'
      ),
      (
        'Contracts (Edit)',
        'contracts',
        false,
        false,
        true,
        false,
        'Edit access for Contracts pages'
      ),
      (
        'Contracts (Delete)',
        'contracts',
        false,
        false,
        false,
        true,
        'Delete access for Contracts pages'
      ),
      (
        'Reports (View)',
        'reports_payroll',
        true,
        false,
        false,
        false,
        'View access for Reports pages'
      ),
      (
        'Notification Center (View)',
        'notifications_center',
        true,
        false,
        false,
        false,
        'View access for Notification Center page'
      ),
      (
        'Notification Center (Add)',
        'notifications_center',
        false,
        true,
        false,
        false,
        'Add access for Notification Center page'
      ),
      (
        'Notification Center (Edit)',
        'notifications_center',
        false,
        false,
        true,
        false,
        'Edit access for Notification Center page'
      ),
      (
        'Notification Center (Delete)',
        'notifications_center',
        false,
        false,
        false,
        true,
        'Delete access for Notification Center page'
      ),
      (
        'Notifications Master (View)',
        'notifications_master',
        true,
        false,
        false,
        false,
        'View access for Notifications Master page'
      ),
      (
        'Notifications Master (Add)',
        'notifications_master',
        false,
        true,
        false,
        false,
        'Add access for Notifications Master page'
      ),
      (
        'Notifications Master (Edit)',
        'notifications_master',
        false,
        false,
        true,
        false,
        'Edit access for Notifications Master page'
      ),
      (
        'Notifications Master (Delete)',
        'notifications_master',
        false,
        false,
        false,
        true,
        'Delete access for Notifications Master page'
      ),
      (
        'Website Setup (View)',
        'cms_website',
        true,
        false,
        false,
        false,
        'View access for Website Setup page'
      ),
      (
        'Website Setup (Add)',
        'cms_website',
        false,
        true,
        false,
        false,
        'Add access for Website Setup page'
      ),
      (
        'Website Setup (Edit)',
        'cms_website',
        false,
        false,
        true,
        false,
        'Edit access for Website Setup page'
      ),
      (
        'Website Setup (Delete)',
        'cms_website',
        false,
        false,
        false,
        true,
        'Delete access for Website Setup page'
      ),
      (
        'Service Categories (View)',
        'case_matter_service_category',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Service Categories page'
      ),
      (
        'Service Categories (Add)',
        'case_matter_service_category',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Service Categories page'
      ),
      (
        'Service Categories (Edit)',
        'case_matter_service_category',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Service Categories page'
      ),
      (
        'Service Categories (Delete)',
        'case_matter_service_category',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Service Categories page'
      ),
      (
        'Service Master (View)',
        'case_matter_service_master',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Service Master page'
      ),
      (
        'Service Master (Add)',
        'case_matter_service_master',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Service Master page'
      ),
      (
        'Service Master (Edit)',
        'case_matter_service_master',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Service Master page'
      ),
      (
        'Service Master (Delete)',
        'case_matter_service_master',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Service Master page'
      ),
      (
        'Events (View)',
        'events',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Events page'
      ),
      (
        'Events (Add)',
        'events',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Events page'
      ),
      (
        'Events (Edit)',
        'events',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Events page'
      ),
      (
        'Events (Delete)',
        'events',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Events page'
      ),
      (
        'Work Type (View)',
        'case_matter_work_type',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Work Type and Payment Type pages'
      ),
      (
        'Work Type (Add)',
        'case_matter_work_type',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Work Type and Payment Type pages'
      ),
      (
        'Work Type (Edit)',
        'case_matter_work_type',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Work Type and Payment Type pages'
      ),
      (
        'Work Type (Delete)',
        'case_matter_work_type',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Work Type and Payment Type pages'
      ),
      (
        'Court (View)',
        'case_matter_court',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Court page'
      ),
      (
        'Court (Add)',
        'case_matter_court',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Court page'
      ),
      (
        'Court (Edit)',
        'case_matter_court',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Court page'
      ),
      (
        'Court (Delete)',
        'case_matter_court',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Court page'
      ),
      (
        'Register Book (View)',
        'case_matter_diary',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Register Book page'
      ),
      (
        'Register Book (Add)',
        'case_matter_diary',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Register Book page'
      ),
      (
        'Register Book (Edit)',
        'case_matter_diary',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Register Book page'
      ),
      (
        'Register Book (Delete)',
        'case_matter_diary',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Register Book page'
      ),
      (
        'Legal Documents (View)',
        'case_matter_document',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Document Categories and Legal Templates pages'
      ),
      (
        'Legal Documents (Add)',
        'case_matter_document',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Document Categories and Legal Templates pages'
      ),
      (
        'Legal Documents (Edit)',
        'case_matter_document',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Document Categories and Legal Templates pages'
      ),
      (
        'Legal Documents (Delete)',
        'case_matter_document',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Document Categories and Legal Templates pages'
      ),
      (
        'Fields (View)',
        'case_matter_fields',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Fields page'
      ),
      (
        'Fields (Add)',
        'case_matter_fields',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Fields page'
      ),
      (
        'Fields (Edit)',
        'case_matter_fields',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Fields page'
      ),
      (
        'Fields (Delete)',
        'case_matter_fields',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Fields page'
      ),
      (
        'Broker Agent (View)',
        'masters_agent',
        true,
        false,
        false,
        false,
        'View access for Legal Masters > Broker Agent page'
      ),
      (
        'Broker Agent (Add)',
        'masters_agent',
        false,
        true,
        false,
        false,
        'Add access for Legal Masters > Broker Agent page'
      ),
      (
        'Broker Agent (Edit)',
        'masters_agent',
        false,
        false,
        true,
        false,
        'Edit access for Legal Masters > Broker Agent page'
      ),
      (
        'Broker Agent (Delete)',
        'masters_agent',
        false,
        false,
        false,
        true,
        'Delete access for Legal Masters > Broker Agent page'
      ),
      (
        'Branches (View)',
        'branches',
        true,
        false,
        false,
        false,
        'View access for Organization Masters > Branches page'
      ),
      (
        'Branches (Add)',
        'branches',
        false,
        true,
        false,
        false,
        'Add access for Organization Masters > Branches page'
      ),
      (
        'Branches (Edit)',
        'branches',
        false,
        false,
        true,
        false,
        'Edit access for Organization Masters > Branches page'
      ),
      (
        'Branches (Delete)',
        'branches',
        false,
        false,
        false,
        true,
        'Delete access for Organization Masters > Branches page'
      ),
      (
        'Departments (View)',
        'masters_departments',
        true,
        false,
        false,
        false,
        'View access for Organization Masters > Departments page'
      ),
      (
        'Departments (Add)',
        'masters_departments',
        false,
        true,
        false,
        false,
        'Add access for Organization Masters > Departments page'
      ),
      (
        'Departments (Edit)',
        'masters_departments',
        false,
        false,
        true,
        false,
        'Edit access for Organization Masters > Departments page'
      ),
      (
        'Departments (Delete)',
        'masters_departments',
        false,
        false,
        false,
        true,
        'Delete access for Organization Masters > Departments page'
      ),
      (
        'Company Terms (View)',
        'masters_company_terms',
        true,
        false,
        false,
        false,
        'View access for Organization Masters > Company Terms page'
      ),
      (
        'Company Terms (Add)',
        'masters_company_terms',
        false,
        true,
        false,
        false,
        'Add access for Organization Masters > Company Terms page'
      ),
      (
        'Company Terms (Edit)',
        'masters_company_terms',
        false,
        false,
        true,
        false,
        'Edit access for Organization Masters > Company Terms page'
      ),
      (
        'Company Terms (Delete)',
        'masters_company_terms',
        false,
        false,
        false,
        true,
        'Delete access for Organization Masters > Company Terms page'
      ),
      (
        'Shifts (View)',
        'masters_shifts',
        true,
        false,
        false,
        false,
        'View access for HR Masters > Shifts page'
      ),
      (
        'Shifts (Add)',
        'masters_shifts',
        false,
        true,
        false,
        false,
        'Add access for HR Masters > Shifts page'
      ),
      (
        'Shifts (Edit)',
        'masters_shifts',
        false,
        false,
        true,
        false,
        'Edit access for HR Masters > Shifts page'
      ),
      (
        'Shifts (Delete)',
        'masters_shifts',
        false,
        false,
        false,
        true,
        'Delete access for HR Masters > Shifts page'
      ),
      (
        'Holidays (View)',
        'masters_holidays',
        true,
        false,
        false,
        false,
        'View access for HR Masters > Holidays page'
      ),
      (
        'Holidays (Add)',
        'masters_holidays',
        false,
        true,
        false,
        false,
        'Add access for HR Masters > Holidays page'
      ),
      (
        'Holidays (Edit)',
        'masters_holidays',
        false,
        false,
        true,
        false,
        'Edit access for HR Masters > Holidays page'
      ),
      (
        'Holidays (Delete)',
        'masters_holidays',
        false,
        false,
        false,
        true,
        'Delete access for HR Masters > Holidays page'
      ),
      (
        'Leave Types (View)',
        'masters_leave_types',
        true,
        false,
        false,
        false,
        'View access for HR Masters > Leave Types page'
      ),
      (
        'Leave Types (Add)',
        'masters_leave_types',
        false,
        true,
        false,
        false,
        'Add access for HR Masters > Leave Types page'
      ),
      (
        'Leave Types (Edit)',
        'masters_leave_types',
        false,
        false,
        true,
        false,
        'Edit access for HR Masters > Leave Types page'
      ),
      (
        'Leave Types (Delete)',
        'masters_leave_types',
        false,
        false,
        false,
        true,
        'Delete access for HR Masters > Leave Types page'
      ),
      (
        'Work Weeks (View)',
        'masters_work_weeks',
        true,
        false,
        false,
        false,
        'View access for HR Masters > Work Weeks page'
      ),
      (
        'Work Weeks (Add)',
        'masters_work_weeks',
        false,
        true,
        false,
        false,
        'Add access for HR Masters > Work Weeks page'
      ),
      (
        'Work Weeks (Edit)',
        'masters_work_weeks',
        false,
        false,
        true,
        false,
        'Edit access for HR Masters > Work Weeks page'
      ),
      (
        'Work Weeks (Delete)',
        'masters_work_weeks',
        false,
        false,
        false,
        true,
        'Delete access for HR Masters > Work Weeks page'
      ),
      (
        'Contract Types (View)',
        'masters_contract_types',
        true,
        false,
        false,
        false,
        'View access for HR Masters > Contract Types pages'
      ),
      (
        'Contract Types (Add)',
        'masters_contract_types',
        false,
        true,
        false,
        false,
        'Add access for HR Masters > Contract Types pages'
      ),
      (
        'Contract Types (Edit)',
        'masters_contract_types',
        false,
        false,
        true,
        false,
        'Edit access for HR Masters > Contract Types pages'
      ),
      (
        'Contract Types (Delete)',
        'masters_contract_types',
        false,
        false,
        false,
        true,
        'Delete access for HR Masters > Contract Types pages'
      ),
      (
        'Salary Components (View)',
        'masters_salary_components',
        true,
        false,
        false,
        false,
        'View access for HR Masters > Salary Components page'
      ),
      (
        'Salary Components (Add)',
        'masters_salary_components',
        false,
        true,
        false,
        false,
        'Add access for HR Masters > Salary Components page'
      ),
      (
        'Salary Components (Edit)',
        'masters_salary_components',
        false,
        false,
        true,
        false,
        'Edit access for HR Masters > Salary Components page'
      ),
      (
        'Salary Components (Delete)',
        'masters_salary_components',
        false,
        false,
        false,
        true,
        'Delete access for HR Masters > Salary Components page'
      ),
      (
        'Countries (View)',
        'location_master_country',
        true,
        false,
        false,
        false,
        'View access for Location Masters > Countries page'
      ),
      (
        'Countries (Add)',
        'location_master_country',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > Countries page'
      ),
      (
        'Countries (Edit)',
        'location_master_country',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > Countries page'
      ),
      (
        'Countries (Delete)',
        'location_master_country',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > Countries page'
      ),
      (
        'States (View)',
        'location_master_state',
        true,
        false,
        false,
        false,
        'View access for Location Masters > States page'
      ),
      (
        'States (Add)',
        'location_master_state',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > States page'
      ),
      (
        'States (Edit)',
        'location_master_state',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > States page'
      ),
      (
        'States (Delete)',
        'location_master_state',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > States page'
      ),
      (
        'Cities (View)',
        'location_master_city',
        true,
        false,
        false,
        false,
        'View access for Location Masters > Cities page'
      ),
      (
        'Cities (Add)',
        'location_master_city',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > Cities page'
      ),
      (
        'Cities (Edit)',
        'location_master_city',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > Cities page'
      ),
      (
        'Cities (Delete)',
        'location_master_city',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > Cities page'
      ),
      (
        'Districts (View)',
        'location_master_district',
        true,
        false,
        false,
        false,
        'View access for Location Masters > Districts page'
      ),
      (
        'Districts (Add)',
        'location_master_district',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > Districts page'
      ),
      (
        'Districts (Edit)',
        'location_master_district',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > Districts page'
      ),
      (
        'Districts (Delete)',
        'location_master_district',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > Districts page'
      ),
      (
        'Talukas (View)',
        'location_master_taluka',
        true,
        false,
        false,
        false,
        'View access for Location Masters > Talukas page'
      ),
      (
        'Talukas (Add)',
        'location_master_taluka',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > Talukas page'
      ),
      (
        'Talukas (Edit)',
        'location_master_taluka',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > Talukas page'
      ),
      (
        'Talukas (Delete)',
        'location_master_taluka',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > Talukas page'
      ),
      (
        'Villages (View)',
        'location_master_village',
        true,
        false,
        false,
        false,
        'View access for Location Masters > Villages page'
      ),
      (
        'Villages (Add)',
        'location_master_village',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > Villages page'
      ),
      (
        'Villages (Edit)',
        'location_master_village',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > Villages page'
      ),
      (
        'Villages (Delete)',
        'location_master_village',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > Villages page'
      ),
      (
        'Pincodes (View)',
        'location_master_pincode',
        true,
        false,
        false,
        false,
        'View access for Location Masters > Pincodes page'
      ),
      (
        'Pincodes (Add)',
        'location_master_pincode',
        false,
        true,
        false,
        false,
        'Add access for Location Masters > Pincodes page'
      ),
      (
        'Pincodes (Edit)',
        'location_master_pincode',
        false,
        false,
        true,
        false,
        'Edit access for Location Masters > Pincodes page'
      ),
      (
        'Pincodes (Delete)',
        'location_master_pincode',
        false,
        false,
        false,
        true,
        'Delete access for Location Masters > Pincodes page'
      ),
      (
        'Users (View)',
        'users',
        true,
        false,
        false,
        false,
        'View access for User & Access Management > Users page'
      ),
      (
        'Users (Add)',
        'users',
        false,
        true,
        false,
        false,
        'Add access for User & Access Management > Users page'
      ),
      (
        'Users (Edit)',
        'users',
        false,
        false,
        true,
        false,
        'Edit access for User & Access Management > Users page'
      ),
      (
        'Users Password Reset (Edit)',
        'users_password_reset',
        false,
        false,
        true,
        false,
        'Edit access to reset other users passwords from My Profile page'
      ),
      (
        'Users (Delete)',
        'users',
        false,
        false,
        false,
        true,
        'Delete access for User & Access Management > Users page'
      ),
      (
        'Roles (View)',
        'roles_management',
        true,
        false,
        false,
        false,
        'View access for User & Access Management > Roles page'
      ),
      (
        'Roles (Add)',
        'roles_management',
        false,
        true,
        false,
        false,
        'Add access for User & Access Management > Roles page'
      ),
      (
        'Roles (Edit)',
        'roles_management',
        false,
        false,
        true,
        false,
        'Edit access for User & Access Management > Roles page'
      ),
      (
        'Roles (Delete)',
        'roles_management',
        false,
        false,
        false,
        true,
        'Delete access for User & Access Management > Roles page'
      ),
      (
        'Permissions (View)',
        'permissions_management',
        true,
        false,
        false,
        false,
        'View access for User & Access Management > Permissions page'
      ),
      (
        'Permissions (Add)',
        'permissions_management',
        false,
        true,
        false,
        false,
        'Add access for User & Access Management > Permissions page'
      ),
      (
        'Permissions (Edit)',
        'permissions_management',
        false,
        false,
        true,
        false,
        'Edit access for User & Access Management > Permissions page'
      ),
      (
        'Permissions (Delete)',
        'permissions_management',
        false,
        false,
        false,
        true,
        'Delete access for User & Access Management > Permissions page'
      ),
      (
        'User Permissions (View)',
        'user_permissions_management',
        true,
        false,
        false,
        false,
        'View access for User & Access Management > User Permissions page'
      ),
      (
        'User Permissions (Add)',
        'user_permissions_management',
        false,
        true,
        false,
        false,
        'Add access for User & Access Management > User Permissions page'
      ),
      (
        'User Permissions (Edit)',
        'user_permissions_management',
        false,
        false,
        true,
        false,
        'Edit access for User & Access Management > User Permissions page'
      ),
      (
        'User Permissions (Delete)',
        'user_permissions_management',
        false,
        false,
        false,
        true,
        'Delete access for User & Access Management > User Permissions page'
      ),
      (
        'Company Settings (View)',
        'settings_company',
        true,
        false,
        false,
        false,
        'View access for Settings > Company Settings page'
      ),
      (
        'Company Settings (Add)',
        'settings_company',
        false,
        true,
        false,
        false,
        'Add access for Settings > Company Settings page'
      ),
      (
        'Company Settings (Edit)',
        'settings_company',
        false,
        false,
        true,
        false,
        'Edit access for Settings > Company Settings page'
      ),
      (
        'Company Settings (Delete)',
        'settings_company',
        false,
        false,
        false,
        true,
        'Delete access for Settings > Company Settings page'
      ),
      (
        'SMTP Settings (View)',
        'settings_smtp',
        true,
        false,
        false,
        false,
        'View access for Settings > SMTP Settings page'
      ),
      (
        'SMTP Settings (Add)',
        'settings_smtp',
        false,
        true,
        false,
        false,
        'Add access for Settings > SMTP Settings page'
      ),
      (
        'SMTP Settings (Edit)',
        'settings_smtp',
        false,
        false,
        true,
        false,
        'Edit access for Settings > SMTP Settings page'
      ),
      (
        'SMTP Settings (Delete)',
        'settings_smtp',
        false,
        false,
        false,
        true,
        'Delete access for Settings > SMTP Settings page'
      ),
      (
        'Support Articles (View)',
        'support_articles',
        true,
        false,
        false,
        false,
        'View access for Support page'
      ),
      (
        'widget_absent_today',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: absent today'
      ),
      (
        'widget_attendance_actions',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: attendance actions'
      ),
      (
        'widget_attendance_overview',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: attendance overview'
      ),
      (
        'widget_attendance_trend',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: attendance trend'
      ),
      (
        'widget_birthdays',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: birthdays'
      ),
      (
        'widget_branch_hearings',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: branch hearings'
      ),
      (
        'widget_cases_by_status',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: cases by status'
      ),
      (
        'widget_clients_overview',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: clients overview'
      ),
      (
        'widget_dept_breakdown',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: department breakdown'
      ),
      (
        'widget_expense_summary',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: expense summary'
      ),
      (
        'widget_header_stats',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: header stats'
      ),
      (
        'widget_quick_access_menu',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: quick access menu'
      ),
      (
        'widget_hearing_list',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: hearing list'
      ),
      (
        'widget_income_vs_expense',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: income vs expense'
      ),
      (
        'widget_inventory_summary',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: inventory summary'
      ),
      (
        'widget_low_stock',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: low stock'
      ),
      (
        'widget_lwp_ot_calculation',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: LWP OT calculation'
      ),
      (
        'widget_my_hearings',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my hearings'
      ),
      (
        'widget_my_attendance_trend',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my attendance trend'
      ),
      (
        'widget_company_events',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: company events'
      ),
      (
        'widget_my_upcoming_holidays',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my upcoming holidays'
      ),
      (
        'widget_my_punch_records',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my punch records'
      ),
      (
        'widget_my_leave_requests',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my leave requests'
      ),
      (
        'widget_my_tasks',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my tasks'
      ),
      (
        'widget_my_used_inventory',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my used inventory'
      ),
      (
        'widget_my_upcoming_tasks',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my upcoming tasks'
      ),
      (
        'widget_payroll_economics',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: payroll economics'
      ),
      (
        'widget_pending_leaves',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: pending leaves'
      ),
      (
        'widget_pending_punch_requests',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: pending punch requests'
      ),
      (
        'widget_my_pending_punch_requests',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: my pending punch requests'
      ),
      (
        'widget_punch_records',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: punch records'
      ),
      (
        'widget_quick_actions_admin',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: quick actions admin'
      ),
      (
        'widget_recent_service_orders',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: recent service orders'
      ),
      (
        'widget_revenue_collections',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: revenue collections'
      ),
      (
        'widget_service_summary',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: service summary'
      ),
      (
        'widget_tasks_list',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: tasks list'
      ),
      (
        'widget_upcoming_events',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: upcoming events'
      ),
      (
        'widget_upcoming_holidays',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: upcoming holidays'
      ),
      (
        'widget_week_off_duty',
        'Dashboard Widgets',
        true,
        false,
        false,
        false,
        'Dashboard widget visibility: week off duty'
      ),
      (
        'My Contract (View)',
        'my_contract',
        true,
        false,
        false,
        false,
        'View access for My Contract page'
      ),
      (
        'My Contract (Add)',
        'my_contract',
        false,
        true,
        false,
        false,
        'Add access for My Contract page'
      ),
      (
        'My Contract (Edit)',
        'my_contract',
        false,
        false,
        true,
        false,
        'Edit access for My Contract page'
      ),
      (
        'My Contract (Delete)',
        'my_contract',
        false,
        false,
        false,
        true,
        'Delete access for My Contract page'
      )
  ) AS t(
    permission_name,
    module_key,
    can_view,
    can_add,
    can_edit,
    can_delete,
    description
  )
)
INSERT INTO public.permissions (
  name,
  module,
  can_view,
  can_add,
  can_edit,
  can_delete,
  description,
  is_active,
  is_deleted,
  updated_at
)
SELECT
  ps.permission_name,
  ps.module_key,
  ps.can_view,
  ps.can_add,
  ps.can_edit,
  ps.can_delete,
  ps.description,
  true,
  false,
  CURRENT_TIMESTAMP
FROM permission_seed ps
ON CONFLICT (name)
DO UPDATE SET
  is_active = true,
  is_deleted = false,
  updated_at = CURRENT_TIMESTAMP;

-- 2) Ensure required roles exist (additive + idempotent)
INSERT INTO public.roles (
  name,
  description,
  is_active,
  is_deleted,
  updated_at
)
VALUES
  ('Admin', 'System Administrator with full access', true, false, CURRENT_TIMESTAMP),
  ('HR Manager', 'HR Manager with elevated operational access', true, false, CURRENT_TIMESTAMP),
  ('Manager', 'Manager with operational management access', true, false, CURRENT_TIMESTAMP),
  ('Employee', 'Employee with limited operational access', true, false, CURRENT_TIMESTAMP),
  ('Sales Partner', 'Sales Partner with view-only access', true, false, CURRENT_TIMESTAMP)
ON CONFLICT (name)
DO UPDATE SET
  is_active = true,
  is_deleted = false,
  updated_at = CURRENT_TIMESTAMP;

-- 3) Auto-assign page permissions (additive only)
-- Exclusions:
--   - Attendance root module (`attendance`)
--   - Website Setup module (`cms_website`)
--   - All dashboard widgets
-- Included in scope: manually_attendance_list, pl_earning_days, punch_edit_requests
-- Safety:
--   - No DELETE/UPDATE on public.role_permissions
--   - Existing assignments are untouched

-- 3.1 Admin => all eligible permissions (full CRUD via existing permission rows)
WITH excluded_modules AS (
  SELECT * FROM (
    VALUES
      ('attendance'),
      ('cms_website'),
      ('Dashboard Widgets')
  ) AS t(module_key)
),
eligible_permissions AS (
  SELECT p.id
  FROM public.permissions p
  LEFT JOIN excluded_modules em
    ON p.module = em.module_key
  WHERE p.is_active = true
    AND p.is_deleted = false
    AND em.module_key IS NULL
    AND p.name NOT LIKE 'widget_%'
)
INSERT INTO public.role_permissions (
  role_id,
  permission_id,
  is_active,
  is_deleted,
  updated_at
)
SELECT
  r.id,
  p.id,
  true,
  false,
  CURRENT_TIMESTAMP
FROM public.roles r
CROSS JOIN eligible_permissions p
WHERE r.name = 'Admin'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- 3.2 Sales Partner => eligible view-only permissions only
WITH excluded_modules AS (
  SELECT * FROM (
    VALUES
      ('attendance'),
      ('cms_website'),
      ('Dashboard Widgets')
  ) AS t(module_key)
),
eligible_view_permissions AS (
  SELECT p.id
  FROM public.permissions p
  LEFT JOIN excluded_modules em
    ON p.module = em.module_key
  WHERE p.is_active = true
    AND p.is_deleted = false
    AND em.module_key IS NULL
    AND p.name NOT LIKE 'widget_%'
    AND p.can_view = true
    AND p.can_add = false
    AND p.can_edit = false
    AND p.can_delete = false
)
INSERT INTO public.role_permissions (
  role_id,
  permission_id,
  is_active,
  is_deleted,
  updated_at
)
SELECT
  r.id,
  p.id,
  true,
  false,
  CURRENT_TIMESTAMP
FROM public.roles r
CROSS JOIN eligible_view_permissions p
WHERE lower(r.name) = 'sales partner'
ON CONFLICT (role_id, permission_id) DO NOTHING;

COMMIT;
