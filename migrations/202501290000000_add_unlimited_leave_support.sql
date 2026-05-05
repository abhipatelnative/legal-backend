-- Add unlimited leave support to leave_types table

-- Add is_unlimited column to leave_types table
ALTER TABLE public.leave_types 
ADD COLUMN is_unlimited BOOLEAN DEFAULT false;

-- Update contract_leaves table to support unlimited leaves
ALTER TABLE public.contract_leaves 
ADD COLUMN is_unlimited BOOLEAN DEFAULT false;

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_leave_types_unlimited ON public.leave_types(is_unlimited);
CREATE INDEX IF NOT EXISTS idx_contract_leaves_unlimited ON public.contract_leaves(is_unlimited);

-- Update existing leave types to set is_unlimited based on days_allowed being null
UPDATE public.leave_types 
SET is_unlimited = true 
WHERE days_allowed IS NULL;

-- Update existing contract leaves to set is_unlimited based on days_allowed being null
UPDATE public.contract_leaves 
SET is_unlimited = true 
WHERE days_allowed IS NULL;

-- Add comment to document the field
COMMENT ON COLUMN public.leave_types.is_unlimited IS 'Indicates if this leave type has unlimited days (no day limit)';
COMMENT ON COLUMN public.contract_leaves.is_unlimited IS 'Indicates if this contract leave has unlimited days (no day limit)';