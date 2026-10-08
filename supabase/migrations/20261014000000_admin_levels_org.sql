-- =====================================================================
-- Altius HRMS — Super Admin / Base Admin
--
--  * profiles.admin_level for admins: 'super' (full control, e.g. the
--    co-founders) or 'base' (partial, e.g. HR).
--  * Only a Super Admin can give, change or remove admin access, change
--    a Super Admin's record, or reset an admin's password. A Base Admin
--    does everything else in the admin console.
--  * Super Admins are the management: they are Non-EMD (not in Employee
--    Master Data or payroll), need no Employee ID or reporting manager,
--    only a designation, and sit at the top of the org structure.
--    Base Admins are employees and stay in EMD and payroll.
--  * Non-EMD is now only for Super Admins; anyone else marked Non-EMD
--    moves back into Employee Master Data.
--  * Existing admins become Super Admins (nobody loses access).
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.profiles
  add column if not exists admin_level text check (admin_level in ('super', 'base'));

update public.profiles set admin_level = 'super' where role = 'admin' and admin_level is null;
update public.profiles set member_type = 'non_employee' where role = 'admin' and admin_level = 'super' and member_type <> 'non_employee';
update public.profiles set member_type = 'employee' where member_type = 'non_employee' and not (role = 'admin' and admin_level = 'super');

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
     where id = auth.uid() and role = 'admin' and status = 'active'
       and (admin_level = 'super' or lower(email) = public.base_admin_email()));
$$;

-- Guard on the profiles table: whatever function does the update, only a Super Admin
-- can change admin access or touch a Super Admin's record.
create or replace function public._guard_admin_rows()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null or public.is_super_admin() then return new; end if; -- SQL editor / migrations, or a Super Admin
  if new.role is distinct from old.role or new.admin_level is distinct from old.admin_level then
    raise exception 'Only a Super Admin can give, change or remove admin access';
  end if;
  if old.role = 'admin' and coalesce(old.admin_level, 'super') = 'super' and old.id <> auth.uid() then
    raise exception 'Only a Super Admin can change a Super Admin';
  end if;
  return new;
end;
$$;

create or replace trigger profiles_guard_admin before update on public.profiles
  for each row execute function public._guard_admin_rows();

-- Give / change / remove admin access. p_level: 'super', 'base' or null (remove).
create or replace function public.admin_set_admin_level(p_user uuid, p_level text)
returns void language plpgsql security definer set search_path = public
as $$
declare v public.profiles;
begin
  if not public.is_super_admin() then raise exception 'Only a Super Admin can give, change or remove admin access'; end if;
  if p_level is not null and p_level not in ('super', 'base') then raise exception 'Unknown admin level'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own admin access'; end if;
  select * into v from public.profiles where id = p_user and status = 'active';
  if not found then raise exception 'Only an active user can be given or lose admin access'; end if;
  if lower(v.email) = public.base_admin_email() and p_level is distinct from 'super' then
    raise exception 'The owner always stays a Super Admin';
  end if;
  if v.role = 'admin' and v.admin_level is not distinct from p_level then return; end if;

  update public.profiles
     set role        = case when p_level is null then 'team' else 'admin' end,
         admin_level = p_level,
         member_type = case when p_level = 'super' then 'non_employee' else 'employee' end
   where id = p_user;

  perform public._fin_log('emd', p_user, current_date,
    case p_level when 'super' then 'Made Super Admin' when 'base' then 'Made Base Admin' else 'Admin access removed' end, null,
    jsonb_build_object('from', case when v.role = 'admin' then coalesce(v.admin_level, 'super') else 'team' end, 'to', coalesce(p_level, 'team')));
end;
$$;

-- The old give / revoke call: "give" now means Super Admin
create or replace function public.admin_set_admin(p_user uuid, p_admin boolean)
returns void language plpgsql security definer set search_path = public
as $$
begin
  perform public.admin_set_admin_level(p_user, case when p_admin then 'super' end);
end;
$$;

-- Non-EMD is only for Super Admins
create or replace function public.admin_set_member_type(p_user uuid, p_type text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_type = 'non_employee' then raise exception 'Non-EMD is only for Super Admins — give Super Admin access instead'; end if;
  if p_type <> 'employee' then raise exception 'Unknown type'; end if;
  update public.profiles set member_type = 'employee'
   where id = p_user and status = 'active' and not (role = 'admin' and coalesce(admin_level, 'super') = 'super');
  if not found then raise exception 'User not found'; end if;
  perform public._fin_log('emd', p_user, current_date, 'Moved to Employee Master Data', null, null);
end;
$$;

-- Designation only (Super Admins have no Employee ID or manager to edit)
create or replace function public.admin_set_designation(p_user uuid, p_designation text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.profiles set designation = nullif(trim(p_designation), '') where id = p_user and status = 'active';
  if not found then raise exception 'User not found'; end if;
  perform public._fin_log('emd', p_user, current_date, 'Designation set: ' || coalesce(nullif(trim(p_designation), ''), '—'), null, null);
end;
$$;

-- Reset password: an admin's password only by a Super Admin
create or replace function public.admin_set_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public
as $$
declare t public.profiles;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'The password must be at least 8 characters'; end if;
  select * into t from public.profiles where id = p_user;
  if not found then raise exception 'This person was not found'; end if;
  if t.id <> auth.uid() and lower(t.email) = lower(public.base_admin_email()) then
    raise exception 'Only the owner can change the owner''s password';
  end if;
  if t.role = 'admin' and t.id <> auth.uid() and not public.is_super_admin() then
    raise exception 'Only a Super Admin can reset an admin''s password';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         email_confirmed_at = coalesce(email_confirmed_at, now()),
         updated_at         = now()
   where id = p_user;
  if not found then raise exception 'This person has no login'; end if;

  perform public._fin_log('emd', p_user, current_date, 'Password reset by admin', null, null);
end;
$$;

revoke execute on function public.is_super_admin() from public, anon;
revoke execute on function public._guard_admin_rows() from public, anon, authenticated;
revoke execute on function public.admin_set_admin_level(uuid, text) from public, anon;
revoke execute on function public.admin_set_designation(uuid, text) from public, anon;
grant execute on function public.is_super_admin() to authenticated;
grant execute on function public.admin_set_admin_level(uuid, text) to authenticated;
grant execute on function public.admin_set_designation(uuid, text) to authenticated;
