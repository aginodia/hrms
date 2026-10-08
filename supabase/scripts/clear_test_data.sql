-- =====================================================================
-- Altius HRMS — clear all test data (run ONCE, by hand, in the Supabase
-- SQL Editor). This is NOT a migration and does not change any setting.
--
-- Keeps:  the admin login sayan.mullick@altiusinvestech.com with its
--         Employee ID, and app_settings (working hours, PT slabs, team
--         visibility, expense sheet link) untouched.
-- Clears: every other user, KYC, salaries (admin's too), payroll uploads,
--         mappings, adjustments, results, variable, bonus, loans,
--         eligibility, expense claims and the activity log.
-- It cannot be undone.
-- =====================================================================
begin;
delete from public.loan_repayments;
delete from public.loan_deductions;
delete from public.loans;
delete from public.variable_payouts;
delete from public.variable_uploads;
delete from public.variable_entries;
delete from public.bonus_payments;
delete from public.expense_claims;
delete from public.comp_eligibility;
delete from public.finance_log;
delete from public.payroll_results;
delete from public.attendance_adjustments;
delete from public.attendance_code_map;
delete from public.attendance_punches;
delete from public.payroll_runs;
delete from public.kyc_submissions;
delete from public.salary_history;
-- removing the auth user also removes their profile
delete from auth.users where lower(email) <> 'sayan.mullick@altiusinvestech.com';
commit;

-- Check: should show users 1, everything else 0, settings 4
select (select count(*) from auth.users) as users, (select count(*) from public.profiles) as profiles,
       (select count(*) from public.attendance_punches) as punches, (select count(*) from public.bonus_payments) as bonus,
       (select count(*) from public.finance_log) as logs, (select count(*) from public.salary_history) as salaries,
       (select count(*) from public.app_settings) as settings;
