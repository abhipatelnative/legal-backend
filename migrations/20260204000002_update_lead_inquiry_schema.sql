-- Migration to update Inquiry and Lead schema for assignment and extended statuses

-- 1. Add assigned_to to Inquiries table
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'inquiries' AND column_name = 'assigned_to') THEN
        ALTER TABLE inquiries ADD COLUMN assigned_to UUID REFERENCES employees(id) ON DELETE SET NULL;
    END IF;
END $$;

-- 2. Ensure assigned_to in Leads has foreign key
DO $$
BEGIN
    -- Check if constraint exists effectively, if not add it.
    -- We assume the column 'assigned_to' exists based on previous schema. 
    -- If no constraint 'fk_lead_assigned' exists, we add it.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_lead_assigned') THEN
        ALTER TABLE leads 
        ADD CONSTRAINT fk_lead_assigned 
        FOREIGN KEY (assigned_to) 
        REFERENCES employees(id) 
        ON DELETE SET NULL;
    END IF;
END $$;

-- 3. Update Lead Status Enum
-- Using ALTER TYPE to add new values. Note: cannot run inside a transaction block in some Postgres versions depending on exact method, 
-- but separate statements usually work. We use 'IF NOT EXISTS' if supported (PG 12+), or exception block.

DO $$
BEGIN
    -- Attempt to add values safely
    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'Assigned';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    
    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'Reassigned';
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'Follow Up';
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'Disqualified';
    EXCEPTION WHEN OTHERS THEN NULL; END;

    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'Cancelled';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    
    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'In Progress';
    EXCEPTION WHEN OTHERS THEN NULL; END;

END $$;
