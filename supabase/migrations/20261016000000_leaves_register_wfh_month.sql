-- =====================================================================
-- Altius HRMS — Leaves register, WFH back-dating within the month
--
--  * leave_records: admins record leaves day by day against an employee
--    (Employee ID + name), full day or half day. Payroll picks them up:
--    a full-day leave makes the day L, a half-day leave makes it HD
--    (the admin can still change the day in day-wise attendance).
--  * my_add_wfh: employees can add WFH for past dates only within the
--    current month (India time), e.g. a week back — not for an earlier
--    month. Published months stay locked as before.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create table if not exists public.leave_records (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.profiles (id) on delete cascade,
  leave_date   date not null,
  kind         text not null default 'full' check (kind in ('full', 'half')),
  note         text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  removed_at   timestamptz,
  removed_by   uuid references public.profiles (id) on delete set null
);
create unique index if not exists leave_records_uq on public.leave_records (employee_id, leave_date) where removed_at is null;
create index if not exists leave_records_date_idx on public.leave_records (leave_date);

alter table public.leave_records enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'leave_records' and policyname = 'leave_records_select') then
    create policy leave_records_select on public.leave_records for select to authenticated
      using (employee_id = auth.uid() or public.is_admin());
  end if;
end $$;
grant select on public.leave_records to authenticated;

-- Record leave for one employee on one or more dates (Sundays and holidays are skipped).
-- A date that already has a leave is updated to the new type / note.
create or replace function public.admin_add_leaves(p_employee uuid, p_dates date[], p_kind text default 'full', p_note text default null)
returns integer language plpgsql security definer set search_path = public
as $$
declare d date; n integer := 0; v_name text;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_kind not in ('full', 'half') then raise exception 'Pick full day or half day'; end if;
  if p_dates is null or cardinality(p_dates) = 0 then raise exception 'Pick at least one date'; end if;
  select full_name into v_name from public.profiles where id = p_employee and status = 'active';
  if v_name is null then raise exception 'Pick an active employee'; end if;
  foreach d in array p_dates loop
    continue when extract(isodow from d) = 7;
    continue when exists (select 1 from public.calendar_days c where c.day = d and c.kind = 'holiday' and c.removed_at is null);
    update public.leave_records set kind = p_kind, note = nullif(trim(p_note), '')
     where employee_id = p_employee and leave_date = d and removed_at is null;
    if not found then
      insert into public.leave_records (employee_id, leave_date, kind, note, created_by)
      values (p_employee, d, p_kind, nullif(trim(p_note), ''), auth.uid());
    end if;
    n := n + 1;
    perform public._fin_log('payroll', p_employee, d,
      case p_kind when 'half' then 'Half-day leave recorded: ' else 'Leave recorded: ' end || to_char(d, 'DD-MM-YYYY'), null,
      case when nullif(trim(p_note), '') is null then null else jsonb_build_object('note', trim(p_note)) end);
  end loop;
  return n;
end;
$$;

create or replace function public.admin_remove_leave(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare l public.leave_records;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.leave_records set removed_at = now(), removed_by = auth.uid()
   where id = p_id and removed_at is null returning * into l;
  if l.id is null then raise exception 'This leave is already removed'; end if;
  perform public._fin_log('payroll', l.employee_id, l.leave_date, 'Leave removed: ' || to_char(l.leave_date, 'DD-MM-YYYY'), null, null);
end;
$$;

-- WFH: back-dated only within the current month
create or replace function public.my_add_wfh(p_dates date[], p_note text default null)
returns integer language plpgsql security definer set search_path = public
as $$
declare d date; n integer := 0;
        v_month_start date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
begin
  if public.my_status() <> 'active' then raise exception 'Your account is not active'; end if;
  if p_dates is null or cardinality(p_dates) = 0 then raise exception 'Pick at least one date'; end if;
  foreach d in array p_dates loop
    if d < v_month_start then
      raise exception '% is in an earlier month — WFH can be back-dated only within this month', to_char(d, 'DD-MM-YYYY');
    end if;
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

revoke execute on function public.admin_add_leaves(uuid, date[], text, text) from public, anon;
revoke execute on function public.admin_remove_leave(uuid) from public, anon;
grant execute on function public.admin_add_leaves(uuid, date[], text, text) to authenticated;
grant execute on function public.admin_remove_leave(uuid) to authenticated;
