-- =====================================================================
--  Altius Investech HRMS — Supabase schema
--  Modules: 1) Sign up / Access control / KYC onboarding
--           2) Employee Master Data (EMD) + salary history
--
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  It is safe to re-run: every object is created with IF NOT EXISTS /
--  CREATE OR REPLACE, and policies are dropped before being re-created.
--
--  Access model (enforced in the database, not just the UI):
--    * role 'admin' — sees and manages everything, only through the
--      admin_* functions below.
--    * role 'team'  — sees only their own rows; can never change their
--      own role/status. The only write a team member can make is
--      submit_kyc() while their status is 'kyc_pending'.
--  No table has INSERT/UPDATE/DELETE policies for normal users; every
--  write goes through a SECURITY DEFINER function that checks the caller.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Base admin
-- ---------------------------------------------------------------------
create or replace function public.base_admin_email()
returns text
language sql
immutable
as $$ select 'sayan.mullick@altiusinvestech.com'::text $$;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- One row per auth user. Lifecycle of `status`:
--   pending        signed up, waiting for admin to give access / reject
--   kyc_pending    access given, employee must fill the KYC form
--   kyc_submitted  KYC submitted, waiting for admin approval
--   active         approved — can use the HRMS
--   inactive       (reserved for exits / offboarding)
-- A rejected sign-up is deleted outright (the sign-up is cancelled).
create table if not exists public.profiles (
  id                    uuid primary key references auth.users (id) on delete cascade,
  full_name             text not null,
  email                 text not null unique,
  phone                 text,
  role                  text not null default 'team'
                          check (role in ('admin', 'team')),
  status                text not null default 'pending'
                          check (status in ('pending', 'kyc_pending', 'kyc_submitted', 'active', 'inactive')),
  employee_code         text unique,               -- EID
  designation           text,
  reporting_manager_id  uuid references public.profiles (id) on delete set null,
  date_of_joining       date,
  date_of_birth         date,
  kyc_remarks           text,                      -- note from admin when KYC is sent back
  access_granted_at     timestamptz,
  access_granted_by     uuid references public.profiles (id) on delete set null,
  kyc_submitted_at      timestamptz,
  approved_at           timestamptz,
  approved_by           uuid references public.profiles (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists profiles_status_idx on public.profiles (status);

-- KYC submitted by the employee during onboarding (one row per employee).
-- *_path columns hold object paths inside the private `kyc-documents` bucket.
create table if not exists public.kyc_submissions (
  employee_id             uuid primary key references public.profiles (id) on delete cascade,
  aadhaar_path            text not null,
  pan_path                text not null,
  marksheet_10_path       text not null,
  marksheet_12_path       text not null,
  graduation_path         text not null,
  payslip_path            text,                    -- optional
  leave_letter_path       text,                    -- optional
  bank_account_number     text not null,
  bank_ifsc               text not null,
  emergency_name          text not null,
  emergency_relationship  text not null,
  emergency_phone         text not null,
  submitted_at            timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- Salary revisions. Each row means "from this month onwards the salary is X".
-- The row with the latest effective_month is the current salary.
create table if not exists public.salary_history (
  id               bigint generated always as identity primary key,
  employee_id      uuid not null references public.profiles (id) on delete cascade,
  effective_month  date not null check (extract(day from effective_month) = 1),
  amount           numeric(12, 2) not null check (amount >= 0),
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  unique (employee_id, effective_month)
);

create index if not exists salary_history_employee_idx
  on public.salary_history (employee_id, effective_month desc);

-- Key/value settings controlled by admin.
-- 'team_visibility' decides what team members can see about themselves.
create table if not exists public.app_settings (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now()
);

insert into public.app_settings (key, value)
values ('team_visibility', '{"job_details": true, "salary": false, "kyc_documents": true}'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Helper functions (SECURITY DEFINER so they can be used inside RLS
--    policies without recursing into the profiles policies)
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and status = 'active'
  );
$$;

create or replace function public.my_status()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select status from public.profiles where id = auth.uid();
$$;

create or replace function public.team_can_see(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value ->> p_key)::boolean
                   from public.app_settings where key = 'team_visibility'), false);
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists kyc_touch on public.kyc_submissions;
create trigger kyc_touch before update on public.kyc_submissions
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 3. New sign-up → profile row
--    The base admin email becomes an active admin; everyone else starts
--    as a pending team member that shows up in Admin → Access Control.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email    text := lower(new.email);
  v_is_admin boolean := lower(new.email) = public.base_admin_email();
begin
  insert into public.profiles (id, full_name, email, phone, role, status)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
             case when v_is_admin then 'Sayan Mullick' else split_part(v_email, '@', 1) end),
    v_email,
    nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
    case when v_is_admin then 'admin' else 'team' end,
    case when v_is_admin then 'active' else 'pending' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.kyc_submissions enable row level security;
alter table public.salary_history  enable row level security;
alter table public.app_settings    enable row level security;

-- profiles: a team member reads only their own row; admin reads all.
drop policy if exists profiles_select_own   on public.profiles;
drop policy if exists profiles_select_admin on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_select_admin on public.profiles
  for select to authenticated using (public.is_admin());

-- kyc_submissions: own row while onboarding, afterwards only if admin
-- allows it in Team Access settings; admin reads all.
drop policy if exists kyc_select_own   on public.kyc_submissions;
drop policy if exists kyc_select_admin on public.kyc_submissions;
create policy kyc_select_own on public.kyc_submissions
  for select to authenticated using (
    employee_id = auth.uid()
    and (public.my_status() <> 'active' or public.team_can_see('kyc_documents'))
  );
create policy kyc_select_admin on public.kyc_submissions
  for select to authenticated using (public.is_admin());

-- salary_history: own rows only if admin allows it; admin reads all.
drop policy if exists salary_select_own   on public.salary_history;
drop policy if exists salary_select_admin on public.salary_history;
create policy salary_select_own on public.salary_history
  for select to authenticated using (
    employee_id = auth.uid()
    and public.my_status() = 'active'
    and public.team_can_see('salary')
  );
create policy salary_select_admin on public.salary_history
  for select to authenticated using (public.is_admin());

-- app_settings: everyone signed in can read; only admin can change.
drop policy if exists settings_select on public.app_settings;
drop policy if exists settings_admin_write on public.app_settings;
create policy settings_select on public.app_settings
  for select to authenticated using (true);
create policy settings_admin_write on public.app_settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 5. Storage — private bucket for KYC documents (PDF / JPG, max 5 MB)
--    Object path convention: <user_id>/<document>-<timestamp>.<ext>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kyc-documents', 'kyc-documents', false, 5242880,
        array['application/pdf', 'image/jpeg', 'image/jpg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists kyc_files_insert_own   on storage.objects;
drop policy if exists kyc_files_update_own   on storage.objects;
drop policy if exists kyc_files_delete_own   on storage.objects;
drop policy if exists kyc_files_select_own   on storage.objects;
drop policy if exists kyc_files_select_admin on storage.objects;
drop policy if exists kyc_files_delete_admin on storage.objects;

-- Team member can upload / replace files in their own folder only while
-- filling the KYC form.
create policy kyc_files_insert_own on storage.objects
  for insert to authenticated with check (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.my_status() = 'kyc_pending'
  );
create policy kyc_files_update_own on storage.objects
  for update to authenticated using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.my_status() = 'kyc_pending'
  );
create policy kyc_files_delete_own on storage.objects
  for delete to authenticated using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.my_status() = 'kyc_pending'
  );
create policy kyc_files_select_own on storage.objects
  for select to authenticated using (
    bucket_id = 'kyc-documents'
    and (storage.foldername(name))[1] = auth.uid()::text
    and (public.my_status() <> 'active' or public.team_can_see('kyc_documents'))
  );
create policy kyc_files_select_admin on storage.objects
  for select to authenticated using (bucket_id = 'kyc-documents' and public.is_admin());
create policy kyc_files_delete_admin on storage.objects
  for delete to authenticated using (bucket_id = 'kyc-documents' and public.is_admin());

-- ---------------------------------------------------------------------
-- 6. Functions the app calls (RPC)
-- ---------------------------------------------------------------------

-- Admin → Access Control → Give access
create or replace function public.admin_grant_access(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.profiles
     set status = 'kyc_pending', access_granted_at = now(), access_granted_by = auth.uid()
   where id = p_user and status = 'pending';
  if not found then raise exception 'This request is no longer pending'; end if;
end;
$$;

-- Admin → Access Control → Reject: cancels the sign-up entirely
create or replace function public.admin_reject_signup(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.profiles where id = p_user and status = 'pending') then
    raise exception 'This request is no longer pending';
  end if;
  delete from auth.users where id = p_user;   -- cascades to profiles
end;
$$;

-- Employee → KYC form → Submit
-- Files are uploaded to storage first; this stores the paths + details and
-- moves the employee to 'kyc_submitted'.
create or replace function public.submit_kyc(p jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_prefix text := auth.uid()::text || '/';
  v_key    text;
  v_dob    date;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if public.my_status() is distinct from 'kyc_pending' then
    raise exception 'KYC can only be submitted after access is given and before approval';
  end if;

  foreach v_key in array array['aadhaar_path', 'pan_path', 'marksheet_10_path', 'marksheet_12_path',
                               'graduation_path', 'bank_account_number', 'bank_ifsc',
                               'emergency_name', 'emergency_relationship', 'emergency_phone',
                               'date_of_birth'] loop
    if coalesce(trim(p ->> v_key), '') = '' then
      raise exception 'Missing required field: %', v_key;
    end if;
  end loop;

  foreach v_key in array array['aadhaar_path', 'pan_path', 'marksheet_10_path', 'marksheet_12_path',
                               'graduation_path', 'payslip_path', 'leave_letter_path'] loop
    if nullif(p ->> v_key, '') is not null and left(p ->> v_key, length(v_prefix)) <> v_prefix then
      raise exception 'Invalid document path for %', v_key;
    end if;
  end loop;

  if upper(trim(p ->> 'bank_ifsc')) !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then
    raise exception 'Invalid IFSC code';
  end if;
  if trim(p ->> 'bank_account_number') !~ '^[0-9]{9,18}$' then
    raise exception 'Invalid bank account number';
  end if;

  v_dob := (p ->> 'date_of_birth')::date;
  if v_dob > current_date - interval '14 years' or v_dob < date '1940-01-01' then
    raise exception 'Invalid date of birth';
  end if;

  insert into public.kyc_submissions as k (
    employee_id, aadhaar_path, pan_path, marksheet_10_path, marksheet_12_path, graduation_path,
    payslip_path, leave_letter_path, bank_account_number, bank_ifsc,
    emergency_name, emergency_relationship, emergency_phone, submitted_at
  ) values (
    v_uid, p ->> 'aadhaar_path', p ->> 'pan_path', p ->> 'marksheet_10_path',
    p ->> 'marksheet_12_path', p ->> 'graduation_path',
    nullif(p ->> 'payslip_path', ''), nullif(p ->> 'leave_letter_path', ''),
    trim(p ->> 'bank_account_number'), upper(trim(p ->> 'bank_ifsc')),
    trim(p ->> 'emergency_name'), trim(p ->> 'emergency_relationship'),
    trim(p ->> 'emergency_phone'), now()
  )
  on conflict (employee_id) do update set
    aadhaar_path           = excluded.aadhaar_path,
    pan_path               = excluded.pan_path,
    marksheet_10_path      = excluded.marksheet_10_path,
    marksheet_12_path      = excluded.marksheet_12_path,
    graduation_path        = excluded.graduation_path,
    payslip_path           = excluded.payslip_path,
    leave_letter_path      = excluded.leave_letter_path,
    bank_account_number    = excluded.bank_account_number,
    bank_ifsc              = excluded.bank_ifsc,
    emergency_name         = excluded.emergency_name,
    emergency_relationship = excluded.emergency_relationship,
    emergency_phone        = excluded.emergency_phone,
    submitted_at           = excluded.submitted_at;

  update public.profiles
     set status = 'kyc_submitted', kyc_submitted_at = now(), kyc_remarks = null,
         date_of_birth = v_dob
   where id = v_uid;
end;
$$;

-- Admin → Access Control → KYC review → Approve
-- Moves the employee into Employee Master Data.
create or replace function public.admin_approve_kyc(
  p_user          uuid,
  p_doj           date,
  p_employee_code text default null,
  p_designation   text default null,
  p_manager       uuid default null,
  p_salary_month  date default null,
  p_salary        numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_doj is null then raise exception 'Date of joining is required'; end if;
  if p_manager = p_user then raise exception 'An employee cannot report to themselves'; end if;

  update public.profiles
     set status               = 'active',
         date_of_joining      = p_doj,
         employee_code        = nullif(trim(p_employee_code), ''),
         designation          = nullif(trim(p_designation), ''),
         reporting_manager_id = p_manager,
         kyc_remarks          = null,
         approved_at          = now(),
         approved_by          = auth.uid()
   where id = p_user and status = 'kyc_submitted';
  if not found then raise exception 'This KYC is no longer awaiting approval'; end if;

  if p_salary is not null and p_salary_month is not null then
    insert into public.salary_history (employee_id, effective_month, amount, created_by)
    values (p_user, date_trunc('month', p_salary_month)::date, p_salary, auth.uid())
    on conflict (employee_id, effective_month) do update set amount = excluded.amount;
  end if;
end;
$$;

-- Admin → Access Control → KYC review → Send back (employee must re-submit)
create or replace function public.admin_send_back_kyc(p_user uuid, p_remarks text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.profiles
     set status = 'kyc_pending', kyc_remarks = nullif(trim(p_remarks), '')
   where id = p_user and status = 'kyc_submitted';
  if not found then raise exception 'This KYC is no longer awaiting approval'; end if;
end;
$$;

-- Admin → EMD → Detailed info → Save
-- Saves the editable fields and replaces the salary history in one
-- transaction. p_salaries: [{"month": "2026-05-01", "amount": 20000}, ...]
create or replace function public.admin_save_employee(
  p_user          uuid,
  p_employee_code text,
  p_designation   text,
  p_manager       uuid,
  p_salaries      jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_months date[];
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_manager = p_user then raise exception 'An employee cannot report to themselves'; end if;
  if jsonb_typeof(coalesce(p_salaries, '[]'::jsonb)) <> 'array' then
    raise exception 'Salaries must be a list';
  end if;

  update public.profiles
     set employee_code        = nullif(trim(p_employee_code), ''),
         designation          = nullif(trim(p_designation), ''),
         reporting_manager_id = p_manager
   where id = p_user and status in ('active', 'inactive');
  if not found then raise exception 'Employee not found in master data'; end if;

  select array_agg(date_trunc('month', (s ->> 'month')::date)::date)
    into v_months
    from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s;

  if v_months is not null and cardinality(v_months) <> (select count(distinct m) from unnest(v_months) m) then
    raise exception 'Each month can only have one salary entry';
  end if;

  delete from public.salary_history
   where employee_id = p_user
     and (v_months is null or effective_month <> all (v_months));

  insert into public.salary_history (employee_id, effective_month, amount, created_by)
  select p_user, date_trunc('month', (s ->> 'month')::date)::date, (s ->> 'amount')::numeric, auth.uid()
    from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s
  on conflict (employee_id, effective_month) do update set amount = excluded.amount;
end;
$$;

-- Team → My profile: own profile plus reporting manager's name
-- (a team member cannot read other profiles directly).
create or replace function public.my_profile()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(p) || jsonb_build_object('reporting_manager_name', m.full_name)
    from public.profiles p
    left join public.profiles m on m.id = p.reporting_manager_id
   where p.id = auth.uid();
$$;

-- Only signed-in users may call the functions; each one checks the caller.
revoke execute on function public.admin_grant_access(uuid) from public, anon;
revoke execute on function public.admin_reject_signup(uuid) from public, anon;
revoke execute on function public.submit_kyc(jsonb) from public, anon;
revoke execute on function public.admin_approve_kyc(uuid, date, text, text, uuid, date, numeric) from public, anon;
revoke execute on function public.admin_send_back_kyc(uuid, text) from public, anon;
revoke execute on function public.admin_save_employee(uuid, text, text, uuid, jsonb) from public, anon;
revoke execute on function public.my_profile() from public, anon;

grant execute on function public.admin_grant_access(uuid) to authenticated;
grant execute on function public.admin_reject_signup(uuid) to authenticated;
grant execute on function public.submit_kyc(jsonb) to authenticated;
grant execute on function public.admin_approve_kyc(uuid, date, text, text, uuid, date, numeric) to authenticated;
grant execute on function public.admin_send_back_kyc(uuid, text) to authenticated;
grant execute on function public.admin_save_employee(uuid, text, text, uuid, jsonb) to authenticated;
grant execute on function public.my_profile() to authenticated;

grant select on public.profiles, public.kyc_submissions, public.salary_history, public.app_settings to authenticated;
grant update on public.app_settings to authenticated;

-- Backfill: anyone who signed up before this script ran gets a profile
-- (the base admin as active admin, everyone else as a pending request).
insert into public.profiles (id, full_name, email, phone, role, status)
select u.id,
       coalesce(nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''), split_part(lower(u.email), '@', 1)),
       lower(u.email),
       nullif(trim(u.raw_user_meta_data ->> 'phone'), ''),
       case when lower(u.email) = public.base_admin_email() then 'admin' else 'team' end,
       case when lower(u.email) = public.base_admin_email() then 'active' else 'pending' end
  from auth.users u
 where u.email is not null
   and not exists (select 1 from public.profiles p where p.id = u.id);

update public.profiles
   set role = 'admin', status = 'active'
 where email = public.base_admin_email();
