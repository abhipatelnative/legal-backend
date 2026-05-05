-- Create holiday masters table
create table public.holiday_masters (
  id uuid not null default gen_random_uuid (),
  name character varying(255) not null unique,
  type public.holiday_type null default 'company'::holiday_type,
  description text null,
  is_recurring boolean DEFAULT false,
  is_active boolean null default true,
  is_deleted boolean null default false,
  created_at timestamp with time zone null default CURRENT_TIMESTAMP,
  updated_at timestamp with time zone null default CURRENT_TIMESTAMP,
  created_by uuid null,
  updated_by uuid null,
  constraint holiday_masters_pkey primary key (id),
  constraint holiday_masters_created_by_fkey foreign KEY (created_by) references auth.users (id),
  constraint holiday_masters_updated_by_fkey foreign KEY (updated_by) references auth.users (id)
) TABLESPACE pg_default;

-- Add index
create index IF not exists idx_holiday_masters_name on public.holiday_masters using btree (name) TABLESPACE pg_default;

-- Add trigger
create trigger update_holiday_masters_updated_at BEFORE
update on holiday_masters for EACH row
execute FUNCTION update_updated_at_column ();

-- Add reference column to existing holidays table
alter table public.holidays 
add column holiday_master_id uuid references holiday_masters(id) on delete set null;

-- Add index for the new foreign key
create index IF not exists idx_holidays_master on public.holidays using btree (holiday_master_id) TABLESPACE pg_default;

-- Insert common holidays
INSERT INTO public.holiday_masters (name, type, description) VALUES
('New Year', 'national', 'New Year celebration'),
('Republic Day', 'national', 'India Republic Day'),
('Holi', 'national', 'Festival of colors'),
('Good Friday', 'national', 'Christian holiday'),
('Independence Day', 'national', 'India Independence Day'),
('Gandhi Jayanti', 'national', 'Mahatma Gandhi birthday'),
('Diwali', 'national', 'Festival of lights'),
('Christmas', 'national', 'Christian celebration'),
('Dussehra', 'national', 'Hindu festival'),
('Eid ul-Fitr', 'national', 'Islamic festival'),
('Eid ul-Adha', 'national', 'Islamic festival'),
('Company Foundation Day', 'company', 'Company anniversary'),
('Company Anniversary', 'company', 'Company anniversary'),
('Saturday Off', 'company', 'Saturday off'),
('Team Outing', 'company', 'Company team building day');