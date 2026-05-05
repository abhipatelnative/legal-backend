-- Migration to make work types global by removing branch association
-- 1. Update existing records to have NULL branch_id
UPDATE work_types SET branch_id = NULL; 
