DO $$ BEGIN
    CREATE TYPE lead_status_type AS ENUM (
        'New',
        'Contacted',
        'Qualified',
        'Converted',
        'Lost'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS leads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    service_id UUID, 
    source TEXT DEFAULT 'Website',
    status lead_status_type DEFAULT 'New',
    assigned_to UUID, -- employee_id
    notes TEXT,
    inquiry_id UUID, -- Link back to inquiry
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT fk_lead_service FOREIGN KEY (service_id) REFERENCES service_master(id) ON DELETE SET NULL,
    CONSTRAINT fk_lead_inquiry FOREIGN KEY (inquiry_id) REFERENCES inquiries(id) ON DELETE SET NULL
    -- CONSTRAINT fk_lead_assigned FOREIGN KEY (assigned_to) REFERENCES employees(id)
);

-- Indices
CREATE INDEX IF NOT EXISTS idx_leads_status ON leads(status);
CREATE INDEX IF NOT EXISTS idx_leads_email ON leads(email);

-- Update trigger
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'update_updated_at_column') THEN
        CREATE TRIGGER update_leads_modtime
            BEFORE UPDATE ON leads
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at_column();
    END IF;
END $$;
