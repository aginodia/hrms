-- =====================================================================
-- Altius HRMS — ESOP 2026
--
--  * esop_allocations: one uploaded allocation sheet (e.g. "Allocation date
--    2 April 2026"), with its exercise period. Re-uploading the same
--    allocation date replaces the earlier upload (kept, marked removed).
--  * esop_grants: options per member and grant type (Performance,
--    Time-weighted, Historical…) with the vesting rule from the sheet.
--  * esop_vesting: the allocation schedule — options vesting on each date.
--  * esop_exercises: options an employee has exercised.
--  * Pool size is in app_settings 'esop' (default 2000 options).
--  Status (vested / unvested / returned to pool / lapsed) is worked out from
--  these and the employee's exit dates, following the scheme: unvested
--  options are cancelled on the resignation / termination notice date and
--  go back to the pool; vested options can be exercised within 6 months of
--  the last working day (30 days after a termination), then lapse.
--  Employees see only their own rows. The scheme document is not stored.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create table if not exists public.esop_allocations (
  id                uuid primary key default gen_random_uuid(),
  allocation_date   date not null,
  title             text,
  exercise_years    integer check (exercise_years between 1 and 20),
  source_file_name  text,
  uploaded_by       uuid references public.profiles (id) on delete set null,
  uploaded_at       timestamptz not null default now(),
  removed_at        timestamptz,
  removed_by        uuid references public.profiles (id) on delete set null
);
create unique index if not exists esop_allocations_active_uq on public.esop_allocations (allocation_date) where removed_at is null;

create table if not exists public.esop_grants (
  id             uuid primary key default gen_random_uuid(),
  allocation_id  uuid not null references public.esop_allocations (id) on delete cascade,
  employee_id    uuid references public.profiles (id) on delete set null,
  member_name    text not null,
  grant_type     text not null,
  options        integer not null check (options >= 0),
  vesting_note   text
);
create index if not exists esop_grants_alloc_idx on public.esop_grants (allocation_id);
create index if not exists esop_grants_emp_idx on public.esop_grants (employee_id);

create table if not exists public.esop_vesting (
  id             uuid primary key default gen_random_uuid(),
  allocation_id  uuid not null references public.esop_allocations (id) on delete cascade,
  employee_id    uuid references public.profiles (id) on delete set null,
  member_name    text not null,
  vest_date      date not null,
  label          text,
  options        integer not null check (options >= 0)
);
create index if not exists esop_vesting_alloc_idx on public.esop_vesting (allocation_id);
create index if not exists esop_vesting_emp_idx on public.esop_vesting (employee_id);

create table if not exists public.esop_exercises (
  id             uuid primary key default gen_random_uuid(),
  employee_id    uuid not null references public.profiles (id) on delete cascade,
  exercise_date  date not null,
  options        integer not null check (options > 0),
  price          numeric(14, 2),
  note           text,
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  removed_at     timestamptz,
  removed_by     uuid references public.profiles (id) on delete set null
);
create index if not exists esop_exercises_emp_idx on public.esop_exercises (employee_id);

alter table public.esop_allocations enable row level security;
alter table public.esop_grants      enable row level security;
alter table public.esop_vesting     enable row level security;
alter table public.esop_exercises   enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'esop_allocations' and policyname = 'esop_allocations_select') then
    create policy esop_allocations_select on public.esop_allocations for select to authenticated
      using (public.is_admin() or (removed_at is null and exists (select 1 from public.esop_grants g where g.allocation_id = esop_allocations.id and g.employee_id = auth.uid())));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'esop_grants' and policyname = 'esop_grants_select') then
    create policy esop_grants_select on public.esop_grants for select to authenticated using (public.is_admin() or employee_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'esop_vesting' and policyname = 'esop_vesting_select') then
    create policy esop_vesting_select on public.esop_vesting for select to authenticated using (public.is_admin() or employee_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'esop_exercises' and policyname = 'esop_exercises_select') then
    create policy esop_exercises_select on public.esop_exercises for select to authenticated using (public.is_admin() or employee_id = auth.uid());
  end if;
end $$;
grant select on public.esop_allocations, public.esop_grants, public.esop_vesting, public.esop_exercises to authenticated;

insert into public.app_settings (key, value)
values ('esop', '{"pool": 2000, "scheme": "Altius Investech Employee Stock Option Plan – 2026 (ESOP 2026)"}'::jsonb)
on conflict (key) do nothing;

-- Upload an allocation sheet.
-- p_rows: [{"member_name", "employee_id"|null,
--           "grants": [{"type", "options", "note"}], "vesting": [{"date", "label", "options"}]}]
create or replace function public.admin_import_esop(p_allocation_date date, p_title text, p_exercise_years integer,
                                                    p_file_name text, p_rows jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_old uuid; r jsonb; g jsonb; v jsonb; v_emp uuid; n_members int := 0; n_opts int := 0;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_allocation_date is null then raise exception 'The allocation date is missing'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No members in the sheet'; end if;

  select id into v_old from public.esop_allocations where allocation_date = p_allocation_date and removed_at is null;
  if v_old is not null then
    update public.esop_allocations set removed_at = now(), removed_by = auth.uid() where id = v_old;
  end if;

  insert into public.esop_allocations (allocation_date, title, exercise_years, source_file_name, uploaded_by)
  values (p_allocation_date, nullif(trim(p_title), ''), p_exercise_years, nullif(trim(p_file_name), ''), auth.uid())
  returning id into v_id;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_emp := nullif(r ->> 'employee_id', '')::uuid;
    if v_emp is not null and not exists (select 1 from public.profiles where id = v_emp) then v_emp := null; end if;
    n_members := n_members + 1;
    for g in select * from jsonb_array_elements(coalesce(r -> 'grants', '[]'::jsonb)) loop
      continue when coalesce((g ->> 'options')::int, 0) <= 0;
      insert into public.esop_grants (allocation_id, employee_id, member_name, grant_type, options, vesting_note)
      values (v_id, v_emp, trim(r ->> 'member_name'), g ->> 'type', (g ->> 'options')::int, nullif(trim(g ->> 'note'), ''));
      n_opts := n_opts + (g ->> 'options')::int;
    end loop;
    for v in select * from jsonb_array_elements(coalesce(r -> 'vesting', '[]'::jsonb)) loop
      continue when coalesce((v ->> 'options')::int, 0) <= 0;
      insert into public.esop_vesting (allocation_id, employee_id, member_name, vest_date, label, options)
      values (v_id, v_emp, trim(r ->> 'member_name'), (v ->> 'date')::date, nullif(v ->> 'label', ''), (v ->> 'options')::int);
    end loop;
  end loop;

  perform public._fin_log('emd', null, p_allocation_date,
    'ESOP allocation uploaded (' || to_char(p_allocation_date, 'DD-MM-YYYY') || '): ' || n_opts || ' options to ' || n_members || ' members', null,
    jsonb_build_object('allocation_id', v_id, 'replaced', v_old, 'file', p_file_name));
  return v_id;
end;
$$;

-- Link a sheet member to an employee (or unlink with null)
create or replace function public.admin_map_esop_member(p_allocation uuid, p_member_name text, p_employee uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.esop_grants set employee_id = p_employee where allocation_id = p_allocation and member_name = p_member_name;
  update public.esop_vesting set employee_id = p_employee where allocation_id = p_allocation and member_name = p_member_name;
end;
$$;

create or replace function public.admin_remove_esop_allocation(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.esop_allocations set removed_at = now(), removed_by = auth.uid() where id = p_id and removed_at is null;
  if not found then raise exception 'This allocation is already removed'; end if;
end;
$$;

create or replace function public.admin_set_esop_pool(p_pool integer)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_pool is null or p_pool < 1 then raise exception 'Enter the pool size'; end if;
  insert into public.app_settings (key, value) values ('esop', jsonb_build_object('pool', p_pool))
  on conflict (key) do update set value = coalesce(app_settings.value, '{}'::jsonb) || jsonb_build_object('pool', p_pool);
end;
$$;

-- Record an exercise: no more than the options vested by that date, less what is already exercised
create or replace function public.admin_add_esop_exercise(p_employee uuid, p_date date, p_options integer, p_price numeric default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_vested int; v_done int; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_options is null or p_options < 1 then raise exception 'Enter the number of options'; end if;
  select coalesce(sum(v.options), 0) into v_vested
    from public.esop_vesting v join public.esop_allocations a on a.id = v.allocation_id and a.removed_at is null
   where v.employee_id = p_employee and v.vest_date <= p_date;
  select coalesce(sum(options), 0) into v_done from public.esop_exercises where employee_id = p_employee and removed_at is null;
  if p_options > v_vested - v_done then
    raise exception 'Only % vested option(s) are available to exercise on %', greatest(v_vested - v_done, 0), to_char(p_date, 'DD-MM-YYYY');
  end if;
  insert into public.esop_exercises (employee_id, exercise_date, options, price, note, created_by)
  values (p_employee, p_date, p_options, p_price, nullif(trim(p_note), ''), auth.uid()) returning id into v_id;
  perform public._fin_log('emd', p_employee, p_date, 'ESOP exercised: ' || p_options || ' option(s)', null, jsonb_build_object('price', p_price));
  return v_id;
end;
$$;

create or replace function public.admin_remove_esop_exercise(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare e public.esop_exercises;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.esop_exercises set removed_at = now(), removed_by = auth.uid() where id = p_id and removed_at is null returning * into e;
  if e.id is null then raise exception 'Already removed'; end if;
  perform public._fin_log('emd', e.employee_id, e.exercise_date, 'ESOP exercise removed: ' || e.options || ' option(s)', null, null);
end;
$$;

-- The employee's own ESOPs (respecting Team Access → ESOPs)
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
                     'exercise_years', a.exercise_years) order by a.allocation_date)
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

revoke execute on function public.admin_import_esop(date, text, integer, text, jsonb) from public, anon;
revoke execute on function public.admin_map_esop_member(uuid, text, uuid) from public, anon;
revoke execute on function public.admin_remove_esop_allocation(uuid) from public, anon;
revoke execute on function public.admin_set_esop_pool(integer) from public, anon;
revoke execute on function public.admin_add_esop_exercise(uuid, date, integer, numeric, text) from public, anon;
revoke execute on function public.admin_remove_esop_exercise(uuid) from public, anon;
revoke execute on function public.my_esops() from public, anon;
grant execute on function public.admin_import_esop(date, text, integer, text, jsonb) to authenticated;
grant execute on function public.admin_map_esop_member(uuid, text, uuid) to authenticated;
grant execute on function public.admin_remove_esop_allocation(uuid) to authenticated;
grant execute on function public.admin_set_esop_pool(integer) to authenticated;
grant execute on function public.admin_add_esop_exercise(uuid, date, integer, numeric, text) to authenticated;
grant execute on function public.admin_remove_esop_exercise(uuid) to authenticated;
grant execute on function public.my_esops() to authenticated;
