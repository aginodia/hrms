-- =====================================================================
-- Altius HRMS — employees submit their resignation from the portal
--
--  * resignation_requests: submitted by the employee (resignation date =
--    the day they submit, requested last working day, reason). HR accepts
--    it — which puts the employee on notice with the final last working
--    day, exactly like Resignation in EMD — or rejects it with a note. The
--    employee can withdraw it while it is pending.
--  * my_resignation(): the employee's latest request and notice details,
--    for the status tracker. my_exit() also returns it.
--  * admin_set_notice / admin_set_employment_status keep the request in
--    step (HR putting someone on notice accepts their pending request;
--    withdrawing / marking active again withdraws it).
-- Re-runnable. Nothing is removed.
-- =====================================================================

create table if not exists public.resignation_requests (
  id                  uuid primary key default gen_random_uuid(),
  employee_id         uuid not null references public.profiles (id) on delete cascade,
  resignation_date    date not null,
  requested_last_day  date not null,
  reason              text,
  status              text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'withdrawn')),
  last_day            date,
  admin_note          text,
  decided_by          uuid references public.profiles (id) on delete set null,
  decided_at          timestamptz,
  created_at          timestamptz not null default now()
);
create unique index if not exists resignation_requests_pending_uq on public.resignation_requests (employee_id) where status = 'pending';
create index if not exists resignation_requests_emp_idx on public.resignation_requests (employee_id, created_at);
alter table public.resignation_requests enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'resignation_requests' and policyname = 'resignation_requests_select') then
    create policy resignation_requests_select on public.resignation_requests for select to authenticated
      using ((select public.is_admin()) or (employee_id = (select auth.uid()) and not (select public._i_have_left())));
  end if;
end $$;
grant select on public.resignation_requests to authenticated;

create or replace function public.my_submit_resignation(p_last_day date, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare p public.profiles; v_today date := (now() at time zone 'Asia/Kolkata')::date; v_id uuid;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.status <> 'active' then raise exception 'Your account is not active'; end if;
  if p.employment_status <> 'active' or p.fnf_completed_at is not null then raise exception 'You have already left'; end if;
  if p.resignation_date is not null then raise exception 'Your resignation is already accepted — you are on notice'; end if;
  if exists (select 1 from public.resignation_requests where employee_id = p.id and status = 'pending') then
    raise exception 'You have already submitted your resignation — HR is reviewing it';
  end if;
  if p_last_day is null then raise exception 'Pick your last working day'; end if;
  if p_last_day < v_today then raise exception 'The last working day cannot be in the past'; end if;
  if p_last_day > v_today + 180 then raise exception 'The last working day must be within 180 days'; end if;
  insert into public.resignation_requests (employee_id, resignation_date, requested_last_day, reason)
  values (p.id, v_today, p_last_day, nullif(trim(p_reason), '')) returning id into v_id;
  perform public._fin_log('emd', p.id, v_today, 'Resignation submitted by the employee', null,
    jsonb_build_object('requested_last_day', p_last_day, 'reason', nullif(trim(p_reason), '')));
  return v_id;
end;
$$;

create or replace function public.my_withdraw_resignation()
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.resignation_requests set status = 'withdrawn', decided_at = now()
   where employee_id = auth.uid() and status = 'pending';
  if not found then raise exception 'There is no pending resignation to withdraw — contact HR'; end if;
  perform public._fin_log('emd', auth.uid(), current_date, 'Resignation withdrawn by the employee', null, null);
end;
$$;

create or replace function public.my_resignation()
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'profile', (select jsonb_build_object('resignation_date', p.resignation_date, 'exit_date', p.exit_date,
                  'employment_status', p.employment_status, 'date_of_joining', p.date_of_joining, 'fnf_completed_at', p.fnf_completed_at)
                from public.profiles p where p.id = auth.uid()),
    'request', (select to_jsonb(r) - 'decided_by' from public.resignation_requests r
                 where r.employee_id = auth.uid() order by r.created_at desc limit 1));
$$;

create or replace function public.admin_reject_resignation(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.resignation_requests;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Add a note for the employee'; end if;
  update public.resignation_requests set status = 'rejected', admin_note = trim(p_note), decided_by = auth.uid(), decided_at = now()
   where id = p_id and status = 'pending' returning * into r;
  if r.id is null then raise exception 'This resignation is no longer pending'; end if;
  perform public._fin_log('emd', r.employee_id, current_date, 'Resignation not accepted', null, jsonb_build_object('note', trim(p_note)));
end;
$$;

-- Notice period (HR). Putting someone on notice accepts their pending request; withdrawing withdraws it.
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
    update public.resignation_requests set status = 'withdrawn', decided_by = auth.uid(), decided_at = now(),
           admin_note = coalesce(admin_note, 'Withdrawn by HR')
     where employee_id = p_user and status in ('pending', 'accepted');
    perform public._fin_log('emd', p_user, current_date, 'Resignation withdrawn — back to active', null, null);
    return;
  end if;
  if p_last_day is null then raise exception 'Pick the last working day'; end if;
  if p_last_day < p_resign_date then raise exception 'The last working day cannot be before the resignation date'; end if;

  update public.profiles
     set resignation_date = p_resign_date, exit_date = p_last_day, exit_note = nullif(trim(p_note), '')
   where id = p_user;
  update public.resignation_requests set status = 'accepted', last_day = p_last_day, decided_by = auth.uid(), decided_at = now()
   where employee_id = p_user and status = 'pending';
  update public.resignation_requests set last_day = p_last_day
   where employee_id = p_user and status = 'accepted'
     and id = (select id from public.resignation_requests where employee_id = p_user order by created_at desc limit 1);
  perform public._fin_log('emd', p_user, p_resign_date,
    case when v_was is null then 'Resignation received — on notice period' else 'Notice period updated' end, null,
    jsonb_build_object('resignation_date', p_resign_date, 'last_working_day', p_last_day,
                       'notice_days', p_last_day - p_resign_date, 'note', nullif(trim(p_note), '')));
end;
$$;

-- Marking someone Active again also withdraws their resignation request
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
  if p_status = 'active' then
    update public.resignation_requests set status = 'withdrawn', decided_by = auth.uid(), decided_at = now(),
           admin_note = coalesce(admin_note, 'Marked active again by HR')
     where employee_id = p_user and status in ('pending', 'accepted');
  else
    update public.resignation_requests set status = 'accepted', last_day = (select exit_date from public.profiles where id = p_user),
           decided_by = auth.uid(), decided_at = now()
     where employee_id = p_user and status = 'pending';
  end if;
  perform public._fin_log('emd', p_user, coalesce(p_exit_date, current_date),
    case p_status when 'active' then 'Marked active again' when 'resigned' then 'Marked resigned — moved to R&T' else 'Marked terminated — moved to R&T' end,
    null, jsonb_build_object('last_working_day', (select exit_date from public.profiles where id = p_user),
                             'settlement_due', (select exit_date + 60 from public.profiles where id = p_user),
                             'note', nullif(trim(p_note), '')));
end;
$$;

revoke execute on function public.my_submit_resignation(date, text) from public, anon;
revoke execute on function public.my_withdraw_resignation() from public, anon;
revoke execute on function public.my_resignation() from public, anon;
revoke execute on function public.admin_reject_resignation(uuid, text) from public, anon;
grant execute on function public.my_submit_resignation(date, text) to authenticated;
grant execute on function public.my_withdraw_resignation() to authenticated;
grant execute on function public.my_resignation() to authenticated;
grant execute on function public.admin_reject_resignation(uuid, text) to authenticated;
