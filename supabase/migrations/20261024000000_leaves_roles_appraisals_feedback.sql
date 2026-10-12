-- =====================================================================
-- Altius HRMS — long-leave approvals, role definitions, appraisals,
-- anonymous feedback
--
--  * leave_requests: leave of 2+ working days, applied by the employee
--    from the portal or entered by HR for them. Either way it starts as
--    pending and an admin approves or rejects it (nobody approves their
--    own leave). On approval each working day (Sundays and holidays are
--    skipped) becomes a leave in leave_records, so payroll marks it L.
--    Cancelling an approved leave removes those days again. The request
--    rows are the leave log.
--  * job_roles: roles with their responsibilities. An employee gets a
--    role from the list, customised responsibilities, or both
--    (profiles.job_role_id / profiles.custom_responsibilities).
--  * appraisals: per employee per appraisal month (several in a year are
--    fine) — increment, new salary, promotion (new designation), rating
--    and review. "Saved" appraisals show in the employee's portal and can
--    still be changed; "Save & issue" makes it final: the new salary goes
--    into the salary history from that month (= current salary in EMD) and
--    the new designation into the profile. appraisal_events is the log.
--  * feedback: anonymous. The table has no employee column and nothing
--    about who sent it is stored anywhere in the database.
-- Re-runnable. Nothing is removed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Long leaves
-- ---------------------------------------------------------------------
create table if not exists public.leave_requests (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  from_date    date not null,
  to_date      date not null,
  days         integer not null,
  reason       text,
  source       text not null default 'employee' check (source in ('employee', 'admin')),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn', 'cancelled')),
  admin_note   text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  decided_by   uuid references public.profiles (id) on delete set null,
  decided_at   timestamptz,
  check (to_date > from_date)
);
create index if not exists leave_requests_emp_idx on public.leave_requests (employee_id, from_date);
create index if not exists leave_requests_status_idx on public.leave_requests (status);
alter table public.leave_requests enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'leave_requests' and policyname = 'leave_requests_select') then
    create policy leave_requests_select on public.leave_requests for select to authenticated
      using ((select public.is_admin()) or (employee_id = (select auth.uid()) and not (select public._i_have_left())));
  end if;
end $$;
grant select on public.leave_requests to authenticated;

alter table public.leave_records add column if not exists leave_request_id uuid references public.leave_requests (id) on delete set null;

-- Working days in a range: Sundays and holidays are not counted
create or replace function public._leave_days(p_from date, p_to date)
returns date[] language sql stable security definer set search_path = public
as $$
  select coalesce(array_agg(d::date order by d), '{}')
    from generate_series(p_from, p_to, interval '1 day') d
   where extract(isodow from d) <> 7
     and not exists (select 1 from public.calendar_days c where c.day = d::date and c.kind = 'holiday' and c.removed_at is null);
$$;

create or replace function public._new_leave_request(p_employee uuid, p_from date, p_to date, p_reason text, p_source text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_days date[]; v_id uuid; c public.leave_requests;
begin
  if p_from is null or p_to is null then raise exception 'Pick the from and to dates'; end if;
  if p_to <= p_from then raise exception 'A leave has to be more than one day — pick a “to” date after the “from” date'; end if;
  if p_to - p_from > 92 then raise exception 'A leave can be at most 3 months — split it into two requests'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Add the reason for the leave'; end if;
  v_days := public._leave_days(p_from, p_to);
  if cardinality(v_days) < 2 then raise exception 'A leave has to be more than one working day (Sundays and holidays are not counted)'; end if;
  select * into c from public.leave_requests
   where employee_id = p_employee and status in ('pending', 'approved') and from_date <= p_to and to_date >= p_from
   order by from_date limit 1;
  if c.id is not null then
    raise exception 'This overlaps a leave that is already % (% to %)', c.status, to_char(c.from_date, 'DD-MM-YYYY'), to_char(c.to_date, 'DD-MM-YYYY');
  end if;
  insert into public.leave_requests (employee_id, from_date, to_date, days, reason, source, created_by)
  values (p_employee, p_from, p_to, cardinality(v_days), trim(p_reason), p_source, auth.uid()) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.my_apply_leave(p_from date, p_to date, p_reason text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.status <> 'active' then raise exception 'Your account is not active'; end if;
  if public._i_have_left() then raise exception 'You have already left'; end if;
  return public._new_leave_request(p.id, p_from, p_to, p_reason, 'employee');
end;
$$;

create or replace function public.my_withdraw_leave(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.leave_requests set status = 'withdrawn', decided_at = now()
   where id = p_id and employee_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Only a pending leave can be withdrawn — contact HR'; end if;
end;
$$;

create or replace function public.admin_add_leave_request(p_employee uuid, p_from date, p_to date, p_reason text)
returns uuid language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.profiles where id = p_employee and status = 'active' and employment_status = 'active' and fnf_completed_at is null) then
    raise exception 'Pick an active employee';
  end if;
  return public._new_leave_request(p_employee, p_from, p_to, p_reason, 'admin');
end;
$$;

create or replace function public.admin_decide_leave(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.leave_requests; d date;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null or r.status <> 'pending' then raise exception 'This leave is no longer pending'; end if;
  if r.employee_id = auth.uid() then raise exception 'You cannot approve or reject your own leave — another admin has to'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Add a note for the employee'; end if;
  update public.leave_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  if p_approve then
    foreach d in array public._leave_days(r.from_date, r.to_date) loop
      update public.leave_records set kind = 'full', note = 'Approved leave', leave_request_id = r.id
       where employee_id = r.employee_id and leave_date = d and removed_at is null;
      if not found then
        insert into public.leave_records (employee_id, leave_date, kind, note, created_by, leave_request_id)
        values (r.employee_id, d, 'full', 'Approved leave', auth.uid(), r.id);
      end if;
    end loop;
    perform public._fin_log('payroll', r.employee_id, r.from_date,
      'Leave approved: ' || to_char(r.from_date, 'DD-MM-YYYY') || ' to ' || to_char(r.to_date, 'DD-MM-YYYY') || ' (' || r.days || ' days)', null,
      jsonb_build_object('reason', r.reason, 'note', nullif(trim(p_note), '')));
  end if;
end;
$$;

create or replace function public.admin_cancel_leave(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.leave_requests;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Add a note for the employee'; end if;
  update public.leave_requests set status = 'cancelled', admin_note = trim(p_note), decided_by = auth.uid(), decided_at = now()
   where id = p_id and status = 'approved' returning * into r;
  if r.id is null then raise exception 'Only an approved leave can be cancelled'; end if;
  update public.leave_records set removed_at = now(), removed_by = auth.uid()
   where leave_request_id = r.id and removed_at is null;
  perform public._fin_log('payroll', r.employee_id, r.from_date,
    'Leave cancelled: ' || to_char(r.from_date, 'DD-MM-YYYY') || ' to ' || to_char(r.to_date, 'DD-MM-YYYY'), null,
    jsonb_build_object('note', trim(p_note)));
end;
$$;

-- ---------------------------------------------------------------------
-- Role definitions
-- ---------------------------------------------------------------------
create table if not exists public.job_roles (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  responsibilities  text not null default '',
  created_by        uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_by        uuid references public.profiles (id) on delete set null,
  updated_at        timestamptz not null default now(),
  removed_at        timestamptz
);
create unique index if not exists job_roles_name_uq on public.job_roles (lower(name)) where removed_at is null;
alter table public.job_roles enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'job_roles' and policyname = 'job_roles_admin_select') then
    create policy job_roles_admin_select on public.job_roles for select to authenticated using ((select public.is_admin()));
  end if;
end $$;
grant select on public.job_roles to authenticated;

alter table public.profiles add column if not exists job_role_id uuid references public.job_roles (id) on delete set null;
alter table public.profiles add column if not exists custom_responsibilities text;

create or replace function public.admin_save_job_role(p_id uuid, p_name text, p_responsibilities text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the role a name'; end if;
  if coalesce(trim(p_responsibilities), '') = '' then raise exception 'Add the responsibilities'; end if;
  if exists (select 1 from public.job_roles where lower(name) = lower(trim(p_name)) and removed_at is null and id is distinct from p_id) then
    raise exception 'A role called “%” already exists', trim(p_name);
  end if;
  if p_id is null then
    insert into public.job_roles (name, responsibilities, created_by, updated_by)
    values (trim(p_name), trim(p_responsibilities), auth.uid(), auth.uid()) returning id into v_id;
  else
    update public.job_roles set name = trim(p_name), responsibilities = trim(p_responsibilities), updated_by = auth.uid(), updated_at = now()
     where id = p_id and removed_at is null returning id into v_id;
    if v_id is null then raise exception 'This role was removed'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_remove_job_role(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select count(*) into n from public.profiles where job_role_id = p_id;
  if n > 0 then raise exception 'This role is given to % employee% — change their role in EMD first', n, case when n = 1 then '' else 's' end; end if;
  update public.job_roles set removed_at = now(), updated_by = auth.uid(), updated_at = now() where id = p_id and removed_at is null;
end;
$$;

create or replace function public.admin_set_job_role(p_user uuid, p_role uuid, p_custom text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_role is not null and not exists (select 1 from public.job_roles where id = p_role and removed_at is null) then
    raise exception 'This role was removed — pick another';
  end if;
  update public.profiles set job_role_id = p_role, custom_responsibilities = nullif(trim(p_custom), '')
   where id = p_user and status = 'active';
  if not found then raise exception 'Employee not found'; end if;
  perform public._fin_log('emd', p_user, current_date, 'Role updated', null,
    jsonb_build_object('role', (select name from public.job_roles where id = p_role), 'customised', nullif(trim(p_custom), '') is not null));
end;
$$;

-- The employee's own role and responsibilities (portal)
create or replace function public.my_role()
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public._i_have_left() then null else jsonb_build_object(
           'role', r.name, 'responsibilities', r.responsibilities, 'custom', p.custom_responsibilities) end
    from public.profiles p left join public.job_roles r on r.id = p.job_role_id
   where p.id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- Appraisals
-- ---------------------------------------------------------------------
create table if not exists public.appraisals (
  id                   uuid primary key default gen_random_uuid(),
  employee_id          uuid not null references public.profiles (id) on delete cascade,
  cycle_month          date not null check (extract(day from cycle_month) = 1),
  current_salary       numeric(12, 2),
  increment_pct        numeric(7, 2),
  new_salary           numeric(12, 2),
  current_designation  text,
  new_designation      text,
  rating               text,
  review               text,
  status               text not null default 'saved' check (status in ('saved', 'issued')),
  created_by           uuid references public.profiles (id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_by           uuid references public.profiles (id) on delete set null,
  updated_at           timestamptz not null default now(),
  issued_by            uuid references public.profiles (id) on delete set null,
  issued_at            timestamptz,
  removed_at           timestamptz,
  removed_by           uuid references public.profiles (id) on delete set null,
  unique (employee_id, cycle_month)
);
alter table public.appraisals add column if not exists removed_at timestamptz;
alter table public.appraisals add column if not exists removed_by uuid references public.profiles (id) on delete set null;
create index if not exists appraisals_month_idx on public.appraisals (cycle_month);
alter table public.appraisals enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'appraisals' and policyname = 'appraisals_admin_select') then
    create policy appraisals_admin_select on public.appraisals for select to authenticated using ((select public.is_admin()));
  end if;
end $$;
grant select on public.appraisals to authenticated;

create table if not exists public.appraisal_events (
  id            bigint generated always as identity primary key,
  appraisal_id  uuid references public.appraisals (id) on delete set null,
  employee_id   uuid references public.profiles (id) on delete set null,
  cycle_month   date not null,
  action        text not null check (action in ('saved', 'changed', 'issued')),
  source        text,
  details       jsonb,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists appraisal_events_month_idx on public.appraisal_events (cycle_month, created_at desc);
create index if not exists appraisal_events_emp_idx on public.appraisal_events (employee_id, created_at desc);
alter table public.appraisal_events enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'appraisal_events' and policyname = 'appraisal_events_admin_select') then
    create policy appraisal_events_admin_select on public.appraisal_events for select to authenticated using ((select public.is_admin()));
  end if;
end $$;
grant select on public.appraisal_events to authenticated;

-- Save appraisals for a month (from the grid or an Excel upload). Each row:
-- { employee_id, increment_pct, new_salary, new_designation, rating, review }.
-- With p_issue = true the rows are saved and issued (final).
create or replace function public.admin_save_appraisals(p_month date, p_rows jsonb, p_issue boolean default false, p_source text default 'manual')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  x jsonb; e public.profiles; a public.appraisals; v_new public.appraisals;
  v_cur numeric; v_pct numeric; v_sal numeric; v_desig text; v_rating text; v_review text;
  v_saved integer := 0; v_issued integer := 0; v_skipped jsonb := '[]'::jsonb; v_changes jsonb;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_month is null then raise exception 'Pick the appraisal month'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Nothing to save'; end if;

  for x in select * from jsonb_array_elements(p_rows) loop
    select * into e from public.profiles where id = (x ->> 'employee_id')::uuid and status = 'active';
    if e.id is null then raise exception 'Employee not found'; end if;
    if e.id = auth.uid() then raise exception 'You cannot save your own appraisal — another admin has to'; end if;
    select * into a from public.appraisals where employee_id = e.id and cycle_month = v_month and removed_at is null for update;
    if a.status = 'issued' then
      v_skipped := v_skipped || to_jsonb(e.full_name);
      continue;
    end if;

    -- Current salary: the latest salary before this month (or the one set for this month)
    select amount into v_cur from public.salary_history
     where employee_id = e.id and removed_at is null and effective_month <= v_month
     order by (effective_month = v_month), effective_month desc limit 1;
    v_pct    := nullif(x ->> 'increment_pct', '')::numeric;
    v_sal    := nullif(x ->> 'new_salary', '')::numeric;
    v_desig  := nullif(trim(x ->> 'new_designation'), '');
    v_rating := nullif(trim(x ->> 'rating'), '');
    v_review := nullif(trim(x ->> 'review'), '');
    if v_pct is null and v_sal is null and v_desig is null and v_rating is null and v_review is null then continue; end if;
    if v_sal is not null and v_sal <= 0 then raise exception 'New salary for % must be more than 0', e.full_name; end if;
    if v_pct is not null and (v_pct < -100 or v_pct > 1000) then raise exception 'Increment for % looks wrong (% %%)', e.full_name, v_pct; end if;
    if v_sal is null and v_pct is not null then
      if v_cur is null then raise exception '% has no current salary in EMD — enter the new salary instead of the increment', e.full_name; end if;
      v_sal := round(v_cur * (1 + v_pct / 100));
    elsif v_sal is not null and v_cur is not null and v_cur > 0 then
      v_pct := round((v_sal - v_cur) / v_cur * 100, 2);
    end if;
    if v_desig = coalesce(e.designation, '') then v_desig := null; end if;
    if p_issue and v_sal is null and v_desig is null then
      raise exception 'Add the new salary or promotion for % before issuing', e.full_name;
    end if;

    insert into public.appraisals as t (employee_id, cycle_month, current_salary, increment_pct, new_salary, current_designation, new_designation,
                                        rating, review, created_by, updated_by)
    values (e.id, v_month, v_cur, v_pct, v_sal, e.designation, v_desig, v_rating, v_review, auth.uid(), auth.uid())
    on conflict (employee_id, cycle_month) do update
      set current_salary = excluded.current_salary, increment_pct = excluded.increment_pct, new_salary = excluded.new_salary,
          current_designation = excluded.current_designation, new_designation = excluded.new_designation,
          rating = excluded.rating, review = excluded.review, updated_by = auth.uid(), updated_at = now(),
          status = 'saved', removed_at = null, removed_by = null
    returning * into v_new;

    v_changes := (select coalesce(jsonb_object_agg(k, jsonb_build_object('from', to_jsonb(a) -> k, 'to', to_jsonb(v_new) -> k)), '{}'::jsonb)
                    from unnest(array['increment_pct', 'new_salary', 'new_designation', 'rating', 'review']) k
                   where a.id is null or (to_jsonb(a) -> k) is distinct from (to_jsonb(v_new) -> k));
    if a.id is null or v_changes <> '{}'::jsonb then
      insert into public.appraisal_events (appraisal_id, employee_id, cycle_month, action, source, details, created_by)
      values (v_new.id, e.id, v_month, case when a.id is null then 'saved' else 'changed' end, p_source,
              jsonb_build_object('current_salary', v_cur, 'increment_pct', v_new.increment_pct, 'new_salary', v_new.new_salary,
                                 'new_designation', v_new.new_designation, 'rating', v_new.rating, 'review', v_new.review,
                                 'changes', case when a.id is null then null else v_changes end), auth.uid());
      v_saved := v_saved + 1;
    end if;

    if p_issue then
      if v_new.new_salary is not null then
        insert into public.salary_history (employee_id, effective_month, amount, created_by)
        values (e.id, v_month, v_new.new_salary, auth.uid())
        on conflict (employee_id, effective_month)
          do update set amount = excluded.amount, removed_at = null, removed_by = null;
      end if;
      if v_new.new_designation is not null then
        update public.profiles set designation = v_new.new_designation where id = e.id;
      end if;
      update public.appraisals set status = 'issued', issued_by = auth.uid(), issued_at = now() where id = v_new.id;
      insert into public.appraisal_events (appraisal_id, employee_id, cycle_month, action, source, details, created_by)
      values (v_new.id, e.id, v_month, 'issued', p_source,
              jsonb_build_object('current_salary', v_cur, 'increment_pct', v_new.increment_pct, 'new_salary', v_new.new_salary,
                                 'new_designation', v_new.new_designation), auth.uid());
      perform public._fin_log('emd', e.id, v_month,
        'Appraisal issued for ' || to_char(v_month, 'Mon YYYY')
          || case when v_new.new_salary is not null then ' — salary ' || coalesce(to_char(v_cur, 'FM99,99,99,999'), '—') || ' → ' || to_char(v_new.new_salary, 'FM99,99,99,999') else '' end
          || case when v_new.new_designation is not null then ' — promoted to ' || v_new.new_designation else '' end,
        v_new.new_salary, jsonb_build_object('increment_pct', v_new.increment_pct, 'from_designation', e.designation, 'to_designation', v_new.new_designation));
      v_issued := v_issued + 1;
    end if;
  end loop;
  return jsonb_build_object('saved', v_saved, 'issued', v_issued, 'skipped_issued', v_skipped);
end;
$$;

-- Remove a saved (not issued) appraisal — kept in the table with removed_at, like everything else
create or replace function public.admin_remove_appraisal(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare a public.appraisals;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into a from public.appraisals where id = p_id and removed_at is null;
  if a.id is null then raise exception 'Appraisal not found'; end if;
  if a.status = 'issued' then raise exception 'An issued appraisal cannot be removed — change the salary in EMD instead'; end if;
  if a.employee_id = auth.uid() then raise exception 'You cannot change your own appraisal'; end if;
  insert into public.appraisal_events (appraisal_id, employee_id, cycle_month, action, source, details, created_by)
  values (null, a.employee_id, a.cycle_month, 'changed', 'manual', jsonb_build_object('removed', true, 'new_salary', a.new_salary,
          'increment_pct', a.increment_pct, 'new_designation', a.new_designation), auth.uid());
  update public.appraisals set removed_at = now(), removed_by = auth.uid() where id = p_id;
end;
$$;

-- The employee's own appraisals (saved = shared with them, issued = final)
create or replace function public.my_appraisals()
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public._i_have_left() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'cycle_month', a.cycle_month, 'current_salary', a.current_salary, 'increment_pct', a.increment_pct,
           'new_salary', a.new_salary, 'current_designation', a.current_designation, 'new_designation', a.new_designation,
           'rating', a.rating, 'review', a.review, 'status', a.status, 'updated_at', a.updated_at, 'issued_at', a.issued_at)
         order by a.cycle_month desc), '[]'::jsonb) end
    from public.appraisals a where a.employee_id = auth.uid() and a.removed_at is null;
$$;

-- ---------------------------------------------------------------------
-- Anonymous feedback — no employee id, no user id, no exact time stored
-- ---------------------------------------------------------------------
create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  category    text not null default 'General',
  message     text not null,
  created_on  date not null default ((now() at time zone 'Asia/Kolkata')::date),
  status      text not null default 'new' check (status in ('new', 'read')),
  admin_note  text
);
create index if not exists feedback_created_idx on public.feedback (created_on desc);
alter table public.feedback enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'feedback' and policyname = 'feedback_admin_select') then
    create policy feedback_admin_select on public.feedback for select to authenticated using ((select public.is_admin()));
  end if;
end $$;
revoke all on public.feedback from anon;
grant select on public.feedback to authenticated;

create or replace function public.my_submit_feedback(p_category text, p_message text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'active') or public._i_have_left() then
    raise exception 'Your account is not active';
  end if;
  if length(trim(coalesce(p_message, ''))) < 5 then raise exception 'Write your feedback first'; end if;
  if length(p_message) > 4000 then raise exception 'Keep the feedback under 4000 characters'; end if;
  insert into public.feedback (category, message)
  values (coalesce(nullif(left(trim(p_category), 40), ''), 'General'), trim(p_message));
end;
$$;

create or replace function public.admin_mark_feedback(p_id uuid, p_read boolean)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.feedback set status = case when p_read then 'read' else 'new' end where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function public._leave_days(date, date) from public, anon, authenticated;
revoke execute on function public._new_leave_request(uuid, date, date, text, text) from public, anon, authenticated;
revoke execute on function public.my_apply_leave(date, date, text) from public, anon;
revoke execute on function public.my_withdraw_leave(uuid) from public, anon;
revoke execute on function public.admin_add_leave_request(uuid, date, date, text) from public, anon;
revoke execute on function public.admin_decide_leave(uuid, boolean, text) from public, anon;
revoke execute on function public.admin_cancel_leave(uuid, text) from public, anon;
revoke execute on function public.admin_save_job_role(uuid, text, text) from public, anon;
revoke execute on function public.admin_remove_job_role(uuid) from public, anon;
revoke execute on function public.admin_set_job_role(uuid, uuid, text) from public, anon;
revoke execute on function public.my_role() from public, anon;
revoke execute on function public.admin_save_appraisals(date, jsonb, boolean, text) from public, anon;
revoke execute on function public.admin_remove_appraisal(uuid) from public, anon;
revoke execute on function public.my_appraisals() from public, anon;
revoke execute on function public.my_submit_feedback(text, text) from public, anon;
revoke execute on function public.admin_mark_feedback(uuid, boolean) from public, anon;
grant execute on function public.my_apply_leave(date, date, text) to authenticated;
grant execute on function public.my_withdraw_leave(uuid) to authenticated;
grant execute on function public.admin_add_leave_request(uuid, date, date, text) to authenticated;
grant execute on function public.admin_decide_leave(uuid, boolean, text) to authenticated;
grant execute on function public.admin_cancel_leave(uuid, text) to authenticated;
grant execute on function public.admin_save_job_role(uuid, text, text) to authenticated;
grant execute on function public.admin_remove_job_role(uuid) to authenticated;
grant execute on function public.admin_set_job_role(uuid, uuid, text) to authenticated;
grant execute on function public.my_role() to authenticated;
grant execute on function public.admin_save_appraisals(date, jsonb, boolean, text) to authenticated;
grant execute on function public.admin_remove_appraisal(uuid) to authenticated;
grant execute on function public.my_appraisals() to authenticated;
grant execute on function public.my_submit_feedback(text, text) to authenticated;
grant execute on function public.admin_mark_feedback(uuid, boolean) to authenticated;
