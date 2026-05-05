import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';
import dayjs from 'dayjs';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config/credentials';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export async function generateAttendanceCSV(startDate: string, endDate: string) {
  try {
    console.log(`Generating attendance CSV for ${startDate} to ${endDate}...`);

    // Query attendance data
    const { data: attendanceData, error } = await supabase
      .from('employee_attendance')
      .select('employee_id, attendance_date, status, first_punch_in, notes')
      .gte('attendance_date', startDate)
      .lte('attendance_date', endDate)
      .order('attendance_date', { ascending: true });

    if (error) {
      console.error('Error fetching attendance data:', error);
      return;
    }

    if (!attendanceData || attendanceData.length === 0) {
      console.log('No attendance data found for the specified date range');
      return;
    }

    console.log(`Found ${attendanceData.length} attendance records`);

    // Get unique employee IDs
    const employeeIds = [...new Set(attendanceData.map(record => record.employee_id))];

    // Query employee details
    const { data: employees, error: empError } = await supabase
      .from('employees')
      .select('id, user_id')
      .in('id', employeeIds);

    if (empError) {
      console.error('Error fetching employee data:', empError);
      return;
    }

    // Get user profile details
    const userIds = employees?.map(emp => emp.user_id) || [];
    const { data: userProfiles, error: userError } = await supabase
      .from('user_profiles')
      .select('id, first_name, last_name, biometric_code')
      .in('id', userIds);

    if (userError) {
      console.error('Error fetching user profile data:', userError);
      return;
    }

    // Create lookup maps
    const employeeMap = new Map(employees?.map(emp => [emp.id, emp.user_id]) || []);
    const userMap = new Map(userProfiles?.map(user => [user.id, user]) || []);

    // Create CSV content
    const csvHeaders = [
      'Employee Name',
      'Biometric Code',
      'Date',
      'Status',
      'First Punch In',
      'Notes'
    ];

    const csvRows = attendanceData.map(record => {
      const userId = employeeMap.get(record.employee_id);
      const userProfile = userMap.get(userId);

      return [
        `"${userProfile?.first_name || ''} ${userProfile?.last_name || ''}"`,
        userProfile?.biometric_code || '',
        record.attendance_date,
        record.status,
        record.first_punch_in ? dayjs(record.first_punch_in).format('YYYY-MM-DD HH:mm:ss') : '',
        `"${record.notes || ''}"`
      ].join(',');
    });

    const csvContent = [csvHeaders.join(','), ...csvRows].join('\n');

    // Create filename with timestamp
    const timestamp = dayjs().format('YYYY-MM-DD_HH-mm-ss');
    const filename = `attendance_${startDate}_to_${endDate}_${timestamp}.csv`;

    // Save to Downloads folder (common location)
    const downloadsPath = path.join(process.env.USERPROFILE || process.env.HOME || '', 'Downloads');
    const filePath = path.join(downloadsPath, filename);

    // Write CSV file
    fs.writeFileSync(filePath, csvContent, 'utf8');

    console.log(`CSV file saved successfully: ${filePath}`);
    return filePath;

  } catch (error) {
    console.error('Error generating CSV:', error);
  }
}

// Function to generate CSV for specific date range
export async function exportAttendanceCSV(startDate: string, endDate: string) {
  const filePath = await generateAttendanceCSV(startDate, endDate);
  if (filePath) {
    console.log(`Attendance CSV exported to: ${filePath}`);
  }
}