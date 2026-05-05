-- Migration: Add provided_by column to service_order_task_documents
-- Description: Adds a column to track who provided the document (Advocate/Firm or Client)
-- Date: 2025-12-25

ALTER TABLE public.service_order_task_documents
ADD COLUMN IF NOT EXISTS provided_by VARCHAR(50);

-- Add comment to column
COMMENT ON COLUMN public.service_order_task_documents.provided_by IS 'Who provided the document: Advocate / Firm or Client (Party Self)';
