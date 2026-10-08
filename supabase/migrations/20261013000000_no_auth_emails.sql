-- =====================================================================
-- Altius HRMS — sign-in without any emails
--
-- The HRMS sends no emails: there is no sign-in code, no confirmation
-- link and no reset email. Admin approval is the gate instead.
--   * Giving access (status → active) also confirms the account's email
--     in Supabase Auth, so the person can sign in even if they signed up
--     while "Confirm email" was still on.
--   * admin_set_password: an admin sets a temporary password for someone
--     who forgot theirs. They sign in with it and change it in the portal.
--   * Accounts that are already approved or waiting for approval are
--     confirmed once, so nobody is stuck at "Email not confirmed".
-- Re-runnable. Nothing is removed.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Giving access confirms the email (covers Give access, Add employee, Excel upload, Restore)
create or replace function public._confirm_email_on_access()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'active' and old.status is distinct from 'active' then
    update auth.users set email_confirmed_at = now() where id = new.id and email_confirmed_at is null;
  end if;
  return new;
end;
$$;

create or replace trigger profiles_confirm_email after update of status on public.profiles
  for each row execute function public._confirm_email_on_access();

-- Admin sets a temporary password
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
    raise exception 'Only the base admin can change the base admin''s password';
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

revoke execute on function public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;
revoke execute on function public._confirm_email_on_access() from public, anon, authenticated;

-- One-time: confirm everyone already approved or waiting for approval (not rejected)
update auth.users u
   set email_confirmed_at = now()
  from public.profiles p
 where p.id = u.id
   and u.email_confirmed_at is null
   and p.rejected_at is null;
