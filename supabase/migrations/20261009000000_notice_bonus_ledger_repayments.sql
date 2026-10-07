-- =====================================================================
-- Altius HRMS — notice period, bonus ledger, manual loan repayments
--
--  * Notice period: profiles.resignation_date marks an employee who has
--    resigned and is serving notice (still employment_status 'active',
--    still in the Active lists). exit_date holds the last working day.
--    "Resigned" then moves them to R&T; F&F is due 60 days after the
--    last working day.
--  * Bonus & Leave Encash: payments are added once (with a date) and
--    become a read-only ledger — no edits after saving.
--  * Loans: manual repayments (date + amount) reduce the loan remaining.
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.profiles
  add column if not exists resignation_date date;

alter table public.bonus_payments
  add column if not exists pay_date date;

-- ---------------------------------------------------------------------
-- Notice period
-- ---------------------------------------------------------------------
-- p_resign_date null = resignation withdrawn (back to plain Active)
create or replace function public.admin_set_notice(p_user uuid, p_resign_date date, p_last_day date, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_was date;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own employment status'; end if;
  select resignation_date into v_was from public.profiles
   where id = p_user and status = 'active' and employment_status = 'active' and fnf_completed_at is null;
  if not found then raise exception 'Only an active employee can be put on notice'; end if;

  if p_resign_date is null then
    update public.profiles set resignation_date = null, exit_date = null, exit_note = null where id = p_user;
    perform public._fin_log('emd', p_user, current_date, 'Resignation withdrawn — back to active', null, null);
    return;
  end if;
  if p_last_day is null then raise exception 'Pick the last working day'; end if;
  if p_last_day < p_resign_date then raise exception 'The last working day cannot be before the resignation date'; end if;

  update public.profiles
     set resignation_date = p_resign_date, exit_date = p_last_day, exit_note = nullif(trim(p_note), '')
   where id = p_user;
  perform public._fin_log('emd', p_user, p_resign_date,
    case when v_was is null then 'Resignation received — on notice period' else 'Notice period updated' end, null,
    jsonb_build_object('resignation_date', p_resign_date, 'last_working_day', p_last_day,
                       'notice_days', p_last_day - p_resign_date, 'note', nullif(trim(p_note), '')));
end;
$$;

-- Resigned / Terminated keep the last working day from the notice period
-- when none is given; Active clears the whole exit.
create or replace function public.admin_set_employment_status(p_user uuid, p_status text, p_exit_date date default null, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own employment status'; end if;
  if p_status not in ('active', 'resigned', 'terminated') then raise exception 'Unknown status'; end if;
  update public.profiles
     set employment_status = p_status,
         exit_date = case when p_status = 'active' then null else coalesce(p_exit_date, exit_date, current_date) end,
         exit_note = case when p_status = 'active' then null else coalesce(nullif(trim(p_note), ''), exit_note) end,
         resignation_date = case when p_status = 'active' then null else resignation_date end
   where id = p_user and status = 'active' and fnf_completed_at is null;
  if not found then raise exception 'Employee not found, or F&F is already completed'; end if;
  perform public._fin_log('emd', p_user, coalesce(p_exit_date, current_date),
    case p_status when 'active' then 'Marked active again' when 'resigned' then 'Marked resigned — moved to R&T' else 'Marked terminated — moved to R&T' end,
    null, jsonb_build_object('last_working_day', (select exit_date from public.profiles where id = p_user),
                             'settlement_due', (select exit_date + 60 from public.profiles where id = p_user),
                             'note', nullif(trim(p_note), '')));
end;
$$;

-- ---------------------------------------------------------------------
-- Manual loan repayments
-- ---------------------------------------------------------------------
create table if not exists public.loan_repayments (
  id           uuid primary key default gen_random_uuid(),
  loan_id      uuid not null references public.loans (id) on delete cascade,
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  paid_on      date not null,
  amount       numeric(14, 2) not null check (amount > 0),
  note         text,
  voided_at    timestamptz,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists loan_repayments_loan_idx on public.loan_repayments (loan_id) where voided_at is null;

-- Remaining = amount − Variable/Bonus deductions − manual repayments
create or replace function public.loan_remaining(p_loan uuid)
returns numeric language sql stable security definer set search_path = public
as $$
  select l.amount
         - coalesce((select sum(d.amount) from public.loan_deductions d where d.loan_id = l.id and d.voided_at is null), 0)
         - coalesce((select sum(r.amount) from public.loan_repayments r where r.loan_id = l.id and r.voided_at is null), 0)
    from public.loans l where l.id = p_loan;
$$;

create or replace function public.admin_add_loan_repayment(p_loan uuid, p_paid_on date, p_amount numeric, p_note text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_emp uuid; v_left numeric; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select employee_id into v_emp from public.loans where id = p_loan and removed_at is null;
  if v_emp is null then raise exception 'Loan not found'; end if;
  if p_paid_on is null then raise exception 'Enter the repayment date'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the repayment amount'; end if;
  v_left := public.loan_remaining(p_loan);
  if p_amount > v_left then
    raise exception 'Repayment is more than the loan remaining (%)', to_char(v_left, 'FM99,99,99,99,990.00');
  end if;
  insert into public.loan_repayments (loan_id, employee_id, paid_on, amount, note, created_by)
  values (p_loan, v_emp, p_paid_on, p_amount, nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  perform public._fin_log('loan', v_emp, p_paid_on, 'Repayment received', p_amount,
    jsonb_build_object('loan_id', p_loan, 'repayment_id', v_id, 'paid_on', p_paid_on,
                       'remaining_after', v_left - p_amount, 'note', nullif(trim(p_note), '')));
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
  if exists (select 1 from public.loan_deductions where loan_id = p_loan and voided_at is null)
     or exists (select 1 from public.loan_repayments where loan_id = p_loan and voided_at is null) then
    raise exception 'This loan already has repayments — it cannot be removed';
  end if;
  update public.loans set removed_at = now() where id = p_loan and removed_at is null
  returning employee_id, amount, taken_on into v_emp, v_amt, v_on;
  if not found then raise exception 'Loan not found'; end if;
  perform public._fin_log('loan', v_emp, v_on, 'Loan removed', v_amt, jsonb_build_object('loan_id', p_loan));
end;
$$;

-- ---------------------------------------------------------------------
-- Bonus & Leave Encash — add-only ledger
-- p_items [{"employee_id", "description", "pay_date", "amount", "use_current_salary",
--           "loan_deduction", "deduct_full"}]
-- Each payment is one ledger row (and one log line). Saved payments
-- are read-only.
-- ---------------------------------------------------------------------
create or replace function public.admin_add_bonus_payments(p_items jsonb)
returns int language plpgsql security definer set search_path = public
as $$
declare
  r       record;
  v_id    uuid;
  v_ded   numeric;
  v_n     int := 0;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  for r in select * from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
             as x(employee_id uuid, description text, pay_date date, amount numeric,
                  use_current_salary boolean, loan_deduction numeric, deduct_full boolean) loop
    if coalesce(trim(r.description), '') = '' or r.pay_date is null or coalesce(r.amount, 0) <= 0 then
      raise exception 'Every line needs a description, date and amount';
    end if;
    if not exists (select 1 from public.profiles where id = r.employee_id and status = 'active' and fnf_completed_at is null) then
      raise exception 'Employee not found';
    end if;
    if not exists (select 1 from public.comp_eligibility where employee_id = r.employee_id and program = 'bonus' and eligible) then
      raise exception 'An employee in the list is not marked eligible for bonus / leave encashment';
    end if;
    if not coalesce(r.deduct_full, false) and coalesce(r.loan_deduction, 0) > r.amount then
      raise exception 'Loan deduction cannot be more than the amount';
    end if;

    insert into public.bonus_payments (employee_id, description, pay_month, pay_date, amount, use_current_salary, created_by)
    values (r.employee_id, trim(r.description), date_trunc('month', r.pay_date)::date, r.pay_date, r.amount,
            coalesce(r.use_current_salary, false), auth.uid())
    returning id into v_id;

    v_ded := 0;
    if coalesce(r.deduct_full, false) or coalesce(r.loan_deduction, 0) > 0 then
      v_ded := public._apply_loan_deduction(r.employee_id, 'bonus', v_id, r.pay_date,
                 case when coalesce(r.deduct_full, false) then r.amount else r.loan_deduction end);
      update public.bonus_payments set loan_deduction = v_ded, deduct_full = coalesce(r.deduct_full, false) where id = v_id;
      if v_ded > 0 then
        perform public._fin_log('loan', r.employee_id, r.pay_date, 'Deducted from bonus: ' || trim(r.description), v_ded,
          jsonb_build_object('line_id', v_id, 'paid_on', r.pay_date));
      end if;
    end if;

    perform public._fin_log('bonus', r.employee_id, r.pay_date, trim(r.description), r.amount,
      jsonb_build_object('line_id', v_id, 'pay_date', r.pay_date, 'loan_deduction', v_ded,
                         'deduct_full', coalesce(r.deduct_full, false), 'net', r.amount - v_ded));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- RLS, grants
-- ---------------------------------------------------------------------
alter table public.loan_repayments enable row level security;

do $do$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'loan_repayments'
                                            and policyname = 'loan_repayments_admin_select') then
    create policy loan_repayments_admin_select on public.loan_repayments for select to authenticated using (public.is_admin());
  end if;
end
$do$;

grant select on public.loan_repayments to authenticated;

revoke execute on function public.admin_set_notice(uuid, date, date, text) from public, anon;
revoke execute on function public.admin_add_loan_repayment(uuid, date, numeric, text) from public, anon;
revoke execute on function public.admin_add_bonus_payments(jsonb) from public, anon;
revoke execute on function public.admin_save_bonus_lines(jsonb) from authenticated;
grant execute on function public.admin_set_notice(uuid, date, date, text) to authenticated;
grant execute on function public.admin_add_loan_repayment(uuid, date, numeric, text) to authenticated;
grant execute on function public.admin_add_bonus_payments(jsonb) to authenticated;
