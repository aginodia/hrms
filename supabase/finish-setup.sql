-- =====================================================================
--  Altius HRMS — finish setup (run once in Supabase → SQL Editor → Run)
--
--  The rest of the schema is already applied to project bejhmbvwaexpafhkseod.
--  These two functions contain DELETE statements, which the Supabase
--  connector holds back for manual confirmation, so they need to be run
--  by hand. Until then, "Reject" in Access Control and "Save" on an
--  employee's detail page will show an error.
--  Safe to run more than once.
-- =====================================================================

-- Admin → Access Control → Reject: cancels the sign-up entirely
create or replace function public.admin_reject_signup(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if not exists (select 1 from public.profiles where id = p_user and status = 'pending') then
    raise exception 'This request is no longer pending';
  end if;
  delete from auth.users where id = p_user;   -- cascades to profiles
end;
$$;

-- Admin → EMD → Detailed info → Save
-- Saves the editable fields and replaces the salary history in one
-- transaction. p_salaries: [{"month": "2026-05-01", "amount": 20000}, ...]
create or replace function public.admin_save_employee(
  p_user          uuid,
  p_employee_code text,
  p_designation   text,
  p_manager       uuid,
  p_salaries      jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_months date[];
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_manager = p_user then raise exception 'An employee cannot report to themselves'; end if;
  if jsonb_typeof(coalesce(p_salaries, '[]'::jsonb)) <> 'array' then
    raise exception 'Salaries must be a list';
  end if;

  update public.profiles
     set employee_code        = nullif(trim(p_employee_code), ''),
         designation          = nullif(trim(p_designation), ''),
         reporting_manager_id = p_manager
   where id = p_user and status in ('active', 'inactive');
  if not found then raise exception 'Employee not found in master data'; end if;

  select array_agg(date_trunc('month', (s ->> 'month')::date)::date)
    into v_months
    from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s;

  if v_months is not null and cardinality(v_months) <> (select count(distinct m) from unnest(v_months) m) then
    raise exception 'Each month can only have one salary entry';
  end if;

  delete from public.salary_history
   where employee_id = p_user
     and (v_months is null or effective_month <> all (v_months));

  insert into public.salary_history (employee_id, effective_month, amount, created_by)
  select p_user, date_trunc('month', (s ->> 'month')::date)::date, (s ->> 'amount')::numeric, auth.uid()
    from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s
  on conflict (employee_id, effective_month) do update set amount = excluded.amount;
end;
$$;

revoke execute on function public.admin_reject_signup(uuid) from public, anon;
revoke execute on function public.admin_save_employee(uuid, text, text, uuid, jsonb) from public, anon;
grant execute on function public.admin_reject_signup(uuid) to authenticated;
grant execute on function public.admin_save_employee(uuid, text, text, uuid, jsonb) to authenticated;
