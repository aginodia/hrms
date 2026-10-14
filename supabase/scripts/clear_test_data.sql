-- =====================================================================
-- Altius HRMS — clear all test / dummy data (run ONCE, by hand, in the
-- Supabase SQL Editor). This is NOT a migration and changes no setting.
-- It cannot be undone.
--
-- Keeps:  the logins listed in KEEP below (with their Employee ID and
--         admin rights), and the setup:
--           app_settings (company, PT slabs, attendance rules, ESOP,
--           Drive, team visibility, expense link), app_secrets (Drive
--           ticket), doc_assets (signature / letterhead), job_roles
--           (Role Definition), calendar_days (holidays), pre-onboarding
--           materials and question bank.
-- Clears: every other login and everything that is records rather than
--         setup — KYC, salaries (the kept admins' too), payroll uploads,
--         punches, code mappings, adjustments, results, queries, leaves,
--         WFH, variable, bonus, loans, eligibility, expenses, ESOP
--         allocations / grants / vesting / exercises, appraisals,
--         feedback, resignations, exits, F&F, HR documents, bank details, change
--         requests, pre-onboarding candidates and the activity log.
-- =====================================================================
begin;

-- Logins to keep (lower case). Add an email here to keep that person.
create temp table keep_users on commit drop as
select id from auth.users where lower(email) in (
  'sayan.mullick@altiusinvestech.com',
  'aginodia@gmail.com'
);
do $$ begin
  if (select count(*) from keep_users) = 0 then raise exception 'No login to keep was found — stopping, nothing deleted'; end if;
end $$;

-- Payroll and attendance
delete from public.payroll_queries;
delete from public.payroll_results;
delete from public.attendance_adjustments;
delete from public.attendance_punches;
delete from public.attendance_code_map;
delete from public.payroll_runs;

-- Finance
delete from public.loan_repayments;
delete from public.loan_deductions;
delete from public.loans;
delete from public.variable_payouts;
delete from public.variable_uploads;
delete from public.variable_entries;
delete from public.bonus_payments;
delete from public.expense_claims;
delete from public.comp_eligibility;
delete from public.salary_history;
delete from public.finance_log;

-- ESOP
delete from public.esop_exercises;
delete from public.esop_vesting;
delete from public.esop_grants;
delete from public.esop_allocations;

-- Leave, WFH, appraisals, feedback
delete from public.leave_records;
delete from public.leave_requests;
delete from public.wfh_days;
delete from public.appraisal_events;
delete from public.appraisals;
delete from public.feedback;

-- Profile changes, KYC, exits, documents
delete from public.change_requests;
do $$ begin if to_regclass('public.bank_requests') is not null then execute 'delete from public.bank_requests'; end if; end $$;
do $$ begin if to_regclass('public.bank_details') is not null then execute 'delete from public.bank_details'; end if; end $$;
delete from public.kyc_drafts;
delete from public.kyc_submissions;
delete from public.resignation_requests;
delete from public.fnf_settlements;
delete from public.exit_documents;
delete from public.hr_documents;

-- Pre-onboarding candidates (materials and questions stay)
delete from public.preboard_views;
delete from public.preboard_attempts;
delete from public.preboard_candidates;

-- Every other login (removing the auth user also removes the profile)
delete from auth.users where id not in (select id from keep_users);

commit;

-- Check: users / profiles = number kept, records 0, settings 7
select (select count(*) from auth.users) as users, (select count(*) from public.profiles) as profiles,
       (select count(*) from public.attendance_punches) as punches, (select count(*) from public.salary_history) as salaries,
       (select count(*) from public.esop_grants) as esop_grants, (select count(*) from public.leave_requests) as leaves,
       (select count(*) from public.appraisals) as appraisals, (select count(*) from public.finance_log) as logs,
       (select count(*) from public.app_settings) as settings;

-- ---------------------------------------------------------------------
-- OPTIONAL — run separately only if these are test too:
--   delete from public.calendar_days;                          -- holidays / relaxation days
--   delete from public.preboard_materials;                     -- pre-onboarding materials
--   delete from public.preboard_questions;                     -- pre-onboarding question bank
--   delete from public.job_roles;                              -- Role Definition
-- Uploaded KYC files (bucket kyc-documents) can't be deleted with SQL:
-- Supabase Dashboard → Storage → kyc-documents → select all → Delete.
-- ---------------------------------------------------------------------
