-- =====================================================================
-- Altius HRMS — Payroll mapping: EmpCodes of people who have left
--
-- The first attendance sheets still carry people who left before the
-- HRMS existed. In Payroll → Mapping they can be marked "Left / resigned"
-- instead of being mapped. A left EmpCode is remembered: it is not
-- counted as unmapped, and later months hide it (it can be undone).
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.attendance_code_map
  add column if not exists left_at timestamptz,
  add column if not exists left_by uuid references public.profiles (id) on delete set null;

-- p_items: [{"emp_code", "employee_id"|null, "sheet_name", "left": bool}]
create or replace function public.admin_save_code_map(p_items jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'Mapping must be a list'; end if;
  if exists (select 1 from jsonb_to_recordset(p_items) as x(employee_id uuid, "left" boolean)
              where x.employee_id is not null and not coalesce(x."left", false)
              group by x.employee_id having count(*) > 1) then
    raise exception 'An employee can only be mapped to one EmpCode';
  end if;

  -- free employees that are being moved to a different code in this save
  update public.attendance_code_map m
     set employee_id = null, mapped_by = auth.uid(), mapped_at = now()
   where m.employee_id in (select x.employee_id from jsonb_to_recordset(p_items) as x(emp_code text, employee_id uuid, "left" boolean)
                            where x.employee_id is not null and not coalesce(x."left", false) and trim(x.emp_code) <> m.emp_code);

  insert into public.attendance_code_map (emp_code, employee_id, sheet_name, mapped_by, mapped_at, left_at, left_by)
  select trim(x.emp_code),
         case when coalesce(x."left", false) then null else x.employee_id end,
         nullif(trim(x.sheet_name), ''), auth.uid(), now(),
         case when coalesce(x."left", false) then now() end,
         case when coalesce(x."left", false) then auth.uid() end
    from jsonb_to_recordset(p_items) as x(emp_code text, employee_id uuid, sheet_name text, "left" boolean)
   where coalesce(trim(x.emp_code), '') <> ''
  on conflict (emp_code) do update
    set employee_id = excluded.employee_id,
        sheet_name  = coalesce(excluded.sheet_name, attendance_code_map.sheet_name),
        mapped_by   = excluded.mapped_by,
        mapped_at   = excluded.mapped_at,
        left_at     = case when excluded.left_at is null then null else coalesce(attendance_code_map.left_at, excluded.left_at) end,
        left_by     = case when excluded.left_at is null then null else coalesce(attendance_code_map.left_by, excluded.left_by) end;
end;
$$;
