
-- Phase 5: Reports & Audit System

-- 42. reports table
CREATE TABLE public.reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  module VARCHAR(100) NOT NULL,
  report_type VARCHAR(50) NOT NULL,
  query_template TEXT NOT NULL,
  parameters JSONB,
  format report_format DEFAULT 'pdf',
  is_scheduled BOOLEAN DEFAULT false,
  schedule_cron VARCHAR(100),
  recipients JSONB,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 43. report_executions table
CREATE TABLE public.report_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
  executed_by UUID NOT NULL REFERENCES auth.users(id),
  execution_time TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  parameters_used JSONB,
  status VARCHAR(50) DEFAULT 'running',
  file_url VARCHAR(500),
  error_message TEXT,
  execution_duration INTEGER, -- in milliseconds
  record_count INTEGER,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_duration CHECK (execution_duration IS NULL OR execution_duration >= 0),
  CONSTRAINT positive_record_count CHECK (record_count IS NULL OR record_count >= 0)
);

-- 44. dashboards table
CREATE TABLE public.dashboards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  layout JSONB NOT NULL,
  is_default BOOLEAN DEFAULT false,
  role_id UUID REFERENCES public.roles(id) ON DELETE SET NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Ensure either role_id or user_id is set, but not both
  CONSTRAINT dashboard_assignment CHECK (
    (role_id IS NOT NULL AND user_id IS NULL) OR 
    (role_id IS NULL AND user_id IS NOT NULL)
  )
);

-- 45. dashboard_widgets table
CREATE TABLE public.dashboard_widgets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dashboard_id UUID NOT NULL REFERENCES public.dashboards(id) ON DELETE CASCADE,
  widget_type VARCHAR(50) NOT NULL,
  title VARCHAR(255) NOT NULL,
  configuration JSONB NOT NULL,
  position_x INTEGER NOT NULL DEFAULT 0,
  position_y INTEGER NOT NULL DEFAULT 0,
  width INTEGER NOT NULL DEFAULT 4,
  height INTEGER NOT NULL DEFAULT 3,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_position CHECK (position_x >= 0 AND position_y >= 0),
  CONSTRAINT positive_dimensions CHECK (width > 0 AND height > 0)
);

-- 46. audit_logs table
CREATE TABLE public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name VARCHAR(100) NOT NULL,
  record_id UUID NOT NULL,
  action audit_action NOT NULL,
  old_values JSONB,
  new_values JSONB,
  changed_fields TEXT[],
  user_id UUID REFERENCES auth.users(id),
  ip_address INET,
  user_agent TEXT,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  
  -- Indexes for performance
  CONSTRAINT audit_log_table_record_idx UNIQUE (table_name, record_id, timestamp)
);

-- 47. system_settings table
CREATE TABLE public.system_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key VARCHAR(100) NOT NULL UNIQUE,
  value JSONB NOT NULL,
  data_type data_type NOT NULL,
  category VARCHAR(100),
  description TEXT,
  is_encrypted BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 48. notifications table
CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(50) DEFAULT 'info',
  read_at TIMESTAMP WITH TIME ZONE,
  action_url VARCHAR(500),
  data JSONB,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 49. activity_logs table
CREATE TABLE public.activity_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action VARCHAR(255) NOT NULL,
  module VARCHAR(100) NOT NULL,
  description TEXT,
  metadata JSONB,
  ip_address INET,
  user_agent TEXT,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id)
);

-- 50. data_exports table
CREATE TABLE public.data_exports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  export_type VARCHAR(100) NOT NULL,
  table_name VARCHAR(100) NOT NULL,
  filters JSONB,
  format report_format DEFAULT 'csv',
  status VARCHAR(50) DEFAULT 'pending',
  file_url VARCHAR(500),
  record_count INTEGER,
  file_size_bytes BIGINT,
  expires_at TIMESTAMP WITH TIME ZONE,
  downloaded_at TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN DEFAULT true,
  is_deleted BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  
  -- Constraints
  CONSTRAINT positive_record_count CHECK (record_count IS NULL OR record_count >= 0),
  CONSTRAINT positive_file_size CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0)
);

-- Create indexes for better performance
CREATE INDEX idx_reports_module ON public.reports(module, report_type);
CREATE INDEX idx_reports_active ON public.reports(is_active, is_deleted);
CREATE INDEX idx_report_executions_report ON public.report_executions(report_id);
CREATE INDEX idx_report_executions_user ON public.report_executions(executed_by);
CREATE INDEX idx_report_executions_time ON public.report_executions(execution_time);
CREATE INDEX idx_dashboards_role ON public.dashboards(role_id) WHERE role_id IS NOT NULL;
CREATE INDEX idx_dashboards_user ON public.dashboards(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_dashboard_widgets_dashboard ON public.dashboard_widgets(dashboard_id);
CREATE INDEX idx_audit_logs_table_record ON public.audit_logs(table_name, record_id);
CREATE INDEX idx_audit_logs_user ON public.audit_logs(user_id);
CREATE INDEX idx_audit_logs_timestamp ON public.audit_logs(timestamp);
CREATE INDEX idx_system_settings_key ON public.system_settings(key);
CREATE INDEX idx_system_settings_category ON public.system_settings(category);
CREATE INDEX idx_notifications_user ON public.notifications(user_id);
CREATE INDEX idx_notifications_read ON public.notifications(read_at);
CREATE INDEX idx_notifications_created ON public.notifications(created_at);
CREATE INDEX idx_activity_logs_user ON public.activity_logs(user_id);
CREATE INDEX idx_activity_logs_module ON public.activity_logs(module);
CREATE INDEX idx_activity_logs_timestamp ON public.activity_logs(timestamp);
CREATE INDEX idx_data_exports_user ON public.data_exports(user_id);
CREATE INDEX idx_data_exports_status ON public.data_exports(status);
CREATE INDEX idx_data_exports_expires ON public.data_exports(expires_at);

-- Create triggers for updated_at columns
CREATE TRIGGER update_reports_updated_at BEFORE UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_report_executions_updated_at BEFORE UPDATE ON public.report_executions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_dashboards_updated_at BEFORE UPDATE ON public.dashboards FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_dashboard_widgets_updated_at BEFORE UPDATE ON public.dashboard_widgets FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_system_settings_updated_at BEFORE UPDATE ON public.system_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_notifications_updated_at BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_activity_logs_updated_at BEFORE UPDATE ON public.activity_logs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_data_exports_updated_at BEFORE UPDATE ON public.data_exports FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Enable Row Level Security on all tables
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dashboards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dashboard_widgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_exports ENABLE ROW LEVEL SECURITY;

-- RLS Policies for reports (Admin/HR only)
CREATE POLICY "HR can manage reports" ON public.reports
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for report_executions
CREATE POLICY "Users can view their own report executions" ON public.report_executions
  FOR SELECT USING (executed_by = auth.uid());

CREATE POLICY "HR can view all report executions" ON public.report_executions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin', 'Finance Manager') 
      AND ur.is_active = true
    )
  );

CREATE POLICY "Users can create report executions" ON public.report_executions
  FOR INSERT WITH CHECK (executed_by = auth.uid());

-- RLS Policies for dashboards
CREATE POLICY "Users can view their assigned dashboards" ON public.dashboards
  FOR SELECT USING (
    user_id = auth.uid() OR
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      WHERE ur.user_id = auth.uid() 
      AND ur.role_id = dashboards.role_id 
      AND ur.is_active = true
    )
  );

CREATE POLICY "HR can manage dashboards" ON public.dashboards
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

-- RLS Policies for dashboard_widgets
CREATE POLICY "Users can view dashboard widgets" ON public.dashboard_widgets
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.dashboards d 
      WHERE d.id = dashboard_id 
      AND (d.user_id = auth.uid() OR
           EXISTS (
             SELECT 1 FROM public.user_roles ur 
             WHERE ur.user_id = auth.uid() 
             AND ur.role_id = d.role_id 
             AND ur.is_active = true
           ))
    )
  );

-- RLS Policies for audit_logs (Admin only)
CREATE POLICY "Admin can view audit logs" ON public.audit_logs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name = 'Admin' 
      AND ur.is_active = true
    )
  );

-- RLS Policies for system_settings (Admin only)
CREATE POLICY "Admin can manage system settings" ON public.system_settings
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name = 'Admin' 
      AND ur.is_active = true
    )
  );

-- RLS Policies for notifications
CREATE POLICY "Users can view their own notifications" ON public.notifications
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can update their own notifications" ON public.notifications
  FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "System can create notifications for users" ON public.notifications
  FOR INSERT WITH CHECK (true); -- Allow system to create notifications

-- RLS Policies for activity_logs
CREATE POLICY "Users can view their own activity logs" ON public.activity_logs
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "HR can view all activity logs" ON public.activity_logs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.user_roles ur 
      JOIN public.roles r ON ur.role_id = r.id 
      WHERE ur.user_id = auth.uid() 
      AND r.name IN ('HR Manager', 'Admin') 
      AND ur.is_active = true
    )
  );

CREATE POLICY "System can create activity logs" ON public.activity_logs
  FOR INSERT WITH CHECK (user_id = auth.uid());

-- RLS Policies for data_exports
CREATE POLICY "Users can manage their own data exports" ON public.data_exports
  FOR ALL USING (user_id = auth.uid());

-- Create audit trigger function for automatic audit logging
CREATE OR REPLACE FUNCTION public.create_audit_log()
RETURNS TRIGGER AS $$
BEGIN
  -- Only log for tables we want to audit
  IF TG_TABLE_NAME NOT IN ('audit_logs', 'activity_logs', 'notifications', 'punch_records') THEN
    INSERT INTO public.audit_logs (
      table_name,
      record_id,
      action,
      old_values,
      new_values,
      changed_fields,
      user_id
    ) VALUES (
      TG_TABLE_NAME,
      COALESCE(NEW.id, OLD.id),
      TG_OP::audit_action,
      CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE NULL END,
      CASE WHEN TG_OP != 'DELETE' THEN to_jsonb(NEW) ELSE NULL END,
      CASE 
        WHEN TG_OP = 'UPDATE' THEN 
          ARRAY(SELECT key FROM jsonb_each(to_jsonb(NEW)) WHERE to_jsonb(NEW)->>key IS DISTINCT FROM to_jsonb(OLD)->>key)
        ELSE NULL 
      END,
      auth.uid()
    );
  END IF;
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Create audit triggers for key tables (add more as needed)
CREATE TRIGGER audit_employees AFTER INSERT OR UPDATE OR DELETE ON public.employees
  FOR EACH ROW EXECUTE FUNCTION public.create_audit_log();

CREATE TRIGGER audit_contracts AFTER INSERT OR UPDATE OR DELETE ON public.contracts
  FOR EACH ROW EXECUTE FUNCTION public.create_audit_log();

CREATE TRIGGER audit_leave_requests AFTER INSERT OR UPDATE OR DELETE ON public.leave_requests
  FOR EACH ROW EXECUTE FUNCTION public.create_audit_log();

CREATE TRIGGER audit_payroll AFTER INSERT OR UPDATE OR DELETE ON public.payroll
  FOR EACH ROW EXECUTE FUNCTION public.create_audit_log();

CREATE TRIGGER audit_user_roles AFTER INSERT OR UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW EXECUTE FUNCTION public.create_audit_log();

-- Insert default system settings
INSERT INTO public.system_settings (key, value, data_type, category, description, created_by) VALUES
('company_name', '"HR Management System"', 'string', 'company', 'Default company name', auth.uid()),
('timezone', '"UTC"', 'string', 'system', 'System timezone', auth.uid()),
('date_format', '"YYYY-MM-DD"', 'string', 'system', 'Default date format', auth.uid()),
('currency', '"USD"', 'string', 'finance', 'Default currency', auth.uid()),
('working_hours_per_day', '8', 'number', 'attendance', 'Standard working hours per day', auth.uid()),
('max_leave_days_carry_forward', '10', 'number', 'leave', 'Maximum leave days that can be carried forward', auth.uid()),
('payroll_cutoff_date', '25', 'number', 'payroll', 'Monthly payroll cutoff date', auth.uid()),
('enable_biometric_attendance', 'false', 'boolean', 'attendance', 'Enable biometric attendance tracking', auth.uid()),
('enable_geolocation_tracking', 'false', 'boolean', 'attendance', 'Enable GPS location tracking for punch records', auth.uid()),
('notification_email_enabled', 'true', 'boolean', 'notifications', 'Enable email notifications', auth.uid());
