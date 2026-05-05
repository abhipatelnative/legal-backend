-- Add remaining inquiry status enum values used in the UI but may be missing from the DB enum
-- Existing values: New, In Progress, Invalid/Spam, Follow-up Required, Not Qualified, Qualified, Disqualified, Converted
-- Missing values used in InquiriesList UI: Assigned, On Hold, Closed

DO $$
BEGIN
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Assigned';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'On Hold';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        ALTER TYPE inquiry_status_type ADD VALUE IF NOT EXISTS 'Closed';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;
