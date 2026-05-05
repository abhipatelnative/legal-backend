-- Migration to make service categories global by removing branch association
-- 1. Update existing records to have NULL branch_id
UPDATE service_category_master SET branch_id = NULL;
