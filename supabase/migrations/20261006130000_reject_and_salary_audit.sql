-- =====================================================================
--  Altius HRMS — rejection and salary audit trail
--
--  * Reject (a sign-up, someone awaiting KYC, or a submitted KYC) cancels
--    access but keeps the record: status becomes 'inactive' with
--    rejected_at / rejected_by / rejection_reason set. Admin can restore.
--  * Removing a salary revision marks it removed_at instead of deleting it,
--    so salary changes keep an audit trail. Removed rows are hidden.
--  Nothing in the HRMS hard-deletes data.
-- =====================================================================

alter table public.profiles
  add column if not exists rejected_at      timestamptz,
  add column if not exists rejected_by      uuid references public.profiles (id) on delete set null,
  add column if not exists rejection_reason text;

alter table public.salary_history
  add column if not exists removed_at timestamptz,
  add column if not exists removed_by uuid references public.profiles (id) on delete set null;

alter policy salary_select_own on public.salary_history
  using (employee_id = auth.uid() and removed_at is null
         and public.my_status() = 'active' and public.team_can_see('salary'));

-- Admin → Access Control → Reject (sign-up, awaiting KYC, or submitted KYC)
create or replace function public.admin_reject(p_user uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot reject your own account'; end if;
  update public.profiles
     set status = 'inactive', rejected_at = now(), rejected_by = auth.uid(),
         rejection_reason = nullif(trim(p_reason), '')
   where id = p_user and status in ('pending', 'kyc_pending', 'kyc_submitted');
  if not found then raise exception 'This request can no longer be rejected'; end if;
end;
$$;

-- Admin → Access Control → Rejected → Restore (back to Signup Requests)
create or replace function public.admin_restore_request(p_user uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.profiles
     set status = 'pending', rejected_at = null, rejected_by = null, rejection_reason = null,
         access_granted_at = null, access_granted_by = null, kyc_remarks = null
   where id = p_user and status = 'inactive' and rejected_at is not null;
  if not found then raise exception 'This request is not in the rejected list'; end if;
end;
$$;

-- Admin → EMD → Detailed info → Save (EID, designation, manager, salary rows)
-- p_salaries: [{"month": "2026-05-01", "amount": 20000}, ...]
create or replace function public.admin_save_employee(
  p_user uuid, p_employee_code text, p_designation text, p_manager uuid, p_salaries jsonb
)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_months date[];
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_manager = p_user then raise exception 'An employee cannot report to themselves'; end if;
  if jsonb_typeof(coalesce(p_salaries, '[]'::jsonb)) <> 'array' then
    raise exception 'Salaries must be a list';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s
              where coalesce((s ->> 'amount')::numeric, 0) <= 0 or (s ->> 'month') is null) then
    raise exception 'Every salary entry needs a month and an amount above zero';
  end if;

  update public.profiles
     set employee_code        = nullif(trim(p_employee_code), ''),
         designation          = nullif(trim(p_designation), ''),
         reporting_manager_id = p_manager
   where id = p_user and status = 'active';
  if not found then raise exception 'Employee not found in master data'; end if;

  select array_agg(date_trunc('month', (s ->> 'month')::date)::date)
    into v_months
    from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s;

  if v_months is not null and cardinality(v_months) <> (select count(distinct m) from unnest(v_months) m) then
    raise exception 'Each month can only have one salary entry';
  end if;

  update public.salary_history
     set removed_at = now(), removed_by = auth.uid()
   where employee_id = p_user and removed_at is null
     and (v_months is null or effective_month <> all (v_months));

  insert into public.salary_history (employee_id, effective_month, amount, created_by)
  select p_user, date_trunc('month', (s ->> 'month')::date)::date, (s ->> 'amount')::numeric, auth.uid()
    from jsonb_array_elements(coalesce(p_salaries, '[]'::jsonb)) s
  on conflict (employee_id, effective_month)
    do update set amount = excluded.amount, removed_at = null, removed_by = null;
end;
$$;

-- Approval: a starting salary for a previously removed month is restored.
create or replace function public.admin_approve_kyc(
  p_user uuid, p_doj date, p_employee_code text default null, p_designation text default null,
  p_manager uuid default null, p_salary_month date default null, p_salary numeric default null
)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_doj is null then raise exception 'Date of joining is required'; end if;
  if p_manager = p_user then raise exception 'An employee cannot report to themselves'; end if;

  update public.profiles
     set status               = 'active',
         date_of_joining      = p_doj,
         employee_code        = nullif(trim(p_employee_code), ''),
         designation          = nullif(trim(p_designation), ''),
         reporting_manager_id = p_manager,
         kyc_remarks          = null,
         approved_at          = now(),
         approved_by          = auth.uid()
   where id = p_user and status = 'kyc_submitted';
  if not found then raise exception 'This KYC is no longer awaiting approval'; end if;

  if p_salary is not null and p_salary_month is not null then
    insert into public.salary_history (employee_id, effective_month, amount, created_by)
    values (p_user, date_trunc('month', p_salary_month)::date, p_salary, auth.uid())
    on conflict (employee_id, effective_month)
      do update set amount = excluded.amount, removed_at = null, removed_by = null;
  end if;
end;
$$;

revoke execute on function public.admin_reject(uuid, text) from public, anon;
revoke execute on function public.admin_restore_request(uuid) from public, anon;
revoke execute on function public.admin_save_employee(uuid, text, text, uuid, jsonb) from public, anon;
grant execute on function public.admin_reject(uuid, text) to authenticated;
grant execute on function public.admin_restore_request(uuid) to authenticated;
grant execute on function public.admin_save_employee(uuid, text, text, uuid, jsonb) to authenticated;
