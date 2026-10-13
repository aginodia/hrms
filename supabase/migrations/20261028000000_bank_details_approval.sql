-- =====================================================================
-- Altius HRMS — bank details: proof document and a separate approval
--
--  * KYC asks for a bank proof (cancelled cheque / passbook / statement)
--    in the Bank details section (kyc_submissions.bank_doc_path).
--  * Bank details are approved on their own, in Access Control → Bank
--    details, not with the rest of the KYC. Every submission is a row in
--    bank_requests: from the KYC form (source 'kyc') or a later change
--    from My KYC (source 'change'), always with the proof document.
--    Approving copies account, IFSC and proof into kyc_submissions;
--    "Send back" asks the employee to fix and submit again.
--  * Bank changes no longer go through "Request a change".
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.kyc_submissions add column if not exists bank_doc_path text;
alter table public.kyc_submissions add column if not exists bank_verified_at timestamptz;

create table if not exists public.bank_requests (
  id              uuid primary key default gen_random_uuid(),
  employee_id     uuid not null references public.profiles (id) on delete cascade,
  account_number  text not null,
  ifsc            text not null,
  doc_path        text,                       -- required for new submissions; empty only for records from before
  previous        jsonb,                      -- {account_number, ifsc} verified when asked, null the first time
  source          text not null default 'change' check (source in ('kyc', 'change')),
  note            text,
  status          text not null default 'pending' check (status in ('pending', 'approved', 'sent_back', 'withdrawn')),
  admin_note      text,
  created_at      timestamptz not null default now(),
  decided_by      uuid references public.profiles (id) on delete set null,
  decided_at      timestamptz
);
create index if not exists bank_requests_emp_idx on public.bank_requests (employee_id, created_at desc);
create unique index if not exists bank_requests_one_pending on public.bank_requests (employee_id) where status = 'pending';

alter table public.bank_requests enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_requests' and policyname = 'bank_requests_select_admin') then
    create policy bank_requests_select_admin on public.bank_requests for select to authenticated using (public.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'bank_requests' and policyname = 'bank_requests_select_own') then
    create policy bank_requests_select_own on public.bank_requests for select to authenticated using (employee_id = auth.uid());
  end if;
end $$;

-- Existing KYCs: verified KYC → bank verified; KYC waiting → bank waiting (no proof yet)
insert into public.bank_requests (employee_id, account_number, ifsc, source, status, created_at, decided_at)
select k.employee_id, k.bank_account_number, k.bank_ifsc, 'kyc',
       case when p.kyc_status = 'approved' then 'approved' else 'pending' end, coalesce(k.submitted_at, now()),
       case when p.kyc_status = 'approved' then now() end
  from public.kyc_submissions k join public.profiles p on p.id = k.employee_id
 where p.kyc_status in ('approved', 'submitted') and coalesce(k.bank_account_number, '') <> ''
   and not exists (select 1 from public.bank_requests b where b.employee_id = k.employee_id);
update public.kyc_submissions k set bank_verified_at = now()
 where bank_verified_at is null and exists (select 1 from public.bank_requests b where b.employee_id = k.employee_id and b.status = 'approved');

create or replace function public._bank_verified(p_user uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.bank_requests where employee_id = p_user and status = 'approved'); $$;

-- Bank proof uploads are allowed for active employees even after KYC is submitted
alter policy kyc_files_insert_own on storage.objects with check (
  bucket_id = 'kyc-documents' and (storage.foldername(name))[1] = auth.uid()::text
  and (public.can_edit_kyc() or (name like auth.uid()::text || '/bank-%' and public.my_status() = 'active')));

-- ---------------------------------------------------------------------
-- KYC: bank proof required; bank details go to the bank approval queue
-- ---------------------------------------------------------------------
create or replace function public.submit_kyc(p jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_prefix text := auth.uid()::text || '/';
  v_key    text;
  v_dob    date;
  v_ok     boolean := public._bank_verified(auth.uid());
  v_acc    text := trim(p ->> 'bank_account_number');
  v_ifsc   text := upper(trim(p ->> 'bank_ifsc'));
  v_doc    text := nullif(trim(p ->> 'bank_doc_path'), '');
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
                               'graduation_path', 'payslip_path', 'leave_letter_path', 'bank_doc_path'] loop
    if nullif(p ->> v_key, '') is not null and left(p ->> v_key, length(v_prefix)) <> v_prefix then
      raise exception 'Invalid document path for %', v_key;
    end if;
  end loop;

  -- Verified bank details stay as they are (they change from My KYC → Bank details)
  if not v_ok then
    if coalesce(v_acc, '') = '' or coalesce(v_ifsc, '') = '' then raise exception 'Missing required field: bank details'; end if;
    if v_doc is null then raise exception 'Upload a bank proof (cancelled cheque, passbook or statement)'; end if;
    if v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Invalid IFSC code'; end if;
    if v_acc !~ '^[0-9]{9,18}$' then raise exception 'Invalid bank account number'; end if;
  end if;

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
    coalesce(v_acc, ''), coalesce(v_ifsc, ''), v_doc,
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
    bank_account_number    = case when v_ok then k.bank_account_number else excluded.bank_account_number end,
    bank_ifsc              = case when v_ok then k.bank_ifsc else excluded.bank_ifsc end,
    bank_doc_path          = case when v_ok then k.bank_doc_path else excluded.bank_doc_path end,
    emergency_name         = excluded.emergency_name,
    emergency_relationship = excluded.emergency_relationship,
    emergency_phone        = excluded.emergency_phone,
    submitted_at           = excluded.submitted_at;

  -- Bank details wait for their own approval (an older waiting one is replaced)
  if not v_ok and not exists (select 1 from public.bank_requests where employee_id = v_uid and status = 'pending'
                                 and account_number = v_acc and ifsc = v_ifsc and doc_path is not distinct from v_doc) then
    update public.bank_requests set status = 'withdrawn', decided_at = now() where employee_id = v_uid and status = 'pending';
    insert into public.bank_requests (employee_id, account_number, ifsc, doc_path, source)
    values (v_uid, v_acc, v_ifsc, v_doc, 'kyc');
  end if;

  update public.profiles
     set kyc_status = 'submitted', kyc_submitted_at = now(), kyc_remarks = null, date_of_birth = v_dob,
         status = case when status = 'kyc_pending' then 'active' else status end
   where id = v_uid;
end;
$$;

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
                               'leave_letter_path', 'bank_doc_path'] loop
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
-- Employee: submit / change bank details (always with a proof)
-- ---------------------------------------------------------------------
create or replace function public.submit_bank_details(p jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_acc  text := regexp_replace(coalesce(p ->> 'account_number', ''), '\s', '', 'g');
  v_ifsc text := upper(trim(coalesce(p ->> 'ifsc', '')));
  v_doc  text := nullif(trim(p ->> 'doc_path'), '');
  k      public.kyc_submissions;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and status = 'active') then raise exception 'Only active employees can do this'; end if;
  select * into k from public.kyc_submissions where employee_id = v_uid;
  if k.employee_id is null then raise exception 'Submit your KYC first — bank details are part of it'; end if;
  if public.can_edit_kyc() then raise exception 'Your KYC is open — put the bank details in the KYC form'; end if;
  if exists (select 1 from public.bank_requests where employee_id = v_uid and status = 'pending') then
    raise exception 'Your bank details are already waiting for approval';
  end if;
  if v_acc !~ '^[0-9]{9,18}$' then raise exception 'Invalid bank account number'; end if;
  if v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Invalid IFSC code'; end if;
  if v_doc is null then raise exception 'Upload a bank proof (cancelled cheque, passbook or statement)'; end if;
  if left(v_doc, length(v_uid::text) + 1) <> v_uid::text || '/' then raise exception 'Invalid document path'; end if;
  insert into public.bank_requests (employee_id, account_number, ifsc, doc_path, previous, source, note)
  values (v_uid, v_acc, v_ifsc, v_doc,
          case when public._bank_verified(v_uid) then jsonb_build_object('account_number', k.bank_account_number, 'ifsc', k.bank_ifsc) end,
          'change', nullif(trim(p ->> 'note'), ''))
  returning id into v_id;
  perform public._fin_log('emd', v_uid, current_date, 'Bank details submitted for approval', null, jsonb_build_object('request_id', v_id));
  return v_id;
end;
$$;

create or replace function public.withdraw_bank_request(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.bank_requests set status = 'withdrawn', decided_at = now()
   where id = p_id and employee_id = auth.uid() and status = 'pending' and source = 'change';
  if not found then raise exception 'This request is no longer waiting'; end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Admin: approve or send back bank details
-- ---------------------------------------------------------------------
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
  if p_approve then
    update public.kyc_submissions
       set bank_account_number = r.account_number, bank_ifsc = r.ifsc,
           bank_doc_path = coalesce(r.doc_path, bank_doc_path), bank_verified_at = now(), updated_at = now()
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

-- Bank changes now go through submit_bank_details (with a proof)
create or replace function public._change_fields()
returns text[] language sql immutable as $$
  select array['full_name', 'phone', 'date_of_birth', 'emergency_name', 'emergency_relationship', 'emergency_phone'];
$$;

-- Moving KYC files to Drive also moves the bank proof
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
  end if;
end;
$$;

-- Employee portal: + bank proof and bank submissions
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


revoke execute on function public._bank_verified(uuid) from public, anon, authenticated;
revoke execute on function public.submit_kyc(jsonb) from public, anon;
grant execute on function public.submit_kyc(jsonb) to authenticated;
revoke execute on function public.save_kyc_draft(jsonb) from public, anon;
grant execute on function public.save_kyc_draft(jsonb) to authenticated;
revoke execute on function public.submit_bank_details(jsonb) from public, anon;
grant execute on function public.submit_bank_details(jsonb) to authenticated;
revoke execute on function public.withdraw_bank_request(uuid) from public, anon;
grant execute on function public.withdraw_bank_request(uuid) to authenticated;
revoke execute on function public.admin_decide_bank(uuid, boolean, text) from public, anon;
grant execute on function public.admin_decide_bank(uuid, boolean, text) to authenticated;
revoke execute on function public.admin_set_kyc_paths(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_kyc_paths(uuid, jsonb) to authenticated;
revoke execute on function public.my_portal() from public, anon;
grant execute on function public.my_portal() to authenticated;
