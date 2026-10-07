-- =====================================================================
--  Altius HRMS — employee exits (Resigned / Terminated / F&F),
--  Variable payouts from an uploaded sheet, Loans with deductions from
--  Variable and Bonus, and an activity log for the finance sections.
--
--  * profiles.employment_status  active | resigned | terminated
--    After F&F (fnf_completed_at) the profile becomes status 'inactive':
--    no sign-in, and it is left out of every sheet and list.
--  * variable_uploads / variable_payouts  calculated variable sheet, rows
--    matched to employees by Employee ID (norm_emp_code)
--  * loans / loan_deductions  loan remaining = amount − active deductions
--  * finance_log  who did what, per employee and month
--  Nothing is hard-deleted: removed rows get removed_at, replaced
--  deductions get voided_at.
-- =====================================================================

alter table public.profiles
  add column if not exists employment_status text not null default 'active'
    check (employment_status in ('active', 'resigned', 'terminated')),
  add column if not exists exit_date        date,
  add column if not exists exit_note        text,
  add column if not exists fnf_completed_at timestamptz,
  add column if not exists fnf_by           uuid references public.profiles (id) on delete set null;

-- ---------------------------------------------------------------------
-- Activity log
-- ---------------------------------------------------------------------
create table if not exists public.finance_log (
  id           bigint generated always as identity primary key,
  section      text not null check (section in ('emd', 'payroll', 'variable', 'bonus', 'loan')),
  employee_id  uuid references public.profiles (id) on delete set null,
  month        date,
  action       text not null,
  amount       numeric(14, 2),
  details      jsonb,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists finance_log_emp_idx on public.finance_log (employee_id, created_at desc);
create index if not exists finance_log_month_idx on public.finance_log (section, month);

create or replace function public._fin_log(p_section text, p_emp uuid, p_month date, p_action text, p_amount numeric, p_details jsonb)
returns void language sql security definer set search_path = public
as $$
  insert into public.finance_log (section, employee_id, month, action, amount, details, created_by)
  values (p_section, p_emp, date_trunc('month', p_month)::date, p_action, p_amount, p_details, auth.uid());
$$;

-- ---------------------------------------------------------------------
-- Exits
-- ---------------------------------------------------------------------
create or replace function public.admin_set_employment_status(p_user uuid, p_status text, p_exit_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own employment status'; end if;
  if p_status not in ('active', 'resigned', 'terminated') then raise exception 'Unknown status'; end if;
  update public.profiles
     set employment_status = p_status,
         exit_date = case when p_status = 'active' then null else coalesce(p_exit_date, current_date) end,
         exit_note = case when p_status = 'active' then null else nullif(trim(p_note), '') end
   where id = p_user and status = 'active' and fnf_completed_at is null;
  if not found then raise exception 'Employee not found, or F&F is already completed'; end if;
  perform public._fin_log('emd', p_user, coalesce(p_exit_date, current_date),
    case p_status when 'active' then 'Marked active again' when 'resigned' then 'Marked resigned' else 'Marked terminated' end,
    null, jsonb_build_object('exit_date', p_exit_date, 'note', nullif(trim(p_note), '')));
end;
$$;

create or replace function public.admin_complete_fnf(p_user uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot complete your own F&F'; end if;
  update public.profiles
     set fnf_completed_at = now(), fnf_by = auth.uid(), status = 'inactive'
   where id = p_user and status = 'active' and employment_status in ('resigned', 'terminated') and fnf_completed_at is null;
  if not found then raise exception 'F&F can only be completed for a resigned or terminated employee'; end if;
  perform public._fin_log('emd', p_user, current_date, 'F&F completed — journey ended', null, null);
end;
$$;

-- ---------------------------------------------------------------------
-- Loans
-- ---------------------------------------------------------------------
create table if not exists public.loans (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  amount       numeric(14, 2) not null check (amount > 0),
  taken_on     date not null,
  note         text,
  removed_at   timestamptz,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists loans_emp_idx on public.loans (employee_id, taken_on);

create table if not exists public.loan_deductions (
  id           uuid primary key default gen_random_uuid(),
  loan_id      uuid not null references public.loans (id) on delete cascade,
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  source       text not null check (source in ('variable', 'bonus')),
  source_id    uuid not null,
  pay_month    date,
  amount       numeric(14, 2) not null check (amount > 0),
  voided_at    timestamptz,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists loan_deductions_loan_idx on public.loan_deductions (loan_id) where voided_at is null;
create index if not exists loan_deductions_src_idx on public.loan_deductions (source, source_id) where voided_at is null;

create or replace function public.loan_remaining(p_loan uuid)
returns numeric language sql stable security definer set search_path = public
as $$
  select l.amount - coalesce((select sum(d.amount) from public.loan_deductions d where d.loan_id = l.id and d.voided_at is null), 0)
    from public.loans l where l.id = p_loan;
$$;

-- Replaces the loan deduction taken from one Variable / Bonus line and
-- spreads it over the employee's open loans, oldest first. Returns the
-- amount actually deducted (never more than the loans still owe).
create or replace function public._apply_loan_deduction(p_emp uuid, p_source text, p_source_id uuid, p_month date, p_amount numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
declare
  v_left    numeric := greatest(coalesce(p_amount, 0), 0);
  v_applied numeric := 0;
  v_take    numeric;
  r         record;
begin
  update public.loan_deductions set voided_at = now()
   where source = p_source and source_id = p_source_id and voided_at is null;
  for r in select l.id, public.loan_remaining(l.id) as remaining
             from public.loans l
            where l.employee_id = p_emp and l.removed_at is null
            order by l.taken_on, l.created_at loop
    exit when v_left <= 0;
    continue when r.remaining <= 0;
    v_take := least(v_left, r.remaining);
    insert into public.loan_deductions (loan_id, employee_id, source, source_id, pay_month, amount, created_by)
    values (r.id, p_emp, p_source, p_source_id, date_trunc('month', p_month)::date, v_take, auth.uid());
    v_left := v_left - v_take;
    v_applied := v_applied + v_take;
  end loop;
  return v_applied;
end;
$$;

create or replace function public.admin_add_loan(p_employee uuid, p_amount numeric, p_taken_on date, p_note text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.profiles where id = p_employee and status = 'active') then
    raise exception 'Employee not found';
  end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the loan amount'; end if;
  if p_taken_on is null then raise exception 'Enter the date the loan was taken'; end if;
  insert into public.loans (employee_id, amount, taken_on, note, created_by)
  values (p_employee, p_amount, p_taken_on, nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  perform public._fin_log('loan', p_employee, p_taken_on, 'Loan added', p_amount, jsonb_build_object('loan_id', v_id, 'note', nullif(trim(p_note), '')));
  return v_id;
end;
$$;

create or replace function public.admin_remove_loan(p_loan uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_emp uuid; v_amt numeric; v_on date;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if exists (select 1 from public.loan_deductions where loan_id = p_loan and voided_at is null) then
    raise exception 'This loan already has deductions — remove those deductions first';
  end if;
  update public.loans set removed_at = now() where id = p_loan and removed_at is null
  returning employee_id, amount, taken_on into v_emp, v_amt, v_on;
  if not found then raise exception 'Loan not found'; end if;
  perform public._fin_log('loan', v_emp, v_on, 'Loan removed', v_amt, jsonb_build_object('loan_id', p_loan));
end;
$$;

-- ---------------------------------------------------------------------
-- Variable payouts (uploaded calculated sheet)
-- ---------------------------------------------------------------------
create table if not exists public.variable_uploads (
  id           uuid primary key default gen_random_uuid(),
  pay_month    date not null check (extract(day from pay_month) = 1),
  file_name    text,
  row_count    integer not null default 0,
  uploaded_by  uuid references public.profiles (id) on delete set null,
  uploaded_at  timestamptz not null default now()
);

create table if not exists public.variable_payouts (
  id              uuid primary key default gen_random_uuid(),
  upload_id       uuid references public.variable_uploads (id) on delete set null,
  employee_id     uuid references public.profiles (id) on delete set null,
  emp_code        text not null,
  emp_name        text,
  pay_month       date not null check (extract(day from pay_month) = 1),
  amount          numeric(14, 2) not null,
  remarks         text,
  loan_deduction  numeric(14, 2) not null default 0,
  deduct_full     boolean not null default false,
  removed_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists variable_payouts_month_idx on public.variable_payouts (pay_month) where removed_at is null;
create index if not exists variable_payouts_emp_idx on public.variable_payouts (employee_id) where removed_at is null;

-- p_rows: [{"emp_code","emp_name","amount","remarks"}]; p_replace = remove this month's earlier rows first
create or replace function public.admin_import_variable(p_month date, p_file_name text, p_rows jsonb, p_replace boolean default true)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_month  date := date_trunc('month', p_month)::date;
  v_upload uuid;
  r        record;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'The sheet has no rows'; end if;

  if p_replace then
    for r in select id, employee_id, amount, loan_deduction from public.variable_payouts where pay_month = v_month and removed_at is null loop
      update public.loan_deductions set voided_at = now() where source = 'variable' and source_id = r.id and voided_at is null;
      update public.variable_payouts set removed_at = now(), updated_at = now() where id = r.id;
      perform public._fin_log('variable', r.employee_id, v_month, 'Replaced by a new upload', r.amount,
        jsonb_build_object('line_id', r.id, 'loan_deduction_reversed', r.loan_deduction));
      if r.loan_deduction > 0 then
        perform public._fin_log('loan', r.employee_id, v_month, 'Deduction reversed (variable re-uploaded)', r.loan_deduction, jsonb_build_object('line_id', r.id));
      end if;
    end loop;
  end if;

  insert into public.variable_uploads (pay_month, file_name, row_count, uploaded_by)
  values (v_month, nullif(trim(p_file_name), ''), jsonb_array_length(p_rows), auth.uid())
  returning id into v_upload;

  insert into public.variable_payouts (upload_id, employee_id, emp_code, emp_name, pay_month, amount, remarks)
  select v_upload,
         (select p.id from public.profiles p
           where p.status = 'active' and p.fnf_completed_at is null
             and public.norm_emp_code(p.employee_code) = public.norm_emp_code(x.emp_code) limit 1),
         trim(x.emp_code), nullif(trim(x.emp_name), ''), v_month, coalesce(x.amount, 0), nullif(trim(x.remarks), '')
    from jsonb_to_recordset(p_rows) as x(emp_code text, emp_name text, amount numeric, remarks text)
   where coalesce(trim(x.emp_code), '') <> '';

  insert into public.finance_log (section, employee_id, month, action, amount, details, created_by)
  select 'variable', v.employee_id, v_month, 'Variable uploaded', v.amount,
         jsonb_build_object('file', p_file_name, 'emp_code', v.emp_code), auth.uid()
    from public.variable_payouts v where v.upload_id = v_upload;

  return jsonb_build_object('upload_id', v_upload,
    'rows', (select count(*) from public.variable_payouts where upload_id = v_upload),
    'unmatched', (select count(*) from public.variable_payouts where upload_id = v_upload and employee_id is null));
end;
$$;

-- Loan deduction for one Variable or Bonus line.
-- p_full = deduct the whole line amount (capped at what the loans still owe).
create or replace function public.admin_set_loan_deduction(p_source text, p_id uuid, p_amount numeric, p_full boolean)
returns numeric language plpgsql security definer set search_path = public
as $$
declare
  v_emp uuid; v_month date; v_line numeric; v_applied numeric;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_source = 'variable' then
    select employee_id, pay_month, amount into v_emp, v_month, v_line from public.variable_payouts where id = p_id and removed_at is null;
  elsif p_source = 'bonus' then
    select employee_id, pay_month, amount into v_emp, v_month, v_line from public.bonus_payments where id = p_id and removed_at is null;
  else
    raise exception 'Unknown source';
  end if;
  if v_month is null then raise exception 'Line not found'; end if;
  if v_emp is null then raise exception 'This line is not matched to an employee'; end if;
  if not coalesce(p_full, false) and coalesce(p_amount, 0) > v_line then
    raise exception 'Loan deduction cannot be more than the line amount';
  end if;

  v_applied := public._apply_loan_deduction(v_emp, p_source, p_id, v_month,
                 case when coalesce(p_full, false) then v_line else coalesce(p_amount, 0) end);

  if p_source = 'variable' then
    update public.variable_payouts set loan_deduction = v_applied, deduct_full = coalesce(p_full, false), updated_at = now() where id = p_id;
  else
    update public.bonus_payments set loan_deduction = v_applied, deduct_full = coalesce(p_full, false), updated_at = now() where id = p_id;
  end if;

  perform public._fin_log(p_source, v_emp, v_month,
    case when v_applied > 0 then 'Loan deducted' || case when coalesce(p_full, false) then ' (full)' else '' end else 'Loan deduction cleared' end,
    v_applied, jsonb_build_object('line_id', p_id, 'line_amount', v_line));
  perform public._fin_log('loan', v_emp, v_month,
    case when v_applied > 0 then 'Deducted from ' || p_source else 'Deduction from ' || p_source || ' cleared' end,
    v_applied, jsonb_build_object('line_id', p_id));
  return v_applied;
end;
$$;

create or replace function public.admin_remove_variable_payout(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_emp uuid; v_month date; v_amt numeric;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.loan_deductions set voided_at = now() where source = 'variable' and source_id = p_id and voided_at is null;
  update public.variable_payouts set removed_at = now(), updated_at = now() where id = p_id and removed_at is null
  returning employee_id, pay_month, amount into v_emp, v_month, v_amt;
  if not found then raise exception 'Line not found'; end if;
  perform public._fin_log('variable', v_emp, v_month, 'Variable line removed', v_amt, jsonb_build_object('line_id', p_id));
end;
$$;

-- ---------------------------------------------------------------------
-- Bonus lines: loan deduction columns + logging
-- ---------------------------------------------------------------------
alter table public.bonus_payments
  add column if not exists loan_deduction numeric(14, 2) not null default 0,
  add column if not exists deduct_full    boolean not null default false;

-- p_items [{"id"|null, "employee_id", "description", "pay_month", "amount", "use_current_salary",
--           "loan_deduction", "deduct_full", "removed": bool}]
create or replace function public.admin_save_bonus_lines(p_items jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare
  r     record;
  v_id  uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  for r in select * from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
             as x(id uuid, employee_id uuid, description text, pay_month date, amount numeric,
                  use_current_salary boolean, loan_deduction numeric, deduct_full boolean, removed boolean) loop
    if coalesce(r.removed, false) then
      update public.loan_deductions set voided_at = now() where source = 'bonus' and source_id = r.id and voided_at is null;
      update public.bonus_payments set removed_at = now(), updated_at = now() where id = r.id and removed_at is null;
      if found then
        perform public._fin_log('bonus', (select employee_id from public.bonus_payments where id = r.id),
          (select pay_month from public.bonus_payments where id = r.id), 'Line removed',
          (select amount from public.bonus_payments where id = r.id), jsonb_build_object('line_id', r.id));
      end if;
      continue;
    end if;
    if coalesce(trim(r.description), '') = '' or r.pay_month is null or r.amount is null then
      raise exception 'Every line needs a description, month and amount';
    end if;
    if not exists (select 1 from public.comp_eligibility where employee_id = r.employee_id and program = 'bonus' and eligible) then
      raise exception 'An employee in the list is not marked eligible for bonus / leave encashment';
    end if;
    if coalesce(r.loan_deduction, 0) > r.amount and not coalesce(r.deduct_full, false) then
      raise exception 'Loan deduction cannot be more than the line amount';
    end if;
    if r.id is null then
      insert into public.bonus_payments (employee_id, description, pay_month, amount, use_current_salary, created_by)
      values (r.employee_id, trim(r.description), date_trunc('month', r.pay_month)::date, r.amount,
              coalesce(r.use_current_salary, false), auth.uid())
      returning id into v_id;
      perform public._fin_log('bonus', r.employee_id, r.pay_month, 'Line added: ' || trim(r.description), r.amount, jsonb_build_object('line_id', v_id));
    else
      v_id := r.id;
      update public.bonus_payments
         set employee_id = r.employee_id, description = trim(r.description),
             pay_month = date_trunc('month', r.pay_month)::date, amount = r.amount,
             use_current_salary = coalesce(r.use_current_salary, false), updated_at = now()
       where id = r.id and removed_at is null;
      perform public._fin_log('bonus', r.employee_id, r.pay_month, 'Line updated: ' || trim(r.description), r.amount, jsonb_build_object('line_id', v_id));
    end if;
    if coalesce(r.loan_deduction, 0) > 0 or coalesce(r.deduct_full, false)
       or exists (select 1 from public.loan_deductions where source = 'bonus' and source_id = v_id and voided_at is null) then
      perform public.admin_set_loan_deduction('bonus', v_id, coalesce(r.loan_deduction, 0), coalesce(r.deduct_full, false));
    end if;
  end loop;
end;
$$;

-- Payroll saves are logged too
create or replace function public.admin_save_payroll(p_run uuid, p_results jsonb, p_rules jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.payroll_runs where id = p_run and superseded_at is null) then
    raise exception 'This attendance upload has been replaced — reload the page';
  end if;

  update public.payroll_results set included = false where run_id = p_run;

  insert into public.payroll_results (
    run_id, employee_id, emp_code, monthly_salary, daily_salary,
    pre_full, pre_half, pre_leave, pre_weekly_off, post_full, post_half, post_leave, post_weekly_off,
    payable, pt, net_payable, included, computed_by, computed_at)
  select p_run, x.employee_id, x.emp_code, x.monthly_salary, x.daily_salary,
         x.pre_full, x.pre_half, x.pre_leave, x.pre_weekly_off, x.post_full, x.post_half, x.post_leave, x.post_weekly_off,
         x.payable, coalesce(x.pt, 0), coalesce(x.net_payable, x.payable), true, auth.uid(), now()
    from jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(
         employee_id uuid, emp_code text, monthly_salary numeric, daily_salary numeric,
         pre_full int, pre_half int, pre_leave int, pre_weekly_off int,
         post_full int, post_half int, post_leave int, post_weekly_off int,
         payable numeric, pt numeric, net_payable numeric)
  on conflict (run_id, employee_id) do update set
    emp_code = excluded.emp_code, monthly_salary = excluded.monthly_salary, daily_salary = excluded.daily_salary,
    pre_full = excluded.pre_full, pre_half = excluded.pre_half, pre_leave = excluded.pre_leave,
    pre_weekly_off = excluded.pre_weekly_off, post_full = excluded.post_full, post_half = excluded.post_half,
    post_leave = excluded.post_leave, post_weekly_off = excluded.post_weekly_off, payable = excluded.payable,
    pt = excluded.pt, net_payable = excluded.net_payable,
    included = true, computed_by = excluded.computed_by, computed_at = excluded.computed_at;

  update public.payroll_runs
     set processed_at = now(), processed_by = auth.uid(), rules_snapshot = p_rules
   where id = p_run;

  insert into public.finance_log (section, employee_id, month, action, amount, details, created_by)
  select 'payroll', x.employee_id, (select month from public.payroll_runs where id = p_run), 'Payroll saved', x.net_payable,
         jsonb_build_object('earned', x.payable, 'pt', x.pt), auth.uid()
    from jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(employee_id uuid, payable numeric, pt numeric, net_payable numeric);
end;
$$;

-- ---------------------------------------------------------------------
-- RLS, grants
-- ---------------------------------------------------------------------
alter table public.finance_log      enable row level security;
alter table public.loans            enable row level security;
alter table public.loan_deductions  enable row level security;
alter table public.variable_uploads enable row level security;
alter table public.variable_payouts enable row level security;

do $do$
declare
  t text;
begin
  foreach t in array array['finance_log', 'loans', 'loan_deductions', 'variable_uploads', 'variable_payouts'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t
                                              and policyname = t || '_admin_select') then
      execute format('create policy %I on public.%I for select to authenticated using (public.is_admin())',
                     t || '_admin_select', t);
    end if;
  end loop;
end
$do$;

grant select on public.finance_log, public.loans, public.loan_deductions, public.variable_uploads, public.variable_payouts to authenticated;

revoke execute on function public._fin_log(text, uuid, date, text, numeric, jsonb) from public, anon, authenticated;
revoke execute on function public._apply_loan_deduction(uuid, text, uuid, date, numeric) from public, anon, authenticated;
revoke execute on function public.loan_remaining(uuid) from public, anon;
revoke execute on function public.admin_set_employment_status(uuid, text, date, text) from public, anon;
revoke execute on function public.admin_complete_fnf(uuid) from public, anon;
revoke execute on function public.admin_add_loan(uuid, numeric, date, text) from public, anon;
revoke execute on function public.admin_remove_loan(uuid) from public, anon;
revoke execute on function public.admin_import_variable(date, text, jsonb, boolean) from public, anon;
revoke execute on function public.admin_set_loan_deduction(text, uuid, numeric, boolean) from public, anon;
revoke execute on function public.admin_remove_variable_payout(uuid) from public, anon;
revoke execute on function public.admin_save_bonus_lines(jsonb) from public, anon;
grant execute on function public.loan_remaining(uuid) to authenticated;
grant execute on function public.admin_set_employment_status(uuid, text, date, text) to authenticated;
grant execute on function public.admin_complete_fnf(uuid) to authenticated;
grant execute on function public.admin_add_loan(uuid, numeric, date, text) to authenticated;
grant execute on function public.admin_remove_loan(uuid) to authenticated;
grant execute on function public.admin_import_variable(date, text, jsonb, boolean) to authenticated;
grant execute on function public.admin_set_loan_deduction(text, uuid, numeric, boolean) to authenticated;
grant execute on function public.admin_remove_variable_payout(uuid) to authenticated;
grant execute on function public.admin_save_bonus_lines(jsonb) to authenticated;
