-- Migration to make fields global by removing branch association
-- 1. Update existing records to have NULL branch_id
UPDATE fields_master SET branch_id = NULL; 
