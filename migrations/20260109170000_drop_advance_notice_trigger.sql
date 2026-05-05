-- Drop advance notice validation trigger
-- The validation is now handled entirely in the frontend

-- Drop the trigger
DROP TRIGGER IF EXISTS validate_leave_advance_notice_trigger ON public.leave_requests;

-- Drop the function
DROP FUNCTION IF EXISTS public.validate_leave_advance_notice();

-- Add comment explaining the change
COMMENT ON TABLE public.leave_requests IS 'Leave requests table. Advance notice validation is handled in the frontend to allow HR/Admin flexibility in approvals.';
