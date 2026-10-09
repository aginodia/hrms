-- =====================================================================
-- Altius HRMS — query auto-resolve, no queries / WFH after leaving,
-- "updated" markers for the employee portal
--
--  * admin_push_payroll: open queries from an earlier upload of the same
--    month move to the new upload; a query whose day was changed before the
--    push is resolved automatically (no need to press Resolved).
--  * Employees in Resigned & Terminated (or after F&F) can't raise salary
--    queries or add WFH.
--  * my_updates(): when each portal section last changed (published pay,
--    answered queries, WFH decisions, holidays, profile change requests,
--    salary), plus whether the person has left — for the "Updated" markers.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create or replace function public._i_have_left()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles
                  where id = auth.uid() and (employment_status in ('resigned', 'terminated') or fnf_completed_at is not null));
$$;

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
  -- Open queries from an earlier upload of the same month move to this one
  update public.payroll_queries q set run_id = p_run
    from public.payroll_runs o
   where o.id = q.run_id and o.month = r.month and o.id <> p_run and q.status = 'open'
     and not exists (select 1 from public.payroll_queries q2 where q2.run_id = p_run and q2.employee_id = q.employee_id
                       and q2.work_date = q.work_date and q2.status = 'open');
  -- A query whose day was changed before this push is resolved automatically
  update public.payroll_queries q
     set status = 'resolved', decided_by = auth.uid(), decided_at = now(),
         admin_note = coalesce(q.admin_note, 'Resolved automatically — the day is now ' ||
           case d ->> 'status' when 'F' then 'a full day' when 'HD' then 'a half day' when 'L' then 'a leave'
                when 'WFH' then 'WFH (full day)' when 'H' then 'a holiday' else d ->> 'status' end)
    from public.payroll_results x, jsonb_array_elements(x.days) d
   where q.run_id = p_run and q.status = 'open' and x.run_id = p_run and x.employee_id = q.employee_id and x.included
     and d ->> 'date' = q.work_date::text and d ->> 'status' <> q.current_status;
  perform public._fin_log('payroll', null, r.month,
    case when r.pushed_at is null then 'Salary sheet pushed to employees' else 'Salary sheet pushed again' end, null, jsonb_build_object('employees', n));
  return n;
end;
$$;

create or replace function public.my_raise_query(p_run uuid, p_date date, p_requested text, p_note text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare r public.payroll_runs; x public.payroll_results; v_status text; v_id uuid;
begin
  if not coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true) then
    raise exception 'Pay details are switched off';
  end if;
  if public._i_have_left() then raise exception 'Queries are not available after you have left'; end if;
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

create or replace function public.my_add_wfh(p_dates date[], p_note text default null)
returns integer language plpgsql security definer set search_path = public
as $$
declare d date; n integer := 0;
        v_month_start date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
begin
  if public.my_status() <> 'active' then raise exception 'Your account is not active'; end if;
  if public._i_have_left() then raise exception 'WFH is not available after you have left'; end if;
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

create or replace function public.my_payslips()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see_pay boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true);
begin
  if not see_pay then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'run_id', r.id, 'month', r.month, 'pushed_at', r.pushed_at, 'last_pushed_at', r.last_pushed_at,
      'query_until', r.pushed_at + interval '12 hours',
      'can_ask', (now() <= r.pushed_at + interval '12 hours') and not public._i_have_left(),
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

create or replace function public.my_updates()
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'left', public._i_have_left(),
    'pay', greatest(
       (select max(coalesce(r.last_pushed_at, r.pushed_at)) from public.payroll_results x join public.payroll_runs r on r.id = x.run_id
         where x.employee_id = auth.uid() and x.included and r.superseded_at is null and r.pushed_at is not null),
       (select max(q.decided_at) from public.payroll_queries q where q.employee_id = auth.uid() and q.decided_by is distinct from auth.uid()),
       (select max(b.created_at) from public.bonus_payments b where b.employee_id = auth.uid() and b.removed_at is null),
       (select max(v.created_at) from public.variable_payouts v where v.employee_id = auth.uid() and v.removed_at is null)),
    'wfh', greatest(
       (select max(w.decided_at) from public.wfh_days w where w.employee_id = auth.uid() and w.decided_by is distinct from auth.uid()),
       (select max(w.created_at) from public.wfh_days w where w.employee_id = auth.uid() and w.added_by is distinct from auth.uid())),
    'calendar', (select max(greatest(c.created_at, coalesce(c.removed_at, c.created_at))) from public.calendar_days c),
    'profile', greatest(
       (select max(c.decided_at) from public.change_requests c where c.employee_id = auth.uid()),
       (select max(s.created_at) from public.salary_history s where s.employee_id = auth.uid())),
    'kyc_status', (select kyc_status from public.profiles where id = auth.uid()));
$$;

revoke execute on function public._i_have_left() from public, anon;
revoke execute on function public.my_updates() from public, anon;
grant execute on function public._i_have_left() to authenticated;
grant execute on function public.my_updates() to authenticated;
