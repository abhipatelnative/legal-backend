import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';
import dayjs from 'dayjs';
import { randomUUID } from 'crypto';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export async function processAttendanceToCSV(startDate: string, endDate: string) {
  try {
    console.log(`Processing attendance from punch records for ${startDate} to ${endDate}...`);

    const csvRows: string[] = [];
    const csvHeaders = ['id', 'employee_id', 'attendance_date', 'status', 'first_punch_in', 'notes'];

    // Get all active employees
    const { data: employees, error: empError } = await supabase
      .from('employees')
      .select('id, user_id')
      .eq('is_active', true)
      .eq('employment_status', 'active');

    if (empError || !employees) {
      console.error('Error fetching employees:', empError);
      return;
    }

    // Filter employees with active contracts
    const employeeIds = employees.map(emp => emp.id);
    const { data: contracts } = await supabase
      .from('contracts')
      .select('employee_id')
      .in('employee_id', employeeIds)
      .eq('status', 'active')
      .eq('is_active', true);

    const activeEmployeeIds = contracts?.map(c => c.employee_id) || [];
    const activeEmployees = employees.filter(emp => activeEmployeeIds.includes(emp.id));

    // Get user profiles for active employees
    const userIds = activeEmployees.map(emp => emp.user_id);
    const { data: userProfiles } = await supabase
      .from('user_profiles')
      .select('id, first_name, last_name, biometric_code')
      .in('id', userIds);

    // Create lookup map
    const userMap = new Map(userProfiles?.map(user => [user.id, user]) || []);
    const employeesWithProfiles = activeEmployees.map(emp => ({
      ...emp,
      user_profiles: userMap.get(emp.user_id)
    })).filter(emp => emp.user_profiles);

    console.log(`Processing ${employeesWithProfiles.length} employees`);

    // Process each date in the range
    const start = dayjs(startDate);
    const end = dayjs(endDate);
    let currentDate = start;

    while (currentDate.isBefore(end) || currentDate.isSame(end)) {
      const processingDate = currentDate.format('YYYY-MM-DD');
      console.log(`Processing date: ${processingDate}`);

      for (const emp of employeesWithProfiles) {
        const employee = emp as any;
        const userProfile = employee.user_profiles;

        // Get contract for this employee
        const { data: contractData } = await supabase
          .from('contracts')
          .select('id')
          .eq('employee_id', employee.id)
          .eq('status', 'active')
          .eq('is_active', true)
          .limit(1);

        if (!contractData || contractData.length === 0) continue;
        const contract = contractData[0];

        let status = 'Absent';
        let firstPunchIn = '';

        // Step 1: Check for approved leave
        const { data: leaveData } = await supabase
          .from('leave_requests')
          .select('id')
          .eq('employee_id', employee.id)
          .eq('status', 'approved')
          .lte('start_date', processingDate)
          .gte('end_date', processingDate)
          .limit(1);

        if (leaveData && leaveData.length > 0) {
          status = 'Leave';
        } else {
          // Step 2: Check contract-based holidays
          const { data: holidayData } = await supabase
            .from('contract_holidays')
            .select(`
              holidays!inner(start_date, end_date)
            `)
            .eq('contract_id', contract.id)
            .eq('is_applicable', true)
            .eq('holidays.is_active', true)
            .lte('holidays.start_date', processingDate)
            .gte('holidays.end_date', processingDate)
            .limit(1);

          if (holidayData && holidayData.length > 0) {
            status = 'Holiday';
          } else {
            // Step 3: Check week-off
            const dayOfWeek = currentDate.day(); // 0=Sunday, 1=Monday, etc.

            const { data: shiftData } = await supabase
              .from('employee_shifts')
              .select(`
                work_weeks!inner(sunday, monday, tuesday, wednesday, thursday, friday, saturday)
              `)
              .eq('employee_id', employee.id)
              .eq('is_active', true)
              .limit(1);

            if (shiftData && shiftData.length > 0) {
              const workWeek = (shiftData[0] as any).work_weeks;
              const dayFields = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
              const isWorkingDay = workWeek[dayFields[dayOfWeek]];

              if (!isWorkingDay) {
                status = 'WeekOff';
              } else {
                // Step 4: Check punch records
                const { data: punchData } = await supabase
                  .from('punch_records')
                  .select('punch_time')
                  .eq('enroll_number', parseInt(userProfile.biometric_code))
                  .gte('punch_time', `${processingDate} 00:00:00`)
                  .lt('punch_time', `${currentDate.add(1, 'day').format('YYYY-MM-DD')} 00:00:00`)
                  .order('punch_time', { ascending: true });

                if (punchData && punchData.length > 0) {
                  status = 'Present';
                  firstPunchIn = dayjs(punchData[0].punch_time).format('HH:mm:ss');
                }
              }
            } else {
              // No shift data, check punch records anyway
              const { data: punchData } = await supabase
                .from('punch_records')
                .select('punch_time')
                .eq('enroll_number', parseInt(userProfile.biometric_code))
                .gte('punch_time', `${processingDate} 00:00:00`)
                .lt('punch_time', `${currentDate.add(1, 'day').format('YYYY-MM-DD')} 00:00:00`)
                .order('punch_time', { ascending: true });

              if (punchData && punchData.length > 0) {
                status = 'Present';
                firstPunchIn = dayjs(punchData[0].punch_time).format('HH:mm:ss');
              }
            }
          }
        }

        // Add row to CSV
        csvRows.push([
          randomUUID(),
          employee.id,
          processingDate,
          status,
          firstPunchIn,
          ''
        ].join(','));
      }

      currentDate = currentDate.add(1, 'day');
    }

    // Create CSV content
    const csvContent = [csvHeaders.join(','), ...csvRows].join('\n');

    // Create filename with timestamp
    const timestamp = dayjs().format('YYYY-MM-DD_HH-mm-ss');
    const filename = `employee_attendance_${startDate}_to_${endDate}_${timestamp}.csv`;

    // Save to Downloads folder
    const downloadsPath = path.join(process.env.USERPROFILE || process.env.HOME || '', 'Downloads');
    const filePath = path.join(downloadsPath, filename);

    // Write CSV file
    fs.writeFileSync(filePath, csvContent, 'utf8');

    console.log(`Attendance CSV processed and saved: ${filePath}`);
    console.log(`Total records: ${csvRows.length}`);
    return filePath;

  } catch (error) {
    console.error('Error processing attendance to CSV:', error);
  }
}