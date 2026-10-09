-- =====================================================================
-- Altius HRMS — Drive storage, salary slips & grant letters, pay record
--
--  * my_payslips: every published month stays in the employee's pay
--    record; the day-wise sheet is sent only while the 12-hour query
--    window is open (after that it disappears from the portal). Adds the
--    holiday / WFH counts and the details printed on the salary slip.
--  * hr_documents: salary slips and ESOP grant letters made in the HRMS.
--    The PDF itself is kept in Google Drive — only its Drive file id and
--    name are stored here.
--  * esop_allocations.exercise_price + admin_set_esop_price: the price
--    printed on the grant letters of an allocation.
--  * app_settings 'drive' (the Drive bridge URL) and 'company' (name,
--    address, signatory for the documents).
--  * admin_set_kyc_paths: points KYC documents at their Drive copies when
--    existing files are moved out of Supabase storage.
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.esop_allocations add column if not exists exercise_price numeric(14, 2);

create table if not exists public.hr_documents (
  id             uuid primary key default gen_random_uuid(),
  employee_id    uuid references public.profiles (id) on delete set null,
  kind           text not null check (kind in ('salary_slip', 'grant_letter')),
  ref            text not null,               -- 'YYYY-MM' for a slip, the allocation id for a grant letter
  title          text,
  drive_file_id  text not null,
  file_name      text,
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  removed_at     timestamptz
);
create unique index if not exists hr_documents_uq on public.hr_documents (employee_id, kind, ref) where removed_at is null;
alter table public.hr_documents enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'hr_documents' and policyname = 'hr_documents_select') then
    create policy hr_documents_select on public.hr_documents for select to authenticated
      using (public.is_admin() or (employee_id = auth.uid() and removed_at is null));
  end if;
end $$;
grant select on public.hr_documents to authenticated;

insert into public.app_settings (key, value) values ('drive', '{"url": ""}'::jsonb) on conflict (key) do nothing;
insert into public.app_settings (key, value)
values ('company', '{"name": "Altius Investech Private Limited", "address": "", "cin": "", "signatory_name": "", "signatory_title": "Director"}'::jsonb)
on conflict (key) do nothing;

-- Record (or replace) a document saved to Drive
create or replace function public.admin_record_document(p_employee uuid, p_kind text, p_ref text, p_title text, p_file_id text, p_file_name text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_file_id), '') = '' then raise exception 'The Drive file is missing'; end if;
  update public.hr_documents set removed_at = now()
   where employee_id is not distinct from p_employee and kind = p_kind and ref = p_ref and removed_at is null;
  insert into public.hr_documents (employee_id, kind, ref, title, drive_file_id, file_name, created_by)
  values (p_employee, p_kind, p_ref, nullif(trim(p_title), ''), trim(p_file_id), nullif(trim(p_file_name), ''), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_set_esop_price(p_allocation uuid, p_price numeric)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_price is not null and p_price < 100 then raise exception 'The exercise price cannot be below the face value of ₹100'; end if;
  update public.esop_allocations set exercise_price = p_price where id = p_allocation and removed_at is null;
  if not found then raise exception 'Allocation not found'; end if;
end;
$$;

-- Point an employee's KYC documents at new paths (used when moving files to Drive).
-- p: {"aadhaar_path": "<employee>/drive/<file id>", ...}
create or replace function public.admin_set_kyc_paths(p_employee uuid, p jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare v_key text; v_prefix text := p_employee::text || '/';
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  for v_key in select jsonb_object_keys(p) loop
    if v_key not in ('aadhaar_path', 'pan_path', 'marksheet_10_path', 'marksheet_12_path', 'graduation_path', 'payslip_path', 'leave_letter_path') then
      raise exception 'Unknown document %', v_key;
    end if;
    if left(p ->> v_key, length(v_prefix)) <> v_prefix then raise exception 'Invalid document path for %', v_key; end if;
  end loop;
  update public.kyc_submissions set
    aadhaar_path      = coalesce(p ->> 'aadhaar_path', aadhaar_path),
    pan_path          = coalesce(p ->> 'pan_path', pan_path),
    marksheet_10_path = coalesce(p ->> 'marksheet_10_path', marksheet_10_path),
    marksheet_12_path = coalesce(p ->> 'marksheet_12_path', marksheet_12_path),
    graduation_path   = coalesce(p ->> 'graduation_path', graduation_path),
    payslip_path      = coalesce(p ->> 'payslip_path', payslip_path),
    leave_letter_path = coalesce(p ->> 'leave_letter_path', leave_letter_path)
  where employee_id = p_employee;
  if not found then raise exception 'No KYC for this employee'; end if;
end;
$$;

-- Pay record: every published month; the day-wise sheet only while queries are open
create or replace function public.my_payslips()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see_pay boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'pay')::boolean, true);
        p public.profiles;
        v_acct text;
begin
  if not see_pay then return '[]'::jsonb; end if;
  select * into p from public.profiles where id = auth.uid();
  select right(bank_account_number, 4) into v_acct from public.kyc_submissions where employee_id = auth.uid();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'run_id', r.id, 'month', r.month, 'pushed_at', r.pushed_at, 'last_pushed_at', r.last_pushed_at,
      'query_until', r.pushed_at + interval '12 hours',
      'sheet_open', now() <= r.pushed_at + interval '12 hours',
      'can_ask', (now() <= r.pushed_at + interval '12 hours') and not public._i_have_left(),
      'monthly_salary', x.monthly_salary, 'daily_salary', x.daily_salary,
      'full', x.post_full, 'half', x.post_half, 'leave', x.post_leave, 'weekly_off', x.post_weekly_off,
      'holidays', (select count(*) from jsonb_array_elements(coalesce(x.days, '[]'::jsonb)) d where d ->> 'status' = 'H'),
      'wfh', (select count(*) from jsonb_array_elements(coalesce(x.days, '[]'::jsonb)) d where d ->> 'status' = 'WFH'),
      'earned', x.payable, 'pt', x.pt, 'net', x.net_payable,
      'days', case when now() <= r.pushed_at + interval '12 hours' then x.days end,
      'employee', jsonb_build_object('full_name', p.full_name, 'employee_code', p.employee_code, 'designation', p.designation,
                                     'date_of_joining', p.date_of_joining, 'bank_last4', v_acct),
      'slip_file', (select d.drive_file_id from public.hr_documents d
                     where d.employee_id = auth.uid() and d.kind = 'salary_slip' and d.ref = to_char(r.month, 'YYYY-MM') and d.removed_at is null),
      'queries', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'date', q.work_date, 'current', q.current_status,
                  'requested', q.requested_status, 'note', q.note, 'status', q.status, 'admin_note', q.admin_note,
                  'created_at', q.created_at, 'decided_at', q.decided_at) order by q.work_date, q.created_at)
                from public.payroll_queries q where q.run_id = r.id and q.employee_id = auth.uid()), '[]'::jsonb)
    ) order by r.month desc)
    from public.payroll_results x join public.payroll_runs r on r.id = x.run_id
   where x.employee_id = auth.uid() and x.included and r.superseded_at is null and r.pushed_at is not null), '[]'::jsonb);
end;
$$;

-- ESOPs for the portal: adds the exercise price and the issued grant letters
create or replace function public.my_esops()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare see boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'esop')::boolean, true);
        p public.profiles;
begin
  if not see then return jsonb_build_object('hidden', true); end if;
  select * into p from public.profiles where id = auth.uid();
  return jsonb_build_object(
    'pool', coalesce(((select value from public.app_settings where key = 'esop') ->> 'pool')::int, 2000),
    'profile', jsonb_build_object('employment_status', p.employment_status, 'resignation_date', p.resignation_date,
                                  'exit_date', p.exit_date, 'fnf_completed_at', p.fnf_completed_at),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'allocation_date', a.allocation_date, 'title', a.title,
                     'exercise_years', a.exercise_years, 'exercise_price', a.exercise_price,
                     'letter_file', (select d.drive_file_id from public.hr_documents d where d.employee_id = auth.uid() and d.kind = 'grant_letter'
                                      and d.ref = a.id::text and d.removed_at is null)) order by a.allocation_date)
                   from public.esop_allocations a where a.removed_at is null
                    and exists (select 1 from public.esop_grants g where g.allocation_id = a.id and g.employee_id = auth.uid())), '[]'::jsonb),
    'grants', coalesce((select jsonb_agg(jsonb_build_object('allocation_id', g.allocation_id, 'type', g.grant_type, 'options', g.options, 'note', g.vesting_note))
               from public.esop_grants g join public.esop_allocations a on a.id = g.allocation_id and a.removed_at is null
              where g.employee_id = auth.uid()), '[]'::jsonb),
    'vesting', coalesce((select jsonb_agg(jsonb_build_object('allocation_id', v.allocation_id, 'date', v.vest_date, 'label', v.label, 'options', v.options) order by v.vest_date)
               from public.esop_vesting v join public.esop_allocations a on a.id = v.allocation_id and a.removed_at is null
              where v.employee_id = auth.uid()), '[]'::jsonb),
    'exercises', coalesce((select jsonb_agg(jsonb_build_object('date', e.exercise_date, 'options', e.options, 'price', e.price, 'note', e.note) order by e.exercise_date)
               from public.esop_exercises e where e.employee_id = auth.uid() and e.removed_at is null), '[]'::jsonb));
end;
$$;

revoke execute on function public.admin_record_document(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.admin_set_esop_price(uuid, numeric) from public, anon;
revoke execute on function public.admin_set_kyc_paths(uuid, jsonb) from public, anon;
grant execute on function public.admin_record_document(uuid, text, text, text, text, text) to authenticated;
grant execute on function public.admin_set_esop_price(uuid, numeric) to authenticated;
grant execute on function public.admin_set_kyc_paths(uuid, jsonb) to authenticated;
