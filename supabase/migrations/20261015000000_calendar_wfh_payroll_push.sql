-- =====================================================================
-- Altius HRMS — holiday & time-relaxation calendar, WFH, salary sheet
-- push with day-wise queries
--
--  * calendar_days: holidays (Mon–Sat holidays are paid full days) and
--    time-relaxation days (a shorter full day, e.g. 5h on Diwali). One entry
--    per date; the financial year runs 1 April – 31 March. Everyone signed in
--    can read the calendar; only admins change it.
--  * wfh_days: work-from-home dates added by the employee. A WFH day that the
--    attendance sheet shows as leave (no punches) is paid as a full day.
--    Admins can reject or add WFH at any time.
--  * payroll_runs.pushed_at / last_pushed_at, payroll_results.days:
--    "Save & push" publishes each employee's final day-wise sheet. It can't
--    be edited by the employee. The portal shows only pushed months.
--  * payroll_queries: for 12 hours after the first push an employee can ask
--    to change a Leave or Half day on a specific date. Admins answer at any
--    time and are never time-limited.
-- Re-runnable. Nothing is removed.
-- =====================================================================

-- Push state on the payroll month and each employee's published day-wise sheet
alter table public.payroll_runs
  add column if not exists pushed_at      timestamptz,
  add column if not exists pushed_by      uuid references public.profiles (id) on delete set null,
  add column if not exists last_pushed_at timestamptz;
alter table public.payroll_results add column if not exists days jsonb;

-- ---------------------------------------------------------------------
-- Holiday & time-relaxation calendar
-- ---------------------------------------------------------------------
create table if not exists public.calendar_days (
  id            uuid primary key default gen_random_uuid(),
  day           date not null,
  kind          text not null check (kind in ('holiday', 'relaxation')),
  description   text not null,
  full_minutes  integer check (full_minutes between 1 and 1440),
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  removed_at    timestamptz,
  removed_by    uuid references public.profiles (id) on delete set null,
  constraint calendar_days_minutes check ((kind = 'relaxation') = (full_minutes is not null))
);
create unique index if not exists calendar_days_day_uq on public.calendar_days (day) where removed_at is null;

alter table public.calendar_days enable row level security;
drop policy if exists calendar_days_select on public.calendar_days;
create policy calendar_days_select on public.calendar_days for select to authenticated
  using (removed_at is null or public.is_admin());
grant select on public.calendar_days to authenticated;

create or replace function public.admin_add_calendar_day(p_kind text, p_day date, p_description text, p_minutes integer default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_other text;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_kind not in ('holiday', 'relaxation') then raise exception 'Unknown calendar type'; end if;
  if p_day is null then raise exception 'Pick a date'; end if;
  if nullif(trim(p_description), '') is null then raise exception 'Add a description'; end if;
  if p_kind = 'relaxation' and (p_minutes is null or p_minutes < 1 or p_minutes > 1440) then
    raise exception 'Enter the full-day time for the relaxation (hours and minutes)';
  end if;
  select case kind when 'holiday' then 'a holiday' else 'a time relaxation' end || ' (' || description || ')' into v_other
    from public.calendar_days where day = p_day and removed_at is null;
  if v_other is not null then raise exception '% already has %', to_char(p_day, 'DD-MM-YYYY'), v_other; end if;
  insert into public.calendar_days (day, kind, description, full_minutes, created_by)
  values (p_day, p_kind, trim(p_description), case when p_kind = 'relaxation' then p_minutes end, auth.uid())
  returning id into v_id;
  perform public._fin_log('payroll', null, p_day,
    case p_kind when 'holiday' then 'Holiday added: ' else 'Time relaxation added: ' end || trim(p_description) || ' (' || to_char(p_day, 'DD-MM-YYYY') || ')', null,
    jsonb_build_object('kind', p_kind, 'day', p_day, 'full_minutes', p_minutes));
  return v_id;
end;
$$;

create or replace function public.admin_remove_calendar_day(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare c public.calendar_days;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.calendar_days set removed_at = now(), removed_by = auth.uid()
   where id = p_id and removed_at is null returning * into c;
  if c.id is null then raise exception 'This date is not in the calendar any more'; end if;
  perform public._fin_log('payroll', null, c.day,
    case c.kind when 'holiday' then 'Holiday removed: ' else 'Time relaxation removed: ' end || c.description || ' (' || to_char(c.day, 'DD-MM-YYYY') || ')', null, null);
end;
$$;

-- ---------------------------------------------------------------------
-- Work from home
-- ---------------------------------------------------------------------
create table if not exists public.wfh_days (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  work_date    date not null,
  note         text,
  status       text not null default 'recorded' check (status in ('recorded', 'rejected', 'withdrawn')),
  added_by     uuid references public.profiles (id) on delete set null,
  admin_note   text,
  created_at   timestamptz not null default now(),
  decided_by   uuid references public.profiles (id) on delete set null,
  decided_at   timestamptz
);
create unique index if not exists wfh_days_uq on public.wfh_days (employee_id, work_date) where status = 'recorded';
create index if not exists wfh_days_date_idx on public.wfh_days (work_date);

alter table public.wfh_days enable row level security;
drop policy if exists wfh_days_select on public.wfh_days;
create policy wfh_days_select on public.wfh_days for select to authenticated
  using (employee_id = auth.uid() or public.is_admin());
grant select on public.wfh_days to authenticated;

-- Has the salary for this date's month already been published?
create or replace function public._month_pushed(p_day date)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.payroll_runs r
                  where r.month = date_trunc('month', p_day)::date and r.superseded_at is null and r.pushed_at is not null);
$$;

create or replace function public.my_add_wfh(p_dates date[], p_note text default null)
returns integer language plpgsql security definer set search_path = public
as $$
declare d date; n integer := 0;
begin
  if public.my_status() <> 'active' then raise exception 'Your account is not active'; end if;
  if p_dates is null or cardinality(p_dates) = 0 then raise exception 'Pick at least one date'; end if;
  foreach d in array p_dates loop
    if extract(isodow from d) = 7 then raise exception '% is a Sunday', to_char(d, 'DD-MM-YYYY'); end if;
    if exists (select 1 from public.calendar_days c where c.day = d and c.kind = 'holiday' and c.removed_at is null) then
      raise exception '% is a holiday', to_char(d, 'DD-MM-YYYY');
    end if;
    if public._month_pushed(d) then
      raise exception 'The salary for % is already published — ask about % in My Pay instead', to_char(d, 'Mon YYYY'), to_char(d, 'DD-MM-YYYY');
    end if;
    if not exists (select 1 from public.wfh_days w where w.employee_id = auth.uid() and w.work_date = d and w.status = 'recorded') then
      insert into public.wfh_days (employee_id, work_date, note, added_by) values (auth.uid(), d, nullif(trim(p_note), ''), auth.uid());
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

create or replace function public.my_withdraw_wfh(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare w public.wfh_days;
begin
  select * into w from public.wfh_days where id = p_id and employee_id = auth.uid() and status = 'recorded';
  if w.id is null then raise exception 'This WFH day can''t be withdrawn'; end if;
  if public._month_pushed(w.work_date) then raise exception 'The salary for this month is already published — it can''t be changed now'; end if;
  update public.wfh_days set status = 'withdrawn', decided_at = now(), decided_by = auth.uid() where id = p_id;
end;
$$;

-- Admins: add a WFH day for someone, or reject / restore one — no time limit
create or replace function public.admin_add_wfh(p_employee uuid, p_date date, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if exists (select 1 from public.wfh_days where employee_id = p_employee and work_date = p_date and status = 'recorded') then
    raise exception 'WFH is already recorded for this date';
  end if;
  insert into public.wfh_days (employee_id, work_date, note, added_by) values (p_employee, p_date, nullif(trim(p_note), ''), auth.uid());
  perform public._fin_log('payroll', p_employee, p_date, 'WFH added by admin: ' || to_char(p_date, 'DD-MM-YYYY'), null, null);
end;
$$;

create or replace function public.admin_set_wfh(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare w public.wfh_days;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_status not in ('recorded', 'rejected') then raise exception 'Unknown WFH status'; end if;
  select * into w from public.wfh_days where id = p_id;
  if w.id is null then raise exception 'WFH entry not found'; end if;
  if p_status = 'recorded' and exists (select 1 from public.wfh_days where employee_id = w.employee_id and work_date = w.work_date and status = 'recorded' and id <> p_id) then
    raise exception 'WFH is already recorded for this date';
  end if;
  update public.wfh_days set status = p_status, admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now() where id = p_id;
  perform public._fin_log('payroll', w.employee_id, w.work_date,
    case p_status when 'rejected' then 'WFH rejected: ' else 'WFH restored: ' end || to_char(w.work_date, 'DD-MM-YYYY'), null,
    case when nullif(trim(p_note), '') is null then null else jsonb_build_object('note', trim(p_note)) end);
end;
$$;

-- ---------------------------------------------------------------------
-- Save & push: the final day-wise sheet goes to each employee
-- ---------------------------------------------------------------------

-- p_days: [{"employee_id": uuid, "days": [{"date", "day", "in", "out", "mins", "need", "status", "label"}]}]
create or replace function public.admin_push_payroll(p_run uuid, p_days jsonb)
returns integer language plpgsql security definer set search_path = public
as $$
declare r public.payroll_runs; n integer;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into r from public.payroll_runs where id = p_run;
  if r.id is null or r.superseded_at is not null then raise exception 'This payroll month was replaced by a newer upload'; end if;
  if r.processed_at is null then raise exception 'Save the payroll before pushing it'; end if;
  update public.payroll_results x set days = d.days
    from jsonb_to_recordset(p_days) as d(employee_id uuid, days jsonb)
   where x.run_id = p_run and x.employee_id = d.employee_id and x.included;
  get diagnostics n = row_count;
  update public.payroll_runs set pushed_at = coalesce(pushed_at, now()), pushed_by = coalesce(pushed_by, auth.uid()), last_pushed_at = now()
   where id = p_run;
  perform public._fin_log('payroll', null, r.month,
    case when r.pushed_at is null then 'Salary sheet pushed to employees' else 'Salary sheet pushed again' end, null, jsonb_build_object('employees', n));
  return n;
end;
$$;

-- ---------------------------------------------------------------------
-- Day-wise queries from employees (12 hours from the first push)
-- ---------------------------------------------------------------------
create table if not exists public.payroll_queries (
  id                uuid primary key default gen_random_uuid(),
  run_id            uuid not null references public.payroll_runs (id) on delete cascade,
  employee_id       uuid not null references public.profiles (id) on delete cascade,
  work_date         date not null,
  current_status    text not null,
  requested_status  text not null check (requested_status in ('F', 'HD')),
  note              text not null,
  status            text not null default 'open' check (status in ('open', 'resolved', 'rejected', 'withdrawn')),
  admin_note        text,
  created_at        timestamptz not null default now(),
  decided_by        uuid references public.profiles (id) on delete set null,
  decided_at        timestamptz
);
create unique index if not exists payroll_queries_open_uq on public.payroll_queries (run_id, employee_id, work_date) where status = 'open';
create index if not exists payroll_queries_run_idx on public.payroll_queries (run_id, status);

alter table public.payroll_queries enable row level security;
drop policy if exists payroll_queries_select on public.payroll_queries;
create policy payroll_queries_select on public.payroll_queries for select to authenticated
  using (employee_id = auth.uid() or public.is_admin());
grant select on public.payroll_queries to authenticated;

create or replace function public.my_raise_query(p_run uuid, p_date date, p_requested text, p_note text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare r public.payroll_runs; x public.payroll_results; v_status text; v_id uuid;
begin
  if not coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true) then
    raise exception 'Pay details are switched off';
  end if;
  select * into r from public.payroll_runs where id = p_run and superseded_at is null;
  if r.id is null or r.pushed_at is null then raise exception 'This salary sheet is not published'; end if;
  if now() > r.pushed_at + interval '12 hours' then
    raise exception 'Queries for % closed at % — contact HR', to_char(r.month, 'Mon YYYY'),
      to_char((r.pushed_at + interval '12 hours') at time zone 'Asia/Kolkata', 'DD-MM-YYYY HH24:MI');
  end if;
  select * into x from public.payroll_results where run_id = p_run and employee_id = auth.uid() and included;
  if x.employee_id is null or x.days is null then raise exception 'You have no salary sheet for this month'; end if;
  select d ->> 'status' into v_status from jsonb_array_elements(x.days) d where d ->> 'date' = p_date::text;
  if v_status is null then raise exception 'That date is not in this salary sheet'; end if;
  if v_status not in ('L', 'HD') then raise exception 'Only a Leave or Half day can be questioned'; end if;
  if p_requested not in ('F', 'HD') or p_requested = v_status then raise exception 'Pick what the day should be'; end if;
  if nullif(trim(p_note), '') is null then raise exception 'Add a short reason'; end if;
  if exists (select 1 from public.payroll_queries where run_id = p_run and employee_id = auth.uid() and work_date = p_date and status = 'open') then
    raise exception 'You already asked about this date';
  end if;
  insert into public.payroll_queries (run_id, employee_id, work_date, current_status, requested_status, note)
  values (p_run, auth.uid(), p_date, v_status, p_requested, trim(p_note)) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.my_withdraw_query(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.payroll_queries set status = 'withdrawn', decided_at = now(), decided_by = auth.uid()
   where id = p_id and employee_id = auth.uid() and status = 'open';
  if not found then raise exception 'This query is already answered'; end if;
end;
$$;

create or replace function public.admin_decide_query(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare q public.payroll_queries;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_status not in ('resolved', 'rejected', 'open') then raise exception 'Unknown status'; end if;
  if p_status = 'rejected' and nullif(trim(p_note), '') is null then raise exception 'Add a note for the employee'; end if;
  update public.payroll_queries set status = p_status, admin_note = nullif(trim(p_note), ''),
         decided_by = case when p_status = 'open' then null else auth.uid() end,
         decided_at = case when p_status = 'open' then null else now() end
   where id = p_id returning * into q;
  if q.id is null then raise exception 'Query not found'; end if;
  perform public._fin_log('payroll', q.employee_id, q.work_date,
    'Salary query ' || case p_status when 'resolved' then 'resolved' when 'rejected' then 'rejected' else 'reopened' end || ': ' || to_char(q.work_date, 'DD-MM-YYYY'), null,
    case when nullif(trim(p_note), '') is null then null else jsonb_build_object('note', trim(p_note)) end);
end;
$$;

-- The employee's published salary sheets with the day-wise lines and their queries
create or replace function public.my_payslips()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see_pay boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true);
begin
  if not see_pay then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'run_id', r.id, 'month', r.month, 'pushed_at', r.pushed_at, 'last_pushed_at', r.last_pushed_at,
      'query_until', r.pushed_at + interval '12 hours',
      'monthly_salary', x.monthly_salary, 'daily_salary', x.daily_salary,
      'full', x.post_full, 'half', x.post_half, 'leave', x.post_leave, 'weekly_off', x.post_weekly_off,
      'earned', x.payable, 'pt', x.pt, 'net', x.net_payable, 'days', x.days,
      'queries', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'date', q.work_date, 'current', q.current_status,
                  'requested', q.requested_status, 'note', q.note, 'status', q.status, 'admin_note', q.admin_note,
                  'created_at', q.created_at, 'decided_at', q.decided_at) order by q.work_date, q.created_at)
                from public.payroll_queries q where q.run_id = r.id and q.employee_id = auth.uid()), '[]'::jsonb)
    ) order by r.month desc)
    from public.payroll_results x join public.payroll_runs r on r.id = x.run_id
   where x.employee_id = auth.uid() and x.included and r.superseded_at is null and r.pushed_at is not null), '[]'::jsonb);
end;
$$;

-- The portal's monthly pay list now shows only published (pushed) months
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

revoke execute on function public.admin_add_calendar_day(text, date, text, integer) from public, anon;
revoke execute on function public.admin_remove_calendar_day(uuid) from public, anon;
revoke execute on function public._month_pushed(date) from public, anon, authenticated;
revoke execute on function public.my_add_wfh(date[], text) from public, anon;
revoke execute on function public.my_withdraw_wfh(uuid) from public, anon;
revoke execute on function public.admin_add_wfh(uuid, date, text) from public, anon;
revoke execute on function public.admin_set_wfh(uuid, text, text) from public, anon;
revoke execute on function public.admin_push_payroll(uuid, jsonb) from public, anon;
revoke execute on function public.my_raise_query(uuid, date, text, text) from public, anon;
revoke execute on function public.my_withdraw_query(uuid) from public, anon;
revoke execute on function public.admin_decide_query(uuid, text, text) from public, anon;
revoke execute on function public.my_payslips() from public, anon;
grant execute on function public.admin_add_calendar_day(text, date, text, integer) to authenticated;
grant execute on function public.admin_remove_calendar_day(uuid) to authenticated;
grant execute on function public.my_add_wfh(date[], text) to authenticated;
grant execute on function public.my_withdraw_wfh(uuid) to authenticated;
grant execute on function public.admin_add_wfh(uuid, date, text) to authenticated;
grant execute on function public.admin_set_wfh(uuid, text, text) to authenticated;
grant execute on function public.admin_push_payroll(uuid, jsonb) to authenticated;
grant execute on function public.my_raise_query(uuid, date, text, text) to authenticated;
grant execute on function public.my_withdraw_query(uuid) to authenticated;
grant execute on function public.admin_decide_query(uuid, text, text) to authenticated;
grant execute on function public.my_payslips() to authenticated;
