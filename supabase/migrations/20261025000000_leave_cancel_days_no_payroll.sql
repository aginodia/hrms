-- =====================================================================
-- Altius HRMS — leaves: cancel single days, no link to the salary sheet
--
--  * Leaves are tracked and approved here only — they no longer write
--    leave days into payroll. Days already written by approved leaves are
--    taken back out of payroll (marked removed, not deleted).
--  * cancel_leave_days(): the employee (from today on) or an admin can
--    cancel one, several or all remaining days of a pending or approved
--    leave — the last day, a day in between, or the whole leave.
--    leave_requests.cancelled_days holds them, days = what is left, and
--    cancellations is the history (who: employee / admin, when, note).
--    A leave with nothing left becomes withdrawn (pending) or cancelled.
--  * A new leave only clashes with days that are still on leave.
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.leave_requests add column if not exists cancelled_days date[] not null default '{}';
alter table public.leave_requests add column if not exists cancellations jsonb not null default '[]'::jsonb;

-- Leave days already sent to payroll by approved leaves come out again
update public.leave_records set removed_at = now()
 where leave_request_id is not null and removed_at is null;

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
  select * into c from public.leave_requests r
   where r.employee_id = p_employee and r.status in ('pending', 'approved') and r.from_date <= p_to and r.to_date >= p_from
     and exists (select 1 from unnest(v_days) d where d between r.from_date and r.to_date and not (d = any (r.cancelled_days)))
   order by r.from_date limit 1;
  if c.id is not null then
    raise exception 'This overlaps a leave that is already % (% to %)', c.status, to_char(c.from_date, 'DD-MM-YYYY'), to_char(c.to_date, 'DD-MM-YYYY');
  end if;
  insert into public.leave_requests (employee_id, from_date, to_date, days, reason, source, created_by)
  values (p_employee, p_from, p_to, cardinality(v_days), trim(p_reason), p_source, auth.uid()) returning id into v_id;
  return v_id;
end;
$$;

-- Approve / reject — tracking only, nothing goes to payroll
create or replace function public.admin_decide_leave(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.leave_requests;
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
end;
$$;

-- Cancel one, several or all remaining days of a leave
create or replace function public.cancel_leave_days(p_id uuid, p_days date[], p_note text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  r public.leave_requests;
  v_admin boolean := public.is_admin();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_all date[]; v_left date[]; v_pick date[]; d date;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'Leave not found'; end if;
  if not v_admin and r.employee_id <> auth.uid() then raise exception 'Leave not found'; end if;
  if not v_admin and public._i_have_left() then raise exception 'You have already left'; end if;
  if r.status not in ('pending', 'approved') then raise exception 'This leave is already %', r.status; end if;
  if p_days is null or cardinality(p_days) = 0 then raise exception 'Pick the day(s) to cancel'; end if;
  if v_admin and r.employee_id <> auth.uid() and coalesce(trim(p_note), '') = '' then raise exception 'Add a note for the employee'; end if;

  v_all := public._leave_days(r.from_date, r.to_date);
  select coalesce(array_agg(x order by x), '{}') into v_left from unnest(v_all) x where not (x = any (r.cancelled_days));
  select coalesce(array_agg(distinct x order by x), '{}') into v_pick from unnest(p_days) x;
  foreach d in array v_pick loop
    if not (d = any (v_left)) then raise exception '% is not a leave day you can cancel', to_char(d, 'DD-MM-YYYY'); end if;
    if not v_admin and d < v_today then raise exception '% has already passed — ask HR to cancel it', to_char(d, 'DD-MM-YYYY'); end if;
  end loop;

  select coalesce(array_agg(x order by x), '{}') into v_left from unnest(v_left) x where not (x = any (v_pick));
  update public.leave_requests
     set cancelled_days = (select array_agg(x order by x) from unnest(r.cancelled_days || v_pick) x),
         days = cardinality(v_left),
         cancellations = cancellations || jsonb_build_array(jsonb_build_object(
           'days', to_jsonb(v_pick), 'by', case when r.employee_id = auth.uid() then 'employee' else 'admin' end,
           'at', now(), 'note', nullif(trim(p_note), ''))),
         status = case when cardinality(v_left) > 0 then status when status = 'pending' then 'withdrawn' else 'cancelled' end,
         admin_note = case when cardinality(v_left) = 0 and r.employee_id <> auth.uid() then coalesce(nullif(trim(p_note), ''), admin_note) else admin_note end,
         decided_at = case when cardinality(v_left) = 0 then now() else decided_at end,
         decided_by = case when cardinality(v_left) = 0 and r.employee_id <> auth.uid() then auth.uid() else decided_by end
   where id = p_id;
  return jsonb_build_object('cancelled', cardinality(v_pick), 'left', cardinality(v_left));
end;
$$;

-- Whole-leave cancel by HR (kept for compatibility) — tracking only
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
end;
$$;

revoke execute on function public.cancel_leave_days(uuid, date[], text) from public, anon;
grant execute on function public.cancel_leave_days(uuid, date[], text) to authenticated;
