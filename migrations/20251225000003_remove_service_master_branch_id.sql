-- Migration to make services global by removing branch association
-- 1. Update existing records to have NULL branch_id
UPDATE service_master SET branch_id = NULL; 
