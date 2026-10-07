-- =====================================================================
--  Altius HRMS — Module 3: Payroll (attendance-based monthly salary)
--
--  * payroll_runs         one attendance upload per month; re-uploading a
--                         month supersedes the previous upload (kept as
--                         history) and carries its manual adjustments over
--  * attendance_punches   the parsed rows of the uploaded sheet
--                         (EmpCode, name, date, day, IN, OUT). The Excel
--                         file itself is never stored.
--  * attendance_code_map  sheet EmpCode → employee in Employee Master Data
--  * attendance_adjustments  admin's day-wise overrides (F / HD / L)
--  * payroll_results      saved monthly payout per employee
--  * app_settings 'attendance_rules'  full-day working hours set by HR
--
--  Admin-only: every table is readable only by an active admin, and every
--  write goes through a SECURITY DEFINER function that checks is_admin().
--  Nothing here hard-deletes data.
-- =====================================================================

create table if not exists public.payroll_runs (
  id                uuid primary key default gen_random_uuid(),
  month             date not null check (extract(day from month) = 1),
  source_file_name  text,
  row_count         integer not null default 0,
  employee_count    integer not null default 0,
  uploaded_by       uuid references public.profiles (id) on delete set null,
  uploaded_at       timestamptz not null default now(),
  superseded_at     timestamptz,
  processed_at      timestamptz,
  processed_by      uuid references public.profiles (id) on delete set null,
  rules_snapshot    jsonb
);
create unique index if not exists payroll_runs_one_active_per_month
  on public.payroll_runs (month) where superseded_at is null;

create table if not exists public.attendance_punches (
  id         bigint generated always as identity primary key,
  run_id     uuid not null references public.payroll_runs (id) on delete cascade,
  emp_code   text not null,
  emp_name   text,
  work_date  date not null,
  day_label  text,
  punch_in   time,
  punch_out  time,
  unique (run_id, emp_code, work_date)
);
create index if not exists attendance_punches_run_idx on public.attendance_punches (run_id, emp_code);

create table if not exists public.attendance_code_map (
  emp_code     text primary key,
  employee_id  uuid references public.profiles (id) on delete set null,
  sheet_name   text,
  mapped_by    uuid references public.profiles (id) on delete set null,
  mapped_at    timestamptz not null default now()
);
create unique index if not exists attendance_code_map_one_code_per_employee
  on public.attendance_code_map (employee_id) where employee_id is not null;

create table if not exists public.attendance_adjustments (
  run_id        uuid not null references public.payroll_runs (id) on delete cascade,
  emp_code      text not null,
  work_date     date not null,
  final_status  text check (final_status in ('F', 'HD', 'L')),   -- null = use the system status
  adjusted_by   uuid references public.profiles (id) on delete set null,
  adjusted_at   timestamptz not null default now(),
  primary key (run_id, emp_code, work_date)
);

create table if not exists public.payroll_results (
  run_id           uuid not null references public.payroll_runs (id) on delete cascade,
  employee_id      uuid not null references public.profiles (id) on delete cascade,
  emp_code         text not null,
  monthly_salary   numeric(12, 2) not null,
  daily_salary     numeric(12, 4) not null,
  pre_full         integer not null default 0,
  pre_half         integer not null default 0,
  pre_leave        integer not null default 0,
  pre_weekly_off   integer not null default 0,
  post_full        integer not null default 0,
  post_half        integer not null default 0,
  post_leave       integer not null default 0,
  post_weekly_off  integer not null default 0,
  payable          numeric(12, 2) not null,
  included         boolean not null default true,
  computed_by      uuid references public.profiles (id) on delete set null,
  computed_at      timestamptz not null default now(),
  primary key (run_id, employee_id)
);

insert into public.app_settings (key, value)
values ('attendance_rules', '{"weekday_full_minutes": 540, "saturday_full_minutes": 300, "sunday_paid_off": true}'::jsonb)
on conflict (key) do nothing;

alter table public.payroll_runs           enable row level security;
alter table public.attendance_punches     enable row level security;
alter table public.attendance_code_map    enable row level security;
alter table public.attendance_adjustments enable row level security;
alter table public.payroll_results        enable row level security;

do $do$
declare
  t text;
begin
  foreach t in array array['payroll_runs', 'attendance_punches', 'attendance_code_map',
                           'attendance_adjustments', 'payroll_results'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t
                                              and policyname = t || '_admin_select') then
      execute format('create policy %I on public.%I for select to authenticated using (public.is_admin())',
                     t || '_admin_select', t);
    end if;
  end loop;
end
$do$;

grant select on public.payroll_runs, public.attendance_punches, public.attendance_code_map,
                public.attendance_adjustments, public.payroll_results to authenticated;

-- ---------------------------------------------------------------------
-- Upload: store the parsed sheet for a month.
-- p_rows: [{"emp_code","emp_name","work_date":"2026-10-01","day_label","punch_in":"09:30","punch_out":"18:45"}]
-- ---------------------------------------------------------------------
create or replace function public.admin_import_attendance(p_month date, p_file_name text, p_rows jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_old   uuid;
  v_new   uuid;
  v_bad   date;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'The sheet has no attendance rows';
  end if;

  select x.work_date into v_bad
    from jsonb_to_recordset(p_rows) as x(work_date date)
   where x.work_date is null or date_trunc('month', x.work_date)::date <> v_month
   limit 1;
  if found then
    raise exception 'Row dated % is outside %', coalesce(v_bad::text, '(blank)'), to_char(v_month, 'Mon YYYY');
  end if;

  select id into v_old from public.payroll_runs where month = v_month and superseded_at is null;
  if v_old is not null then
    update public.payroll_runs set superseded_at = now() where id = v_old;
  end if;

  insert into public.payroll_runs (month, source_file_name, uploaded_by)
  values (v_month, nullif(trim(p_file_name), ''), auth.uid())
  returning id into v_new;

  -- several rows for the same person and day are merged: earliest IN, latest OUT
  insert into public.attendance_punches (run_id, emp_code, emp_name, work_date, day_label, punch_in, punch_out)
  select v_new, trim(x.emp_code), max(nullif(trim(x.emp_name), '')), x.work_date,
         max(nullif(trim(x.day_label), '')), min(x.punch_in), max(x.punch_out)
    from jsonb_to_recordset(p_rows)
         as x(emp_code text, emp_name text, work_date date, day_label text, punch_in time, punch_out time)
   where coalesce(trim(x.emp_code), '') <> ''
   group by trim(x.emp_code), x.work_date;

  if v_old is not null then
    insert into public.attendance_adjustments (run_id, emp_code, work_date, final_status, adjusted_by, adjusted_at)
    select v_new, a.emp_code, a.work_date, a.final_status, a.adjusted_by, a.adjusted_at
      from public.attendance_adjustments a
     where a.run_id = v_old and a.final_status is not null
       and exists (select 1 from public.attendance_punches p
                    where p.run_id = v_new and p.emp_code = a.emp_code and p.work_date = a.work_date);
  end if;

  update public.payroll_runs
     set row_count      = (select count(*) from public.attendance_punches where run_id = v_new),
         employee_count = (select count(distinct emp_code) from public.attendance_punches where run_id = v_new)
   where id = v_new;

  return v_new;
end;
$$;

-- Mapping: sheet EmpCode → employee. p_items: [{"emp_code","employee_id"|null,"sheet_name"}]
create or replace function public.admin_save_code_map(p_items jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'Mapping must be a list'; end if;
  if exists (select 1 from jsonb_to_recordset(p_items) as x(employee_id uuid)
              where x.employee_id is not null
              group by x.employee_id having count(*) > 1) then
    raise exception 'An employee can only be mapped to one EmpCode';
  end if;

  -- free employees that are being moved to a different code in this save
  update public.attendance_code_map m
     set employee_id = null, mapped_by = auth.uid(), mapped_at = now()
   where m.employee_id in (select x.employee_id from jsonb_to_recordset(p_items) as x(emp_code text, employee_id uuid)
                            where x.employee_id is not null and trim(x.emp_code) <> m.emp_code);

  insert into public.attendance_code_map (emp_code, employee_id, sheet_name, mapped_by, mapped_at)
  select trim(x.emp_code), x.employee_id, nullif(trim(x.sheet_name), ''), auth.uid(), now()
    from jsonb_to_recordset(p_items) as x(emp_code text, employee_id uuid, sheet_name text)
   where coalesce(trim(x.emp_code), '') <> ''
  on conflict (emp_code) do update
    set employee_id = excluded.employee_id,
        sheet_name  = coalesce(excluded.sheet_name, attendance_code_map.sheet_name),
        mapped_by   = excluded.mapped_by,
        mapped_at   = excluded.mapped_at;
end;
$$;

-- Day-wise adjustments for one employee. p_items: [{"date":"2026-10-03","status":"F"|"HD"|"L"|null}]
create or replace function public.admin_save_adjustments(p_run uuid, p_emp_code text, p_items jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.payroll_runs where id = p_run and superseded_at is null) then
    raise exception 'This attendance upload has been replaced — reload the page';
  end if;
  insert into public.attendance_adjustments (run_id, emp_code, work_date, final_status, adjusted_by, adjusted_at)
  select p_run, p_emp_code, x.date, nullif(x.status, ''), auth.uid(), now()
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) as x(date date, status text)
  on conflict (run_id, emp_code, work_date) do update
    set final_status = excluded.final_status, adjusted_by = excluded.adjusted_by, adjusted_at = excluded.adjusted_at;
end;
$$;

-- Save the month's payroll (computed in the app from the post-adjustment line).
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
    payable, included, computed_by, computed_at)
  select p_run, x.employee_id, x.emp_code, x.monthly_salary, x.daily_salary,
         x.pre_full, x.pre_half, x.pre_leave, x.pre_weekly_off, x.post_full, x.post_half, x.post_leave, x.post_weekly_off,
         x.payable, true, auth.uid(), now()
    from jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(
         employee_id uuid, emp_code text, monthly_salary numeric, daily_salary numeric,
         pre_full int, pre_half int, pre_leave int, pre_weekly_off int,
         post_full int, post_half int, post_leave int, post_weekly_off int, payable numeric)
  on conflict (run_id, employee_id) do update set
    emp_code = excluded.emp_code, monthly_salary = excluded.monthly_salary, daily_salary = excluded.daily_salary,
    pre_full = excluded.pre_full, pre_half = excluded.pre_half, pre_leave = excluded.pre_leave,
    pre_weekly_off = excluded.pre_weekly_off, post_full = excluded.post_full, post_half = excluded.post_half,
    post_leave = excluded.post_leave, post_weekly_off = excluded.post_weekly_off, payable = excluded.payable,
    included = true, computed_by = excluded.computed_by, computed_at = excluded.computed_at;

  update public.payroll_runs
     set processed_at = now(), processed_by = auth.uid(), rules_snapshot = p_rules
   where id = p_run;
end;
$$;

revoke execute on function public.admin_import_attendance(date, text, jsonb) from public, anon;
revoke execute on function public.admin_save_code_map(jsonb) from public, anon;
revoke execute on function public.admin_save_adjustments(uuid, text, jsonb) from public, anon;
revoke execute on function public.admin_save_payroll(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.admin_import_attendance(date, text, jsonb) to authenticated;
grant execute on function public.admin_save_code_map(jsonb) to authenticated;
grant execute on function public.admin_save_adjustments(uuid, text, jsonb) to authenticated;
grant execute on function public.admin_save_payroll(uuid, jsonb, jsonb) to authenticated;
