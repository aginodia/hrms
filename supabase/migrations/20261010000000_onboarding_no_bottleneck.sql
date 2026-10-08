-- =====================================================================
-- Altius HRMS — onboarding without a bottleneck
--
--  * "Give access" (or Admin → Add employee) puts the person straight
--    into Employee Master Data (status 'active') with a date of joining
--    and optional EID / designation / manager / starting salary.
--  * KYC no longer blocks anything. profiles.kyc_status tracks it:
--      not_started → submitted → approved   (or sent_back → submitted)
--    The employee sees the KYC form when they sign in and can skip it
--    and finish it later from their portal.
--  * admin_set_employee_code: assign / change the Employee ID on its own
--    (recorded in the log) so the payroll mapping can use it right away.
--    IDs are unique ignoring case and leading zeros (0007 = 007), as in payroll.
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.profiles
  add column if not exists kyc_status text not null default 'not_started'
    check (kyc_status in ('not_started', 'submitted', 'sent_back', 'approved'));

-- Existing people: approved actives and admins are done; people who were
-- mid-onboarding move into the HRMS with their KYC state carried over.
do $do$
begin
  if not exists (select 1 from public.profiles where kyc_status <> 'not_started') then
    update public.profiles set kyc_status = 'approved' where status = 'active' or role = 'admin';
    update public.profiles
       set kyc_status = case when kyc_remarks is not null then 'sent_back'
                             when exists (select 1 from public.kyc_submissions k where k.employee_id = profiles.id) then 'sent_back'
                             else 'not_started' end,
           status = 'active',
           date_of_joining = coalesce(date_of_joining, access_granted_at::date, current_date)
     where status = 'kyc_pending';
    update public.profiles
       set kyc_status = 'submitted', status = 'active',
           date_of_joining = coalesce(date_of_joining, access_granted_at::date, current_date)
     where status = 'kyc_submitted';
  end if;
end
$do$;

-- The employee may upload / submit KYC while it is not submitted or was sent back
create or replace function public.can_edit_kyc()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid()
       and ((status = 'active' and kyc_status in ('not_started', 'sent_back')) or status = 'kyc_pending')
  );
$$;

alter policy kyc_files_insert_own on storage.objects with check (
  bucket_id = 'kyc-documents' and (storage.foldername(name))[1] = auth.uid()::text and public.can_edit_kyc());
alter policy kyc_files_update_own on storage.objects using (
  bucket_id = 'kyc-documents' and (storage.foldername(name))[1] = auth.uid()::text and public.can_edit_kyc());
alter policy kyc_files_delete_own on storage.objects using (
  bucket_id = 'kyc-documents' and (storage.foldername(name))[1] = auth.uid()::text and public.can_edit_kyc());
alter policy kyc_files_select_own on storage.objects using (
  bucket_id = 'kyc-documents' and (storage.foldername(name))[1] = auth.uid()::text
  and (public.can_edit_kyc() or public.my_status() <> 'active' or public.team_can_see('kyc_documents')));
alter policy kyc_select_own on public.kyc_submissions using (
  employee_id = auth.uid()
  and (public.can_edit_kyc() or public.my_status() <> 'active' or public.team_can_see('kyc_documents')));

-- ---------------------------------------------------------------------
-- Give access → straight into Employee Master Data
-- ---------------------------------------------------------------------
create or replace function public.admin_give_access(
  p_user uuid, p_doj date default null, p_employee_code text default null, p_designation text default null,
  p_manager uuid default null, p_salary_month date default null, p_salary numeric default null
)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_manager = p_user then raise exception 'An employee cannot report to themselves'; end if;
  if nullif(trim(p_employee_code), '') is not null
     and exists (select 1 from public.profiles where public.norm_emp_code(employee_code) = public.norm_emp_code(p_employee_code) and id <> p_user) then
    raise exception 'Employee ID % is already used by someone else', trim(p_employee_code);
  end if;

  update public.profiles
     set status               = 'active',
         kyc_status           = case when kyc_status = 'approved' then kyc_status else 'not_started' end,
         date_of_joining      = coalesce(p_doj, current_date),
         employee_code        = nullif(trim(p_employee_code), ''),
         designation          = nullif(trim(p_designation), ''),
         reporting_manager_id = p_manager,
         access_granted_at    = now(),
         access_granted_by    = auth.uid(),
         approved_at          = now(),
         approved_by          = auth.uid()
   where id = p_user and status in ('pending', 'kyc_pending', 'kyc_submitted');
  if not found then raise exception 'This request is no longer pending'; end if;

  if p_salary is not null and p_salary > 0 and p_salary_month is not null then
    insert into public.salary_history (employee_id, effective_month, amount, created_by)
    values (p_user, date_trunc('month', p_salary_month)::date, p_salary, auth.uid())
    on conflict (employee_id, effective_month)
      do update set amount = excluded.amount, removed_at = null, removed_by = null;
  end if;

  perform public._fin_log('emd', p_user, coalesce(p_doj, current_date), 'Access given — added to Employee Master Data', null,
    jsonb_build_object('date_of_joining', coalesce(p_doj, current_date), 'employee_code', nullif(trim(p_employee_code), '')));
end;
$$;

-- The old one-click "Give access" now does the same (joining date = today)
create or replace function public.admin_grant_access(p_user uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  perform public.admin_give_access(p_user, current_date);
end;
$$;

-- ---------------------------------------------------------------------
-- KYC — submitted any time; reviewed without blocking access
-- ---------------------------------------------------------------------
create or replace function public.submit_kyc(p jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_prefix text := auth.uid()::text || '/';
  v_key    text;
  v_dob    date;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not public.can_edit_kyc() then
    raise exception 'Your KYC is already submitted or approved';
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
     set kyc_status = 'submitted', kyc_submitted_at = now(), kyc_remarks = null, date_of_birth = v_dob,
         status = case when status = 'kyc_pending' then 'active' else status end
   where id = v_uid;
end;
$$;

create or replace function public.admin_verify_kyc(p_user uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.profiles set kyc_status = 'approved', kyc_remarks = null
   where id = p_user and kyc_status = 'submitted';
  if not found then raise exception 'This KYC is no longer awaiting review'; end if;
  perform public._fin_log('emd', p_user, current_date, 'KYC approved', null, null);
end;
$$;

create or replace function public.admin_send_back_kyc(p_user uuid, p_remarks text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_remarks), '') = '' then raise exception 'Write what needs to be fixed'; end if;
  update public.profiles set kyc_status = 'sent_back', kyc_remarks = trim(p_remarks)
   where id = p_user and kyc_status = 'submitted';
  if not found then raise exception 'This KYC is no longer awaiting review'; end if;
  perform public._fin_log('emd', p_user, current_date, 'KYC sent back', null, jsonb_build_object('remarks', trim(p_remarks)));
end;
$$;

-- ---------------------------------------------------------------------
-- Employee ID on its own (EMD → Assign Emp ID)
-- ---------------------------------------------------------------------
create or replace function public.admin_set_employee_code(p_user uuid, p_code text)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_old text;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_code), '') = '' then raise exception 'Enter the Employee ID'; end if;
  if exists (select 1 from public.profiles where public.norm_emp_code(employee_code) = public.norm_emp_code(p_code) and id <> p_user) then
    raise exception 'Employee ID % is already used by someone else', trim(p_code);
  end if;
  select employee_code into v_old from public.profiles where id = p_user and status = 'active';
  if not found then raise exception 'Employee not found in master data'; end if;
  update public.profiles set employee_code = trim(p_code) where id = p_user;
  perform public._fin_log('emd', p_user, current_date,
    case when v_old is null then 'Employee ID assigned: ' || trim(p_code) else 'Employee ID changed: ' || v_old || ' → ' || trim(p_code) end,
    null, jsonb_build_object('old', v_old, 'new', trim(p_code)));
end;
$$;

revoke execute on function public.can_edit_kyc() from public, anon;
revoke execute on function public.admin_give_access(uuid, date, text, text, uuid, date, numeric) from public, anon;
revoke execute on function public.admin_verify_kyc(uuid) from public, anon;
revoke execute on function public.admin_set_employee_code(uuid, text) from public, anon;
grant execute on function public.can_edit_kyc() to authenticated;
grant execute on function public.admin_give_access(uuid, date, text, text, uuid, date, numeric) to authenticated;
grant execute on function public.admin_verify_kyc(uuid) to authenticated;
grant execute on function public.admin_set_employee_code(uuid, text) to authenticated;
