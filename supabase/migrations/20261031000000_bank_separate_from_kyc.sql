-- =====================================================================
-- Altius HRMS — bank details separate from the KYC
--
--  * bank_details: the employee's approved salary account (one row each):
--    account number, IFSC, bank proof, when and by whom it was verified.
--  * Employees submit bank details (always with a bank proof) any time —
--    before, after or without the KYC — and HR approves them on their own.
--    The KYC no longer asks for bank details.
--  * Salary slips (my_payslips, my_exit) take the account from
--    bank_details (falling back to an older KYC record).
--  * Existing approved bank details are copied into bank_details.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create table if not exists public.bank_details (
  employee_id     uuid primary key references public.profiles (id) on delete cascade,
  account_number  text not null,
  ifsc            text not null,
  doc_path        text,
  verified_at     timestamptz not null default now(),
  verified_by     uuid references public.profiles (id) on delete set null
);
alter table public.bank_details enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_details' and policyname = 'bank_details_select_admin') then
    create policy bank_details_select_admin on public.bank_details for select to authenticated using (public.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_details' and policyname = 'bank_details_select_own') then
    create policy bank_details_select_own on public.bank_details for select to authenticated using (employee_id = auth.uid());
  end if;
end $$;

-- Approved bank details so far (kept on the KYC record) move here
insert into public.bank_details (employee_id, account_number, ifsc, doc_path, verified_at)
select k.employee_id, k.bank_account_number, k.bank_ifsc, k.bank_doc_path, coalesce(k.bank_verified_at, now())
  from public.kyc_submissions k
 where coalesce(k.bank_account_number, '') <> ''
   and exists (select 1 from public.bank_requests b where b.employee_id = k.employee_id and b.status = 'approved')
on conflict (employee_id) do nothing;

create or replace function public._bank_verified(p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.bank_details where employee_id = p_user); $$;

-- Last 4 digits of the salary account for slips
create or replace function public._bank_last4(p_user uuid)
returns text language sql stable security definer set search_path = public
as $$
  select right(coalesce((select account_number from public.bank_details where employee_id = p_user),
                        (select nullif(bank_account_number, '') from public.kyc_submissions where employee_id = p_user)), 4);
$$;


-- KYC: no bank details any more (they are submitted separately)
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
                               'graduation_path', 'emergency_name', 'emergency_relationship', 'emergency_phone',
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

  v_dob := (p ->> 'date_of_birth')::date;
  if v_dob > current_date - interval '14 years' or v_dob < date '1940-01-01' then
    raise exception 'Invalid date of birth';
  end if;

  insert into public.kyc_submissions as k (
    employee_id, aadhaar_path, pan_path, marksheet_10_path, marksheet_12_path, graduation_path,
    payslip_path, leave_letter_path, bank_account_number, bank_ifsc, bank_doc_path,
    emergency_name, emergency_relationship, emergency_phone, submitted_at
  ) values (
    v_uid, p ->> 'aadhaar_path', p ->> 'pan_path', p ->> 'marksheet_10_path',
    p ->> 'marksheet_12_path', p ->> 'graduation_path',
    nullif(p ->> 'payslip_path', ''), nullif(p ->> 'leave_letter_path', ''),
    coalesce((select account_number from public.bank_details where employee_id = v_uid), ''),
    coalesce((select ifsc from public.bank_details where employee_id = v_uid), ''),
    (select doc_path from public.bank_details where employee_id = v_uid),
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
    emergency_name         = excluded.emergency_name,
    emergency_relationship = excluded.emergency_relationship,
    emergency_phone        = excluded.emergency_phone,
    submitted_at           = excluded.submitted_at;

  -- Bank details wait for their own approval (an older waiting one is replaced)
  update public.profiles
     set kyc_status = 'submitted', kyc_submitted_at = now(), kyc_remarks = null, date_of_birth = v_dob,
         status = case when status = 'kyc_pending' then 'active' else status end
   where id = v_uid;
end;
$$;

-- Bank details any time, with a bank proof; no KYC needed
create or replace function public.submit_bank_details(p jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_acc  text := regexp_replace(coalesce(p ->> 'account_number', ''), '\s', '', 'g');
  v_ifsc text := upper(trim(coalesce(p ->> 'ifsc', '')));
  v_doc  text := nullif(trim(p ->> 'doc_path'), '');
  cur    public.bank_details;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and status = 'active') then raise exception 'Only active employees can do this'; end if;
  select * into cur from public.bank_details where employee_id = v_uid;
  if exists (select 1 from public.bank_requests where employee_id = v_uid and status = 'pending' and doc_path is not null) then
    raise exception 'Your bank details are already waiting for approval';
  end if;
  if v_acc !~ '^[0-9]{9,18}$' then raise exception 'Invalid bank account number'; end if;
  if v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Invalid IFSC code'; end if;
  if v_doc is null then raise exception 'Upload a bank proof (cancelled cheque, passbook or statement)'; end if;
  if left(v_doc, length(v_uid::text) + 1) <> v_uid::text || '/' then raise exception 'Invalid document path'; end if;
  -- Details waiting without a proof are replaced by this submission (which has one)
  update public.bank_requests set status = 'withdrawn', decided_at = now() where employee_id = v_uid and status = 'pending' and doc_path is null;
  insert into public.bank_requests (employee_id, account_number, ifsc, doc_path, previous, source, note)
  values (v_uid, v_acc, v_ifsc, v_doc,
          case when cur.employee_id is not null then jsonb_build_object('account_number', cur.account_number, 'ifsc', cur.ifsc) end,
          'change', nullif(trim(p ->> 'note'), ''))
  returning id into v_id;
  perform public._fin_log('emd', v_uid, current_date, 'Bank details submitted for approval', null, jsonb_build_object('request_id', v_id));
  return v_id;
end;
$$;

-- Approving fills bank_details (the salary account)
create or replace function public.admin_decide_bank(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.bank_requests;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into r from public.bank_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'These bank details are no longer waiting'; end if;
  if r.employee_id = auth.uid() then raise exception 'Another admin has to approve your own bank details'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Write what needs to be fixed'; end if;
  if p_approve and r.doc_path is null then raise exception 'There is no bank proof yet — send it back to ask for one'; end if;
  if p_approve then
    insert into public.bank_details (employee_id, account_number, ifsc, doc_path, verified_at, verified_by)
    values (r.employee_id, r.account_number, r.ifsc, r.doc_path, now(), auth.uid())
    on conflict (employee_id) do update set account_number = excluded.account_number, ifsc = excluded.ifsc,
      doc_path = excluded.doc_path, verified_at = excluded.verified_at, verified_by = excluded.verified_by;
    -- Kept in step on the KYC record too, if there is one
    update public.kyc_submissions
       set bank_account_number = r.account_number, bank_ifsc = r.ifsc,
           bank_doc_path = r.doc_path, bank_verified_at = now(), updated_at = now()
     where employee_id = r.employee_id;
  end if;
  update public.bank_requests
     set status = case when p_approve then 'approved' else 'sent_back' end,
         admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  perform public._fin_log('emd', r.employee_id, current_date,
    case when p_approve then 'Bank details approved' else 'Bank details sent back' end, null,
    jsonb_build_object('request_id', p_id, 'account_last4', right(r.account_number, 4), 'ifsc', r.ifsc, 'note', nullif(trim(p_note), '')));
end;
$$;

create or replace function public.admin_set_kyc_paths(p_employee uuid, p jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare v_key text; v_prefix text := p_employee::text || '/'; v_old text;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  for v_key in select jsonb_object_keys(p) loop
    if v_key not in ('aadhaar_path', 'pan_path', 'marksheet_10_path', 'marksheet_12_path', 'graduation_path', 'payslip_path', 'leave_letter_path', 'bank_doc_path') then
      raise exception 'Unknown document %', v_key;
    end if;
    if left(p ->> v_key, length(v_prefix)) <> v_prefix then raise exception 'Invalid document path for %', v_key; end if;
  end loop;
  select bank_doc_path into v_old from public.kyc_submissions where employee_id = p_employee;
  update public.kyc_submissions set
    aadhaar_path      = coalesce(p ->> 'aadhaar_path', aadhaar_path),
    pan_path          = coalesce(p ->> 'pan_path', pan_path),
    marksheet_10_path = coalesce(p ->> 'marksheet_10_path', marksheet_10_path),
    marksheet_12_path = coalesce(p ->> 'marksheet_12_path', marksheet_12_path),
    graduation_path   = coalesce(p ->> 'graduation_path', graduation_path),
    payslip_path      = coalesce(p ->> 'payslip_path', payslip_path),
    leave_letter_path = coalesce(p ->> 'leave_letter_path', leave_letter_path),
    bank_doc_path     = coalesce(p ->> 'bank_doc_path', bank_doc_path)
  where employee_id = p_employee;
  if not found then raise exception 'No KYC for this employee'; end if;
  if p ? 'bank_doc_path' and v_old is not null then
    update public.bank_requests set doc_path = p ->> 'bank_doc_path' where employee_id = p_employee and doc_path = v_old;
    update public.bank_details set doc_path = p ->> 'bank_doc_path' where employee_id = p_employee and doc_path = v_old;
  end if;
end;
$$;

-- Employee portal: + the approved bank details
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
  -- After leaving (resigned / terminated) only the exit summary is available
  if public._i_have_left() then return jsonb_build_object('left', true); end if;
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
        'payslip_path', k.payslip_path, 'leave_letter_path', k.leave_letter_path, 'bank_doc_path', k.bank_doc_path) end) end,
    'bank_current', (select jsonb_build_object('account_number', bd.account_number, 'ifsc', bd.ifsc, 'has_doc', bd.doc_path is not null, 'verified_at', bd.verified_at)
                       from public.bank_details bd where bd.employee_id = v_uid),
    'bank', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'account_number', b.account_number, 'ifsc', b.ifsc, 'has_doc', b.doc_path is not null,
                'source', b.source, 'note', b.note, 'status', b.status, 'admin_note', b.admin_note, 'created_at', b.created_at, 'decided_at', b.decided_at) order by b.created_at desc)
              from (select * from public.bank_requests where employee_id = v_uid order by created_at desc limit 10) b), '[]'::jsonb),
    'salary', case when see_sal then coalesce((select jsonb_agg(jsonb_build_object('effective_month', s.effective_month, 'amount', s.amount) order by s.effective_month)
                from public.salary_history s where s.employee_id = v_uid and s.removed_at is null), '[]'::jsonb) end,
    'pay', case when see_pay then coalesce((select jsonb_agg(jsonb_build_object(
                'month', r.month, 'monthly_salary', x.monthly_salary, 'full', x.post_full, 'half', x.post_half, 'leave', x.post_leave,
                'weekly_off', x.post_weekly_off, 'earned', x.payable, 'pt', x.pt, 'net', x.net_payable) order by r.month desc)
              from public.payroll_results x join public.payroll_runs r on r.id = x.run_id
             where x.employee_id = v_uid and x.included and r.superseded_at is null and r.pushed_at is not null), '[]'::jsonb) end,
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

-- Salary slips: account from bank_details
create or replace function public.my_payslips()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see_pay boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true);
        p public.profiles;
        v_acct text;
begin
  if not see_pay or public._i_have_left() then return '[]'::jsonb; end if;
  select * into p from public.profiles where id = auth.uid();
  v_acct := public._bank_last4(auth.uid());
  return coalesce((select jsonb_agg(jsonb_build_object(
      'run_id', r.id, 'month', r.month, 'pushed_at', r.pushed_at, 'last_pushed_at', r.last_pushed_at,
      'query_until', r.pushed_at + interval '12 hours',
      'sheet_open', now() <= r.pushed_at + interval '12 hours',
      'can_ask', (now() <= r.pushed_at + interval '12 hours') and not public._i_have_left(),
      'monthly_salary', x.monthly_salary, 'daily_salary', x.daily_salary,
      'full', x.post_full, 'half', x.post_half, 'leave', x.post_leave, 'weekly_off', x.post_weekly_off,
      'holidays', (select count(*) from jsonb_array_elements(coalesce(x.days, '[]'::jsonb)) d where d ->> 'status' = 'H'),
      'wfh', (select count(*) from jsonb_array_elements(coalesce(x.days, '[]'::jsonb)) d where d ->> 'status' = 'WFH'),
      'earned', x.payable, 'pt', x.pt, 'net', x.net_payable,
      'days', case when now() <= r.pushed_at + interval '12 hours' then x.days end,
      'employee', jsonb_build_object('full_name', p.full_name, 'employee_code', p.employee_code, 'designation', p.designation,
                                     'date_of_joining', p.date_of_joining, 'bank_last4', v_acct),
      'slip_file', (select d.drive_file_id from public.hr_documents d
                     where d.employee_id = auth.uid() and d.kind = 'salary_slip' and d.ref = to_char(r.month, 'YYYY-MM') and d.removed_at is null),
      'queries', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'date', q.work_date, 'current', q.current_status,
                  'requested', q.requested_status, 'note', q.note, 'status', q.status, 'admin_note', q.admin_note,
                  'created_at', q.created_at, 'decided_at', q.decided_at) order by q.work_date, q.created_at)
                from public.payroll_queries q where q.run_id = r.id and q.employee_id = auth.uid()), '[]'::jsonb)
    ) order by r.month desc)
    from public.payroll_results x join public.payroll_runs r on r.id = x.run_id
   where x.employee_id = auth.uid() and x.included and r.superseded_at is null and r.pushed_at is not null), '[]'::jsonb);
end;
$$;

create or replace function public.my_exit()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare p public.profiles; v_acct text;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then return null; end if;
  if not (p.employment_status in ('resigned', 'terminated') or p.fnf_completed_at is not null) then return jsonb_build_object('left', false); end if;
  if p.fnf_completed_at is not null and now() > p.fnf_completed_at + interval '3 days' then return jsonb_build_object('left', true, 'ended', true); end if;
  v_acct := public._bank_last4(p.id);
  return jsonb_build_object(
    'left', true, 'ended', false,
    'profile', jsonb_build_object('full_name', p.full_name, 'employee_code', p.employee_code, 'designation', p.designation,
      'date_of_joining', p.date_of_joining, 'employment_status', p.employment_status, 'resignation_date', p.resignation_date,
      'exit_date', p.exit_date, 'fnf_completed_at', p.fnf_completed_at,
      'settle_due', p.exit_date + 60,
      'access_until', case when p.fnf_completed_at is not null then p.fnf_completed_at + interval '3 days' end),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('kind', d.kind, 'file', d.drive_file_id, 'name', d.file_name, 'at', d.created_at))
                  from public.exit_documents d where d.employee_id = p.id and d.removed_at is null), '[]'::jsonb),
    'fnf', (select jsonb_build_object('settled_on', f.settled_on, 'items', f.items, 'net', f.net, 'note', f.note)
              from public.fnf_settlements f where f.employee_id = p.id),
    'payslips', coalesce((select jsonb_agg(x order by x ->> 'month' desc) from (
        select jsonb_build_object('run_id', r.id, 'month', r.month, 'monthly_salary', s.monthly_salary, 'daily_salary', s.daily_salary,
          'full', s.post_full, 'half', s.post_half, 'leave', s.post_leave, 'weekly_off', s.post_weekly_off,
          'holidays', (select count(*) from jsonb_array_elements(coalesce(s.days, '[]'::jsonb)) dd where dd ->> 'status' = 'H'),
          'wfh', (select count(*) from jsonb_array_elements(coalesce(s.days, '[]'::jsonb)) dd where dd ->> 'status' = 'WFH'),
          'earned', s.payable, 'pt', s.pt, 'net', s.net_payable,
          'employee', jsonb_build_object('full_name', p.full_name, 'employee_code', p.employee_code, 'designation', p.designation,
                                         'date_of_joining', p.date_of_joining, 'bank_last4', v_acct),
          'slip_file', (select d.drive_file_id from public.hr_documents d where d.employee_id = p.id and d.kind = 'salary_slip'
                          and d.ref = to_char(r.month, 'YYYY-MM') and d.removed_at is null)) as x
          from public.payroll_results s join public.payroll_runs r on r.id = s.run_id
         where s.employee_id = p.id and s.included and r.superseded_at is null and r.pushed_at is not null
         order by r.month desc limit 6) q), '[]'::jsonb));
end;
$$;

revoke execute on function public._bank_verified(uuid) from public, anon, authenticated;
revoke execute on function public._bank_last4(uuid) from public, anon, authenticated;
revoke execute on function public.submit_kyc(jsonb) from public, anon;
grant execute on function public.submit_kyc(jsonb) to authenticated;
revoke execute on function public.submit_bank_details(jsonb) from public, anon;
grant execute on function public.submit_bank_details(jsonb) to authenticated;
revoke execute on function public.admin_decide_bank(uuid, boolean, text) from public, anon;
grant execute on function public.admin_decide_bank(uuid, boolean, text) to authenticated;
revoke execute on function public.admin_set_kyc_paths(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_kyc_paths(uuid, jsonb) to authenticated;
revoke execute on function public.my_portal() from public, anon;
grant execute on function public.my_portal() to authenticated;
revoke execute on function public.my_payslips() from public, anon;
grant execute on function public.my_payslips() to authenticated;
revoke execute on function public.my_exit() from public, anon;
grant execute on function public.my_exit() to authenticated;
