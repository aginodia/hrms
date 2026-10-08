-- =====================================================================
-- Altius HRMS — admin access, Non-EMD, KYC drafts, change requests,
-- employee portal
--
--  * profiles.member_type: 'employee' (in Employee Master Data) or
--    'non_employee' (has access but is not part of EMD / payroll).
--  * admin_set_admin: give / revoke admin access (management). Admins
--    use only the admin console. The base admin can't be revoked.
--  * kyc_drafts: what an employee saved on the KYC form without
--    submitting ("Save" keeps it, "Skip" keeps nothing).
--  * change_requests: after KYC is submitted, an employee asks to change
--    personal / bank / emergency details; nothing changes until an admin
--    approves.
--  * my_portal(): everything an employee may see about themselves
--    (profile, salary, monthly pay, bonus, variable, loans, KYC
--    summary, own change requests), respecting Team Access settings.
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.profiles
  add column if not exists member_type text not null default 'employee'
    check (member_type in ('employee', 'non_employee'));

-- ---------------------------------------------------------------------
-- Admin access (management) and Non-EMD
-- ---------------------------------------------------------------------
create or replace function public.admin_set_admin(p_user uuid, p_admin boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_email text;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own admin access'; end if;
  select email into v_email from public.profiles where id = p_user and status = 'active';
  if v_email is null then raise exception 'Only an active user can be given or lose admin access'; end if;
  if not p_admin and lower(v_email) = public.base_admin_email() then
    raise exception 'The base admin keeps admin access';
  end if;
  update public.profiles set role = case when p_admin then 'admin' else 'team' end where id = p_user;
  perform public._fin_log('emd', p_user, current_date,
    case when p_admin then 'Admin access given' else 'Admin access revoked' end, null, null);
end;
$$;

create or replace function public.admin_set_member_type(p_user uuid, p_type text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_type not in ('employee', 'non_employee') then raise exception 'Unknown type'; end if;
  update public.profiles set member_type = p_type where id = p_user and status = 'active';
  if not found then raise exception 'User not found'; end if;
  perform public._fin_log('emd', p_user, current_date,
    case when p_type = 'employee' then 'Moved to Employee Master Data' else 'Moved to Non-EMD' end, null, null);
end;
$$;

-- ---------------------------------------------------------------------
-- KYC drafts ("Save" on the KYC form)
-- ---------------------------------------------------------------------
create table if not exists public.kyc_drafts (
  employee_id  uuid primary key references public.profiles (id) on delete cascade,
  data         jsonb not null default '{}'::jsonb,
  saved_at     timestamptz not null default now()
);

create or replace function public.save_kyc_draft(p jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_prefix text := auth.uid()::text || '/';
  v_key    text;
  v_clean  jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.can_edit_kyc() then raise exception 'Your KYC is already submitted or approved'; end if;
  -- keep only known, non-empty fields; document paths must be in the person's own folder
  foreach v_key in array array['date_of_birth', 'bank_account_number', 'bank_ifsc', 'emergency_name',
                               'emergency_relationship', 'emergency_phone', 'aadhaar_path', 'pan_path',
                               'marksheet_10_path', 'marksheet_12_path', 'graduation_path', 'payslip_path',
                               'leave_letter_path'] loop
    if coalesce(trim(p ->> v_key), '') <> '' then
      if v_key like '%\_path' and left(p ->> v_key, length(v_prefix)) <> v_prefix then
        raise exception 'Invalid document path for %', v_key;
      end if;
      v_clean := v_clean || jsonb_build_object(v_key, trim(p ->> v_key));
    end if;
  end loop;
  insert into public.kyc_drafts (employee_id, data, saved_at) values (auth.uid(), v_clean, now())
  on conflict (employee_id) do update set data = excluded.data, saved_at = excluded.saved_at;
end;
$$;

-- ---------------------------------------------------------------------
-- Change requests (employee asks, admin approves)
-- ---------------------------------------------------------------------
create table if not exists public.change_requests (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  changes      jsonb not null,              -- {field: new value}
  previous     jsonb not null,              -- {field: value at request time}
  note         text,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  admin_note   text,
  created_at   timestamptz not null default now(),
  decided_by   uuid references public.profiles (id) on delete set null,
  decided_at   timestamptz
);
create index if not exists change_requests_emp_idx on public.change_requests (employee_id, created_at desc);

-- Fields an employee may ask to change, and where they live
create or replace function public._change_fields()
returns text[] language sql immutable as $$
  select array['full_name', 'phone', 'date_of_birth', 'bank_account_number', 'bank_ifsc',
               'emergency_name', 'emergency_relationship', 'emergency_phone'];
$$;

create or replace function public._current_details(p_user uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'full_name', p.full_name, 'phone', p.phone, 'date_of_birth', p.date_of_birth,
    'bank_account_number', k.bank_account_number, 'bank_ifsc', k.bank_ifsc,
    'emergency_name', k.emergency_name, 'emergency_relationship', k.emergency_relationship,
    'emergency_phone', k.emergency_phone)
  from public.profiles p left join public.kyc_submissions k on k.employee_id = p.id
  where p.id = p_user;
$$;

create or replace function public.request_profile_change(p_changes jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_cur  jsonb;
  v_new  jsonb := '{}'::jsonb;
  v_prev jsonb := '{}'::jsonb;
  v_key  text;
  v_val  text;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and status = 'active') then
    raise exception 'Only active users can request changes';
  end if;
  if exists (select 1 from public.change_requests where employee_id = v_uid and status = 'pending') then
    raise exception 'You already have a change request waiting for approval';
  end if;
  v_cur := public._current_details(v_uid);
  for v_key, v_val in select key, trim(value) from jsonb_each_text(coalesce(p_changes, '{}'::jsonb)) loop
    if not v_key = any (public._change_fields()) then raise exception 'This detail cannot be changed here: %', v_key; end if;
    if v_val = '' then raise exception 'A new value cannot be empty'; end if;
    if v_val is not distinct from (v_cur ->> v_key) then continue; end if;
    if v_key like 'bank_%' or v_key like 'emergency_%' then
      if not exists (select 1 from public.kyc_submissions where employee_id = v_uid) then
        raise exception 'Submit your KYC first — bank and emergency details come from it';
      end if;
    end if;
    if v_key = 'bank_ifsc' then v_val := upper(v_val); if v_val !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Invalid IFSC code'; end if; end if;
    if v_key = 'bank_account_number' and v_val !~ '^[0-9]{9,18}$' then raise exception 'Invalid bank account number'; end if;
    if v_key = 'date_of_birth' then
      if v_val::date > current_date - interval '14 years' or v_val::date < date '1940-01-01' then raise exception 'Invalid date of birth'; end if;
    end if;
    v_new := v_new || jsonb_build_object(v_key, v_val);
    v_prev := v_prev || jsonb_build_object(v_key, v_cur -> v_key);
  end loop;
  if v_new = '{}'::jsonb then raise exception 'Nothing has changed'; end if;
  insert into public.change_requests (employee_id, changes, previous, note)
  values (v_uid, v_new, v_prev, nullif(trim(p_note), ''))
  returning id into v_id;
  perform public._fin_log('emd', v_uid, current_date, 'Change requested by employee', null, jsonb_build_object('request_id', v_id, 'fields', (select jsonb_agg(k) from jsonb_object_keys(v_new) k)));
  return v_id;
end;
$$;

create or replace function public.withdraw_change_request(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.change_requests set status = 'withdrawn', decided_at = now()
   where id = p_id and employee_id = auth.uid() and status = 'pending';
  if not found then raise exception 'This request is no longer waiting'; end if;
end;
$$;

create or replace function public.admin_decide_change(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare
  r public.change_requests;
  c jsonb;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into r from public.change_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'This request is no longer waiting'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Write why the change is rejected'; end if;
  if p_approve then
    c := r.changes;
    update public.profiles
       set full_name     = coalesce(c ->> 'full_name', full_name),
           phone         = coalesce(c ->> 'phone', phone),
           date_of_birth = coalesce((c ->> 'date_of_birth')::date, date_of_birth)
     where id = r.employee_id;
    update public.kyc_submissions
       set bank_account_number    = coalesce(c ->> 'bank_account_number', bank_account_number),
           bank_ifsc              = coalesce(c ->> 'bank_ifsc', bank_ifsc),
           emergency_name         = coalesce(c ->> 'emergency_name', emergency_name),
           emergency_relationship = coalesce(c ->> 'emergency_relationship', emergency_relationship),
           emergency_phone        = coalesce(c ->> 'emergency_phone', emergency_phone),
           updated_at             = now()
     where employee_id = r.employee_id;
  end if;
  update public.change_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  perform public._fin_log('emd', r.employee_id, current_date,
    case when p_approve then 'Change request approved' else 'Change request rejected' end, null,
    jsonb_build_object('request_id', p_id, 'changes', r.changes, 'note', nullif(trim(p_note), '')));
end;
$$;

-- ---------------------------------------------------------------------
-- Employee portal: one call, only the caller's own data
-- Team Access: job_details, salary, kyc_documents (existing switches);
-- pay (monthly payroll) and finance (bonus, variable, loans) — on unless
-- switched off.
-- ---------------------------------------------------------------------
create or replace function public.my_portal()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v jsonb := coalesce((select value from public.app_settings where key = 'team_visibility'), '{}'::jsonb);
  see_job boolean := coalesce((v ->> 'job_details')::boolean, false);
  see_sal boolean := coalesce((v ->> 'salary')::boolean, false);
  see_kyc boolean := coalesce((v ->> 'kyc_documents')::boolean, false);
  see_pay boolean := coalesce((v ->> 'pay')::boolean, true);
  see_fin boolean := coalesce((v ->> 'finance')::boolean, true);
  p public.profiles;
  k public.kyc_submissions;
begin
  select * into p from public.profiles where id = v_uid;
  if p.id is null then return null; end if;
  select * into k from public.kyc_submissions where employee_id = v_uid;
  return jsonb_build_object(
    'visibility', jsonb_build_object('job_details', see_job, 'salary', see_sal, 'kyc_documents', see_kyc, 'pay', see_pay, 'finance', see_fin),
    'profile', jsonb_build_object(
      'full_name', p.full_name, 'email', p.email, 'phone', p.phone, 'date_of_birth', p.date_of_birth,
      'kyc_status', p.kyc_status, 'kyc_remarks', p.kyc_remarks, 'member_type', p.member_type,
      'employee_code', case when see_job then p.employee_code end,
      'designation', case when see_job then p.designation end,
      'date_of_joining', case when see_job then p.date_of_joining end,
      'reporting_manager_name', case when see_job then (select full_name from public.profiles m where m.id = p.reporting_manager_id) end),
    'kyc', case when k.employee_id is null then null else jsonb_build_object(
      'bank_account_number', k.bank_account_number, 'bank_ifsc', k.bank_ifsc,
      'emergency_name', k.emergency_name, 'emergency_relationship', k.emergency_relationship, 'emergency_phone', k.emergency_phone,
      'submitted_at', k.submitted_at,
      'documents', case when see_kyc then jsonb_build_object(
        'aadhaar_path', k.aadhaar_path, 'pan_path', k.pan_path, 'marksheet_10_path', k.marksheet_10_path,
        'marksheet_12_path', k.marksheet_12_path, 'graduation_path', k.graduation_path,
        'payslip_path', k.payslip_path, 'leave_letter_path', k.leave_letter_path) end) end,
    'salary', case when see_sal then coalesce((select jsonb_agg(jsonb_build_object('effective_month', s.effective_month, 'amount', s.amount) order by s.effective_month)
                from public.salary_history s where s.employee_id = v_uid and s.removed_at is null), '[]'::jsonb) end,
    'pay', case when see_pay then coalesce((select jsonb_agg(jsonb_build_object(
                'month', r.month, 'monthly_salary', x.monthly_salary, 'full', x.post_full, 'half', x.post_half, 'leave', x.post_leave,
                'weekly_off', x.post_weekly_off, 'earned', x.payable, 'pt', x.pt, 'net', x.net_payable) order by r.month desc)
              from public.payroll_results x join public.payroll_runs r on r.id = x.run_id
             where x.employee_id = v_uid and x.included and r.superseded_at is null and r.processed_at is not null), '[]'::jsonb) end,
    'bonus', case when see_fin then coalesce((select jsonb_agg(jsonb_build_object('date', coalesce(b.pay_date, b.pay_month), 'description', b.description,
                'amount', b.amount, 'loan_deduction', b.loan_deduction) order by coalesce(b.pay_date, b.pay_month) desc)
              from public.bonus_payments b where b.employee_id = v_uid and b.removed_at is null), '[]'::jsonb) end,
    'variable', case when see_fin then coalesce((select jsonb_agg(jsonb_build_object('month', vp.pay_month, 'amount', vp.amount,
                'loan_deduction', vp.loan_deduction, 'remarks', vp.remarks) order by vp.pay_month desc)
              from public.variable_payouts vp where vp.employee_id = v_uid and vp.removed_at is null), '[]'::jsonb) end,
    'loans', case when see_fin then coalesce((select jsonb_agg(jsonb_build_object('taken_on', l.taken_on, 'amount', l.amount,
                'remaining', public.loan_remaining(l.id)) order by l.taken_on desc)
              from public.loans l where l.employee_id = v_uid and l.removed_at is null), '[]'::jsonb) end,
    'draft', (select jsonb_build_object('data', d.data, 'saved_at', d.saved_at) from public.kyc_drafts d where d.employee_id = v_uid),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'changes', c.changes, 'previous', c.previous, 'note', c.note,
                'status', c.status, 'admin_note', c.admin_note, 'created_at', c.created_at, 'decided_at', c.decided_at) order by c.created_at desc)
              from public.change_requests c where c.employee_id = v_uid), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- RLS, grants
-- ---------------------------------------------------------------------
alter table public.kyc_drafts      enable row level security;
alter table public.change_requests enable row level security;

do $do$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'kyc_drafts' and policyname = 'kyc_drafts_select') then
    create policy kyc_drafts_select on public.kyc_drafts for select to authenticated using (employee_id = auth.uid() or public.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'change_requests' and policyname = 'change_requests_select') then
    create policy change_requests_select on public.change_requests for select to authenticated using (employee_id = auth.uid() or public.is_admin());
  end if;
end
$do$;

grant select on public.kyc_drafts, public.change_requests to authenticated;

revoke execute on function public.admin_set_admin(uuid, boolean) from public, anon;
revoke execute on function public.admin_set_member_type(uuid, text) from public, anon;
revoke execute on function public.save_kyc_draft(jsonb) from public, anon;
revoke execute on function public._current_details(uuid) from public, anon, authenticated;
revoke execute on function public.request_profile_change(jsonb, text) from public, anon;
revoke execute on function public.withdraw_change_request(uuid) from public, anon;
revoke execute on function public.admin_decide_change(uuid, boolean, text) from public, anon;
revoke execute on function public.my_portal() from public, anon;
grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;
grant execute on function public.admin_set_member_type(uuid, text) to authenticated;
grant execute on function public.save_kyc_draft(jsonb) to authenticated;
grant execute on function public.request_profile_change(jsonb, text) to authenticated;
grant execute on function public.withdraw_change_request(uuid) to authenticated;
grant execute on function public.admin_decide_change(uuid, boolean, text) to authenticated;
grant execute on function public.my_portal() to authenticated;
