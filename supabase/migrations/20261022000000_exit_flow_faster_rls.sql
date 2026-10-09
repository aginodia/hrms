-- =====================================================================
-- Altius HRMS — exit flow, and faster access checks
--
-- Exit
--  * Once an employee is Resigned / Terminated their portal access is
--    revoked: their own data is no longer readable (RLS) and the portal
--    calls return nothing — only my_exit() answers: relieving letter,
--    experience letter, the last 6 salary slips, and the F&F (due 60 days
--    after the last working day; the statement once it is done).
--  * After F&F the person can still sign in for 3 days to download it,
--    then access ends ("No access found"). Nothing is deleted.
--  * exit_documents: relieving / experience letters and the F&F statement
--    saved to Google Drive (only the Drive file id is stored).
--  * fnf_settlements: the F&F statement (earnings / deductions, net).
--  * admin_complete_fnf(p_user, p_settled_on, p_items, p_note).
-- Speed
--  * Access checks in the row-level policies run once per query instead
--    of once per row ((select ...) wrappers).
-- Re-runnable. Nothing is removed.
-- =====================================================================

create or replace function public._access_ended()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles
                  where id = auth.uid() and fnf_completed_at is not null and now() > fnf_completed_at + interval '3 days');
$$;

create table if not exists public.exit_documents (
  id             uuid primary key default gen_random_uuid(),
  employee_id    uuid not null references public.profiles (id) on delete cascade,
  kind           text not null check (kind in ('relieving', 'experience', 'fnf')),
  drive_file_id  text not null,
  file_name      text,
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  removed_at     timestamptz
);
create unique index if not exists exit_documents_uq on public.exit_documents (employee_id, kind) where removed_at is null;
alter table public.exit_documents enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'exit_documents' and policyname = 'exit_documents_admin_select') then
    create policy exit_documents_admin_select on public.exit_documents for select to authenticated using ((select public.is_admin()));
  end if;
end $$;
grant select on public.exit_documents to authenticated;

create table if not exists public.fnf_settlements (
  employee_id  uuid primary key references public.profiles (id) on delete cascade,
  settled_on   date not null,
  items        jsonb not null default '[]'::jsonb,
  net          numeric(14, 2) not null default 0,
  note         text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
alter table public.fnf_settlements enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fnf_settlements' and policyname = 'fnf_settlements_admin_select') then
    create policy fnf_settlements_admin_select on public.fnf_settlements for select to authenticated using ((select public.is_admin()));
  end if;
end $$;
grant select on public.fnf_settlements to authenticated;

create or replace function public.admin_record_exit_doc(p_employee uuid, p_kind text, p_file_id text, p_file_name text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_kind not in ('relieving', 'experience', 'fnf') then raise exception 'Unknown document'; end if;
  if coalesce(trim(p_file_id), '') = '' then raise exception 'The Drive file is missing'; end if;
  update public.exit_documents set removed_at = now() where employee_id = p_employee and kind = p_kind and removed_at is null;
  insert into public.exit_documents (employee_id, kind, drive_file_id, file_name, created_by)
  values (p_employee, p_kind, trim(p_file_id), nullif(trim(p_file_name), ''), auth.uid());
  perform public._fin_log('emd', p_employee, current_date,
    case p_kind when 'relieving' then 'Relieving letter issued' when 'experience' then 'Experience letter issued' else 'F&F statement saved' end, null, null);
end;
$$;

-- F&F with its statement. p_items: [{"label": "...", "type": "earning"|"deduction", "amount": 123.45}]
create or replace function public.admin_complete_fnf(p_user uuid, p_settled_on date, p_items jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare v_net numeric := 0; it jsonb;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot complete your own F&F'; end if;
  if p_settled_on is null then raise exception 'Pick the settlement date'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then raise exception 'Invalid F&F lines'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if coalesce(trim(it ->> 'label'), '') = '' then raise exception 'Every F&F line needs a description'; end if;
    if (it ->> 'type') not in ('earning', 'deduction') then raise exception 'Each line is an earning or a deduction'; end if;
    if (it ->> 'amount')::numeric < 0 then raise exception 'Amounts cannot be negative'; end if;
    v_net := v_net + case when it ->> 'type' = 'earning' then (it ->> 'amount')::numeric else -(it ->> 'amount')::numeric end;
  end loop;
  update public.profiles
     set fnf_completed_at = now(), fnf_by = auth.uid(), status = 'inactive'
   where id = p_user and status = 'active' and employment_status in ('resigned', 'terminated') and fnf_completed_at is null;
  if not found then raise exception 'F&F can only be completed for a resigned or terminated employee'; end if;
  insert into public.fnf_settlements (employee_id, settled_on, items, net, note, created_by)
  values (p_user, p_settled_on, coalesce(p_items, '[]'::jsonb), round(v_net, 2), nullif(trim(p_note), ''), auth.uid())
  on conflict (employee_id) do update set settled_on = excluded.settled_on, items = excluded.items, net = excluded.net,
    note = excluded.note, created_by = excluded.created_by, created_at = now();
  perform public._fin_log('emd', p_user, current_date, 'F&F completed — journey ended', round(v_net, 2), jsonb_build_object('settled_on', p_settled_on));
end;
$$;

-- Everything a person who has left can see
create or replace function public.my_exit()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare p public.profiles; v_acct text;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then return null; end if;
  if not (p.employment_status in ('resigned', 'terminated') or p.fnf_completed_at is not null) then return jsonb_build_object('left', false); end if;
  if p.fnf_completed_at is not null and now() > p.fnf_completed_at + interval '3 days' then return jsonb_build_object('left', true, 'ended', true); end if;
  select right(bank_account_number, 4) into v_acct from public.kyc_submissions where employee_id = p.id;
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

-- Drive passes: also during the 3 days after F&F (to download the exit documents)
create or replace function public.drive_ticket()
returns text language plpgsql stable security definer set search_path = public, extensions
as $$
declare p public.profiles; v_secret text; v_payload text; v_b64 text;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or not (p.status in ('kyc_pending', 'kyc_submitted', 'active')
                          or (p.fnf_completed_at is not null and now() <= p.fnf_completed_at + interval '3 days')) then
    raise exception 'Your account cannot use file storage';
  end if;
  select value into v_secret from public.app_secrets where key = 'drive_bridge';
  v_payload := jsonb_build_object('uid', p.id, 'admin', p.role = 'admin' and p.status = 'active',
    'name', p.full_name, 'eid', p.employee_code, 'exp', floor(extract(epoch from now())) + 300)::text;
  v_b64 := translate(encode(convert_to(v_payload, 'utf8'), 'base64'), E'+/=\n', '-_');
  return v_b64 || '.' || encode(extensions.hmac(v_b64, v_secret, 'sha256'), 'hex');
end;
$$;

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
        'payslip_path', k.payslip_path, 'leave_letter_path', k.leave_letter_path) end) end,
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

create or replace function public.my_payslips()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see_pay boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true);
        p public.profiles;
        v_acct text;
begin
  if not see_pay or public._i_have_left() then return '[]'::jsonb; end if;
  select * into p from public.profiles where id = auth.uid();
  select right(bank_account_number, 4) into v_acct from public.kyc_submissions where employee_id = auth.uid();
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

create or replace function public.my_esops()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'esop')::boolean, true);
        p public.profiles;
begin
  if not see or public._i_have_left() then return jsonb_build_object('hidden', true); end if;
  select * into p from public.profiles where id = auth.uid();
  return jsonb_build_object(
    'pool', coalesce(((select value from public.app_settings where key = 'esop') ->> 'pool')::int, 2000),
    'profile', jsonb_build_object('employment_status', p.employment_status, 'resignation_date', p.resignation_date,
                                  'exit_date', p.exit_date, 'fnf_completed_at', p.fnf_completed_at),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'allocation_date', a.allocation_date, 'title', a.title,
                     'exercise_years', a.exercise_years, 'exercise_price', a.exercise_price,
                     'letter_file', (select d.drive_file_id from public.hr_documents d where d.employee_id = auth.uid() and d.kind = 'grant_letter'
                                      and d.ref = a.id::text and d.removed_at is null)) order by a.allocation_date)
                   from public.esop_allocations a where a.removed_at is null
                    and exists (select 1 from public.esop_grants g where g.allocation_id = a.id and g.employee_id = auth.uid())), '[]'::jsonb),
    'grants', coalesce((select jsonb_agg(jsonb_build_object('allocation_id', g.allocation_id, 'type', g.grant_type, 'options', g.options, 'note', g.vesting_note))
               from public.esop_grants g join public.esop_allocations a on a.id = g.allocation_id and a.removed_at is null
              where g.employee_id = auth.uid()), '[]'::jsonb),
    'vesting', coalesce((select jsonb_agg(jsonb_build_object('allocation_id', v.allocation_id, 'date', v.vest_date, 'label', v.label, 'options', v.options) order by v.vest_date)
               from public.esop_vesting v join public.esop_allocations a on a.id = v.allocation_id and a.removed_at is null
              where v.employee_id = auth.uid()), '[]'::jsonb),
    'exercises', coalesce((select jsonb_agg(jsonb_build_object('date', e.exercise_date, 'options', e.options, 'price', e.price, 'note', e.note) order by e.exercise_date)
               from public.esop_exercises e where e.employee_id = auth.uid() and e.removed_at is null), '[]'::jsonb));
end;
$$;

-- Row-level policies: checks evaluated once per query; own rows hidden after leaving
alter policy change_requests_select on public.change_requests using ((employee_id = (select auth.uid()) and not (select public._i_have_left())) or (select public.is_admin()));
alter policy esop_allocations_select on public.esop_allocations using ((select public.is_admin()) or ((removed_at is null) and not (select public._i_have_left()) and exists (select 1 from public.esop_grants g where g.allocation_id = esop_allocations.id and g.employee_id = (select auth.uid()))));
alter policy esop_exercises_select on public.esop_exercises using ((select public.is_admin()) or (employee_id = (select auth.uid()) and not (select public._i_have_left())));
alter policy esop_grants_select on public.esop_grants using ((select public.is_admin()) or (employee_id = (select auth.uid()) and not (select public._i_have_left())));
alter policy esop_vesting_select on public.esop_vesting using ((select public.is_admin()) or (employee_id = (select auth.uid()) and not (select public._i_have_left())));
alter policy hr_documents_select on public.hr_documents using ((select public.is_admin()) or (employee_id = (select auth.uid()) and removed_at is null and not (select public._i_have_left())));
alter policy kyc_drafts_select on public.kyc_drafts using ((employee_id = (select auth.uid()) and not (select public._i_have_left())) or (select public.is_admin()));
alter policy kyc_select_own on public.kyc_submissions using (employee_id = (select auth.uid()) and not (select public._i_have_left()) and ((select public.can_edit_kyc()) or ((select public.my_status()) <> 'active') or (select public.team_can_see('kyc_documents'))));
alter policy leave_records_select on public.leave_records using ((employee_id = (select auth.uid()) and not (select public._i_have_left())) or (select public.is_admin()));
alter policy payroll_queries_select on public.payroll_queries using ((employee_id = (select auth.uid()) and not (select public._i_have_left())) or (select public.is_admin()));
alter policy profiles_select_own on public.profiles using (id = (select auth.uid()));
alter policy salary_select_own on public.salary_history using (employee_id = (select auth.uid()) and removed_at is null and not (select public._i_have_left()) and ((select public.my_status()) = 'active') and (select public.team_can_see('salary')));
alter policy wfh_days_select on public.wfh_days using ((employee_id = (select auth.uid()) and not (select public._i_have_left())) or (select public.is_admin()));
alter policy settings_admin_write on public.app_settings using ((select public.is_admin()));
alter policy attendance_adjustments_admin_select on public.attendance_adjustments using ((select public.is_admin()));
alter policy attendance_code_map_admin_select on public.attendance_code_map using ((select public.is_admin()));
alter policy attendance_punches_admin_select on public.attendance_punches using ((select public.is_admin()));
alter policy bonus_payments_admin_select on public.bonus_payments using ((select public.is_admin()));
alter policy calendar_days_select on public.calendar_days using ((removed_at is null) or (select public.is_admin()));
alter policy comp_eligibility_admin_select on public.comp_eligibility using ((select public.is_admin()));
alter policy doc_assets_admin_select on public.doc_assets using ((select public.is_admin()));
alter policy expense_claims_admin_select on public.expense_claims using ((select public.is_admin()));
alter policy finance_log_admin_select on public.finance_log using ((select public.is_admin()));
alter policy kyc_select_admin on public.kyc_submissions using ((select public.is_admin()));
alter policy loan_deductions_admin_select on public.loan_deductions using ((select public.is_admin()));
alter policy loan_repayments_admin_select on public.loan_repayments using ((select public.is_admin()));
alter policy loans_admin_select on public.loans using ((select public.is_admin()));
alter policy payroll_results_admin_select on public.payroll_results using ((select public.is_admin()));
alter policy payroll_runs_admin_select on public.payroll_runs using ((select public.is_admin()));
alter policy profiles_select_admin on public.profiles using ((select public.is_admin()));
alter policy salary_select_admin on public.salary_history using ((select public.is_admin()));
alter policy variable_entries_admin_select on public.variable_entries using ((select public.is_admin()));
alter policy variable_payouts_admin_select on public.variable_payouts using ((select public.is_admin()));
alter policy variable_uploads_admin_select on public.variable_uploads using ((select public.is_admin()));

revoke execute on function public._access_ended() from public, anon;
revoke execute on function public.admin_record_exit_doc(uuid, text, text, text) from public, anon;
revoke execute on function public.admin_complete_fnf(uuid, date, jsonb, text) from public, anon;
revoke execute on function public.my_exit() from public, anon;
grant execute on function public._access_ended() to authenticated;
grant execute on function public.admin_record_exit_doc(uuid, text, text, text) to authenticated;
grant execute on function public.admin_complete_fnf(uuid, date, jsonb, text) to authenticated;
grant execute on function public.my_exit() to authenticated;
