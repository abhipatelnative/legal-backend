-- Migration: Add enable_pl_days_counting flag to company_settings
-- This flag controls the visibility of PL (Paid Leave) days counting features
-- across the application (sidebar, dashboard, contract forms, leave types).

ALTER TABLE company_settings
ADD COLUMN IF NOT EXISTS enable_pl_days_counting BOOLEAN DEFAULT false;
