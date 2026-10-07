-- =====================================================================
--  Altius HRMS — Finance: Professional Tax, Variable pay,
--  Bonus & Leave Encashment, Monthly Expenses
--
--  * app_settings 'professional_tax'  slabs (monthly salary band → PT amount)
--  * payroll_results.pt / net_payable  PT deducted from the month's payable
--  * comp_eligibility    who is eligible for 'variable' / 'bonus'
--  * variable_entries    variable-pay calculations per employee
--  * bonus_payments      bonus / leave-encashment line items
--  * expense_claims      expenses synced from the Google Form responses sheet
--  * app_settings 'expense_source'  responses-sheet link + column mapping
--
--  Admin-only. Writes go through SECURITY DEFINER functions that check
--  is_admin(). Nothing is hard-deleted: removed rows get removed_at.
-- =====================================================================

-- Employee codes are compared case-insensitively and ignoring leading zeros
-- in each number ("0003" = "003" = "3"; "AI-0047" = "ai-47").
create or replace function public.norm_emp_code(p text)
returns text language sql immutable
as $$ select nullif(regexp_replace(lower(trim(coalesce(p, ''))), '(^|[^0-9])0+([0-9])', '\1\2', 'g'), '') $$;

-- ---------------------------------------------------------------------
-- Professional Tax
-- ---------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('professional_tax', '{"slabs": [
  {"min": 0,     "max": 10000, "amount": 0},
  {"min": 10001, "max": 15000, "amount": 110},
  {"min": 15001, "max": 25000, "amount": 130},
  {"min": 25001, "max": 40000, "amount": 150},
  {"min": 40001, "max": null,  "amount": 200}]}'::jsonb)
on conflict (key) do nothing;

insert into public.app_settings (key, value)
values ('expense_source', '{"url": "", "columns": {}}'::jsonb)
on conflict (key) do nothing;

alter table public.payroll_results
  add column if not exists pt          numeric(12, 2) not null default 0,
  add column if not exists net_payable numeric(12, 2);

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
end;
$$;

-- ---------------------------------------------------------------------
-- Eligibility (Variable, Bonus & Leave Encash)
-- ---------------------------------------------------------------------
create table if not exists public.comp_eligibility (
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  program      text not null check (program in ('variable', 'bonus')),
  eligible     boolean not null default false,
  updated_by   uuid references public.profiles (id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (employee_id, program)
);

-- ---------------------------------------------------------------------
-- Variable pay
-- result = Buy × Buy commission % + Sell × Sell commission %
--          − Current salary × Duration (months) × Sales time %
-- ---------------------------------------------------------------------
create table if not exists public.variable_entries (
  id                   uuid primary key default gen_random_uuid(),
  employee_id          uuid not null references public.profiles (id) on delete cascade,
  period_month         date not null check (extract(day from period_month) = 1),
  duration_months      numeric(8, 2) not null check (duration_months >= 0),
  buy                  numeric(16, 2) not null default 0 check (buy >= 0),
  sell                 numeric(16, 2) not null default 0 check (sell >= 0),
  buy_commission_pct   numeric(8, 4) not null default 0 check (buy_commission_pct >= 0),
  sell_commission_pct  numeric(8, 4) not null default 0 check (sell_commission_pct >= 0),
  sales_time_pct       numeric(6, 2) not null default 0 check (sales_time_pct between 0 and 100),
  current_salary       numeric(12, 2) not null,
  result               numeric(16, 2) not null,
  note                 text,
  removed_at           timestamptz,
  created_by           uuid references public.profiles (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists variable_entries_emp_idx on public.variable_entries (employee_id, period_month desc);

-- ---------------------------------------------------------------------
-- Bonus & Leave Encashment
-- ---------------------------------------------------------------------
create table if not exists public.bonus_payments (
  id                  uuid primary key default gen_random_uuid(),
  employee_id         uuid not null references public.profiles (id) on delete cascade,
  description         text not null,
  pay_month           date not null check (extract(day from pay_month) = 1),
  amount              numeric(12, 2) not null check (amount >= 0),
  use_current_salary  boolean not null default false,
  removed_at          timestamptz,
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists bonus_payments_month_idx on public.bonus_payments (pay_month desc);

-- ---------------------------------------------------------------------
-- Monthly expenses (from the Google Form responses sheet)
-- ---------------------------------------------------------------------
create table if not exists public.expense_claims (
  id            bigint generated always as identity primary key,
  source_key    text not null unique,
  submitted_at  timestamptz,
  emp_code      text,
  emp_name      text,
  employee_id   uuid references public.profiles (id) on delete set null,
  expense_date  date,
  month         date,
  category      text,
  description   text,
  amount        numeric(12, 2),
  receipt_url   text,
  raw           jsonb,
  synced_at     timestamptz not null default now()
);
create index if not exists expense_claims_emp_idx on public.expense_claims (employee_id, month desc);

alter table public.comp_eligibility enable row level security;
alter table public.variable_entries enable row level security;
alter table public.bonus_payments   enable row level security;
alter table public.expense_claims   enable row level security;

do $do$
declare
  t text;
begin
  foreach t in array array['comp_eligibility', 'variable_entries', 'bonus_payments', 'expense_claims'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t
                                              and policyname = t || '_admin_select') then
      execute format('create policy %I on public.%I for select to authenticated using (public.is_admin())',
                     t || '_admin_select', t);
    end if;
  end loop;
end
$do$;

grant select on public.comp_eligibility, public.variable_entries, public.bonus_payments, public.expense_claims to authenticated;

-- Eligibility: p_items [{"employee_id": "...", "eligible": true}]
create or replace function public.admin_set_eligibility(p_program text, p_items jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_program not in ('variable', 'bonus') then raise exception 'Unknown program'; end if;
  insert into public.comp_eligibility (employee_id, program, eligible, updated_by, updated_at)
  select x.employee_id, p_program, coalesce(x.eligible, false), auth.uid(), now()
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) as x(employee_id uuid, eligible boolean)
  on conflict (employee_id, program) do update
    set eligible = excluded.eligible, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;

-- Variable entry: insert (id null) or update. The result is calculated here.
create or replace function public.admin_save_variable_entry(p jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_id     uuid := nullif(p ->> 'id', '')::uuid;
  v_emp    uuid := (p ->> 'employee_id')::uuid;
  v_dur    numeric := coalesce((p ->> 'duration_months')::numeric, 0);
  v_buy    numeric := coalesce((p ->> 'buy')::numeric, 0);
  v_sell   numeric := coalesce((p ->> 'sell')::numeric, 0);
  v_bc     numeric := coalesce((p ->> 'buy_commission_pct')::numeric, 0);
  v_sc     numeric := coalesce((p ->> 'sell_commission_pct')::numeric, 0);
  v_st     numeric := coalesce((p ->> 'sales_time_pct')::numeric, 0);
  v_sal    numeric := coalesce((p ->> 'current_salary')::numeric, 0);
  v_result numeric;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.comp_eligibility where employee_id = v_emp and program = 'variable' and eligible) then
    raise exception 'This employee is not marked eligible for variable pay';
  end if;
  v_result := round(v_buy * v_bc / 100 + v_sell * v_sc / 100 - v_sal * v_dur * v_st / 100, 2);

  if v_id is null then
    insert into public.variable_entries (employee_id, period_month, duration_months, buy, sell, buy_commission_pct,
      sell_commission_pct, sales_time_pct, current_salary, result, note, created_by)
    values (v_emp, date_trunc('month', (p ->> 'period_month')::date)::date, v_dur, v_buy, v_sell, v_bc, v_sc, v_st,
            v_sal, v_result, nullif(trim(p ->> 'note'), ''), auth.uid())
    returning id into v_id;
  else
    update public.variable_entries
       set period_month = date_trunc('month', (p ->> 'period_month')::date)::date, duration_months = v_dur,
           buy = v_buy, sell = v_sell, buy_commission_pct = v_bc, sell_commission_pct = v_sc, sales_time_pct = v_st,
           current_salary = v_sal, result = v_result, note = nullif(trim(p ->> 'note'), ''), updated_at = now()
     where id = v_id and employee_id = v_emp and removed_at is null;
    if not found then raise exception 'Entry not found'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_remove_variable_entry(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.variable_entries set removed_at = now(), updated_at = now() where id = p_id and removed_at is null;
end;
$$;

-- Bonus lines: p_items [{"id"|null, "employee_id", "description", "pay_month", "amount", "use_current_salary", "removed": bool}]
create or replace function public.admin_save_bonus_lines(p_items jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  for r in select * from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
             as x(id uuid, employee_id uuid, description text, pay_month date, amount numeric,
                  use_current_salary boolean, removed boolean) loop
    if coalesce(r.removed, false) then
      update public.bonus_payments set removed_at = now(), updated_at = now() where id = r.id and removed_at is null;
      continue;
    end if;
    if coalesce(trim(r.description), '') = '' or r.pay_month is null or r.amount is null then
      raise exception 'Every line needs a description, month and amount';
    end if;
    if not exists (select 1 from public.comp_eligibility where employee_id = r.employee_id and program = 'bonus' and eligible) then
      raise exception 'An employee in the list is not marked eligible for bonus / leave encashment';
    end if;
    if r.id is null then
      insert into public.bonus_payments (employee_id, description, pay_month, amount, use_current_salary, created_by)
      values (r.employee_id, trim(r.description), date_trunc('month', r.pay_month)::date, r.amount,
              coalesce(r.use_current_salary, false), auth.uid());
    else
      update public.bonus_payments
         set employee_id = r.employee_id, description = trim(r.description),
             pay_month = date_trunc('month', r.pay_month)::date, amount = r.amount,
             use_current_salary = coalesce(r.use_current_salary, false), updated_at = now()
       where id = r.id and removed_at is null;
    end if;
  end loop;
end;
$$;

-- Expense sync: rows parsed from the responses sheet in the browser.
-- Each row is matched to an employee by Employee ID (norm_emp_code).
create or replace function public.admin_sync_expenses(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_total int;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  insert into public.expense_claims (source_key, submitted_at, emp_code, emp_name, employee_id, expense_date, month,
                                     category, description, amount, receipt_url, raw, synced_at)
  select x.source_key, x.submitted_at, nullif(trim(x.emp_code), ''), nullif(trim(x.emp_name), ''),
         (select p.id from public.profiles p
           where p.status = 'active' and public.norm_emp_code(p.employee_code) = public.norm_emp_code(x.emp_code)
           limit 1),
         x.expense_date, date_trunc('month', coalesce(x.expense_date, x.submitted_at::date))::date,
         nullif(trim(x.category), ''), nullif(trim(x.description), ''), x.amount, nullif(trim(x.receipt_url), ''), x.raw, now()
    from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb)) as x(
         source_key text, submitted_at timestamptz, emp_code text, emp_name text, expense_date date,
         category text, description text, amount numeric, receipt_url text, raw jsonb)
   where coalesce(x.source_key, '') <> ''
  on conflict (source_key) do update set
    submitted_at = excluded.submitted_at, emp_code = excluded.emp_code, emp_name = excluded.emp_name,
    employee_id = excluded.employee_id, expense_date = excluded.expense_date, month = excluded.month,
    category = excluded.category, description = excluded.description, amount = excluded.amount,
    receipt_url = excluded.receipt_url, raw = excluded.raw, synced_at = now();

  -- re-match earlier rows too (e.g. after an Employee ID was corrected in EMD)
  update public.expense_claims e
     set employee_id = (select p.id from public.profiles p
                         where p.status = 'active' and public.norm_emp_code(p.employee_code) = public.norm_emp_code(e.emp_code)
                         limit 1);

  select count(*) into v_total from public.expense_claims;
  return jsonb_build_object('total', v_total,
                            'unmatched', (select count(*) from public.expense_claims where employee_id is null));
end;
$$;

revoke execute on function public.admin_set_eligibility(text, jsonb) from public, anon;
revoke execute on function public.admin_save_variable_entry(jsonb) from public, anon;
revoke execute on function public.admin_remove_variable_entry(uuid) from public, anon;
revoke execute on function public.admin_save_bonus_lines(jsonb) from public, anon;
revoke execute on function public.admin_sync_expenses(jsonb) from public, anon;
grant execute on function public.admin_set_eligibility(text, jsonb) to authenticated;
grant execute on function public.admin_save_variable_entry(jsonb) to authenticated;
grant execute on function public.admin_remove_variable_entry(uuid) to authenticated;
grant execute on function public.admin_save_bonus_lines(jsonb) to authenticated;
grant execute on function public.admin_sync_expenses(jsonb) to authenticated;
