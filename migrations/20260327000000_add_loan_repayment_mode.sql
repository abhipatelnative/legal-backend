-- Add repayment_mode to employee_loans
-- fixed_emi: monthly EMI stays constant, remaining tenure reduces after partial payments
-- fixed_tenure: total months stay constant, EMI = remaining / months_left after each partial payment
ALTER TABLE public.employee_loans
  ADD COLUMN IF NOT EXISTS repayment_mode VARCHAR(20) NOT NULL DEFAULT 'fixed_emi'
  CHECK (repayment_mode IN ('fixed_emi', 'fixed_tenure'));

-- Add is_manual to loan_transactions to distinguish payroll deductions from manual payments
-- Critical for fixed_tenure mode: months_left = tenure - count(is_manual=false)
ALTER TABLE public.loan_transactions
  ADD COLUMN IF NOT EXISTS is_manual BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.employee_loans.repayment_mode IS
  'fixed_emi: monthly EMI stays constant, remaining tenure reduces after partial payments. fixed_tenure: total months stay constant, EMI = remaining / months_left after each partial payment.';

COMMENT ON COLUMN public.loan_transactions.is_manual IS
  'true = manual repayment recorded via EmployeeLoans page; false = payroll auto-deduction. Used in fixed_tenure mode to count only payroll months for months_left calculation.';
