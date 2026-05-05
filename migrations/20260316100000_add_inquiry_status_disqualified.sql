-- Add missing inquiry status enum values (e.g. Disqualified) so status updates succeed
-- 20260316100000_add_inquiry_status_disqualified.sql

DO $$
BEGIN
    -- Inquiry status values used in UI that may be missing from inquiry_status_type
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Disqualified';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Qualified';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Converted';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Invalid/Spam';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Follow-up Required';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Not Qualified';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'In Progress';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'New';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;
