-- Migration to update status enums for both Inquiries and Leads to support detailed workflow
-- 20260204000003_update_status_enums.sql

DO $$
BEGIN
    -- Update Inquiry Status Enum
    -- Needed: 'Assigned', 'On Hold', 'Closed'
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Assigned';
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'On Hold';
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Closed';
    EXCEPTION WHEN OTHERS THEN NULL; END;

    -- Update Lead Status Enum
    -- Needed: 'On Hold' (others like Assigned, Contacted, Disqualified, Cancelled, In Progress were added or exist)
    BEGIN
        ALTER TYPE lead_status_type ADD VALUE IF NOT EXISTS 'On Hold';
    EXCEPTION WHEN OTHERS THEN NULL; END;

END $$;
