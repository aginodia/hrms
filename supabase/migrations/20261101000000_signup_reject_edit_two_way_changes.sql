-- =====================================================================
-- Altius HRMS — sign-up rejection types, DOB at sign-up, two-way change
-- requests
--
--  * Sign-up asks for the date of birth (profiles.date_of_birth).
--  * A sign-up request can be
--      - rejected for edits (admin_reject_for_edit): the person signs in,
--        corrects their details (resubmit_signup) and the request goes back
--        to Signup Requests;
--      - marked NA / unidentified (admin_remove_unidentified): the sign-up
--        is deleted — login, name and email are removed from the database.
--  * Change requests now also cover date of joining and email (the login
--    email changes too). They go both ways:
--      - the employee asks → an admin approves (admin_decide_change);
--      - an admin asks (admin_request_change) → the employee approves
--        (employee_decide_change).
--    Nothing changes until the other side approves.
-- Re-runnable.
-- =====================================================================

alter table public.profiles add column if not exists rejection_kind text;
alter table public.profiles add column if not exists resubmitted_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_rejection_kind_check') then
    alter table public.profiles add constraint profiles_rejection_kind_check check (rejection_kind in ('edit'));
  end if;
end $$;

alter table public.change_requests add column if not exists requested_by text not null default 'employee';
alter table public.change_requests add column if not exists created_by uuid references public.profiles (id) on delete set null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'change_requests_requested_by_check') then
    alter table public.change_requests add constraint change_requests_requested_by_check check (requested_by in ('employee', 'admin'));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Sign-up: date of birth from the sign-up form
-- ---------------------------------------------------------------------
create or replace function public._safe_dob(p text)
returns date language plpgsql immutable as $$
declare d date;
begin
  if coalesce(trim(p), '') = '' then return null; end if;
  d := p::date;
  if d > current_date - interval '14 years' or d < date '1940-01-01' then return null; end if;
  return d;
exception when others then return null;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email    text := lower(new.email);
  v_is_admin boolean := lower(new.email) = public.base_admin_email();
begin
  insert into public.profiles (id, full_name, email, phone, date_of_birth, role, status)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
             case when v_is_admin then 'Sayan Mullick' else split_part(v_email, '@', 1) end),
    v_email,
    nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
    public._safe_dob(new.raw_user_meta_data ->> 'date_of_birth'),
    case when v_is_admin then 'admin' else 'team' end,
    case when v_is_admin then 'active' else 'pending' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Login email: auth user, its email identity and the profile
create or replace function public._set_login_email(p_user uuid, p_email text)
returns void language plpgsql security definer set search_path = public
as $$
declare v text := lower(trim(p_email));
begin
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
  if exists (select 1 from auth.users where lower(email) = v and id <> p_user)
     or exists (select 1 from public.profiles where lower(email) = v and id <> p_user) then
    raise exception 'This email is already used by another account';
  end if;
  update auth.users set email = v, updated_at = now() where id = p_user;
  update auth.identities set identity_data = jsonb_set(coalesce(identity_data, '{}'::jsonb), '{email}', to_jsonb(v)), updated_at = now()
   where user_id = p_user and provider = 'email';
  update public.profiles set email = v where id = p_user;
end;
$$;

-- ---------------------------------------------------------------------
-- Sign-up rejection: for edits, or NA (unidentified → deleted)
-- ---------------------------------------------------------------------
create or replace function public.admin_reject_for_edit(p_user uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot reject your own account'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Write what they need to correct'; end if;
  update public.profiles
     set status = 'inactive', rejected_at = now(), rejected_by = auth.uid(),
         rejection_reason = trim(p_reason), rejection_kind = 'edit'
   where id = p_user and status = 'pending' and role = 'team';
  if not found then raise exception 'This sign-up can no longer be rejected'; end if;
end;
$$;

-- The person corrects their sign-up details; the request goes back to Signup Requests
create or replace function public.resubmit_signup(p_full_name text, p_phone text, p_dob date, p_email text)
returns void language plpgsql security definer set search_path = public
as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.status <> 'inactive' or p.rejected_at is null or p.rejection_kind is distinct from 'edit' then
    raise exception 'Your sign-up is not open for corrections';
  end if;
  if length(coalesce(trim(p_full_name), '')) < 2 then raise exception 'Enter your full name'; end if;
  if regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') !~ '^(91)?[0-9]{10}$' then raise exception 'Enter a valid phone number'; end if;
  if p_dob is null or p_dob > current_date - interval '14 years' or p_dob < date '1940-01-01' then raise exception 'Enter a valid date of birth'; end if;
  if lower(trim(coalesce(p_email, ''))) <> lower(p.email) then perform public._set_login_email(p.id, p_email); end if;
  update public.profiles
     set full_name = trim(p_full_name), phone = trim(p_phone), date_of_birth = p_dob,
         status = 'pending', rejected_at = null, rejected_by = null, rejection_kind = null, resubmitted_at = now()
   where id = p.id;
end;
$$;

-- NA: an unidentified sign-up is deleted (login, name and email removed)
create or replace function public.admin_remove_unidentified(p_user uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare p public.profiles;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'You cannot remove your own account'; end if;
  select * into p from public.profiles where id = p_user;
  if p.id is null then raise exception 'This sign-up is already gone'; end if;
  if p.role <> 'team' or p.status not in ('pending', 'inactive') or p.access_granted_at is not null
     or p.employee_code is not null or p.fnf_completed_at is not null then
    raise exception 'Only a sign-up that never got access can be removed';
  end if;
  delete from auth.users where id = p_user;
end;
$$;

-- ---------------------------------------------------------------------
-- Change requests: + date of joining and email; both directions
-- ---------------------------------------------------------------------
create or replace function public._change_fields()
returns text[] language sql immutable as $$
  select array['full_name', 'phone', 'email', 'date_of_birth', 'date_of_joining', 'emergency_name', 'emergency_relationship', 'emergency_phone'];
$$;

create or replace function public._current_details(p_user uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'full_name', p.full_name, 'phone', p.phone, 'email', p.email, 'date_of_birth', p.date_of_birth, 'date_of_joining', p.date_of_joining,
    'emergency_name', k.emergency_name, 'emergency_relationship', k.emergency_relationship,
    'emergency_phone', k.emergency_phone)
  from public.profiles p left join public.kyc_submissions k on k.employee_id = p.id
  where p.id = p_user;
$$;

-- Checks a set of changes; returns {"changes": {...new}, "previous": {...now}}
create or replace function public._prepare_change(p_user uuid, p_changes jsonb)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare
  v_cur  jsonb := public._current_details(p_user);
  v_new  jsonb := '{}'::jsonb;
  v_prev jsonb := '{}'::jsonb;
  v_key  text;
  v_val  text;
begin
  for v_key, v_val in select key, trim(value) from jsonb_each_text(coalesce(p_changes, '{}'::jsonb)) loop
    if not v_key = any (public._change_fields()) then raise exception 'This detail cannot be changed here: %', v_key; end if;
    if v_val = '' then raise exception 'A new value cannot be empty'; end if;
    if v_key = 'email' then v_val := lower(v_val); end if;
    if v_val is not distinct from (v_cur ->> v_key) then continue; end if;
    if v_key like 'emergency_%' and not exists (select 1 from public.kyc_submissions where employee_id = p_user) then
      raise exception 'Emergency contact comes from the KYC — submit the KYC first';
    end if;
    if v_key = 'date_of_birth' then
      if v_val::date > current_date - interval '14 years' or v_val::date < date '1940-01-01' then raise exception 'Invalid date of birth'; end if;
    end if;
    if v_key = 'date_of_joining' then
      if v_val::date > current_date + interval '1 year' or v_val::date < date '1980-01-01' then raise exception 'Invalid date of joining'; end if;
    end if;
    if v_key = 'email' then
      if v_val !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
      if exists (select 1 from public.profiles where lower(email) = v_val and id <> p_user) then raise exception 'This email is already used by another account'; end if;
    end if;
    if v_key = 'phone' and regexp_replace(v_val, '\D', '', 'g') !~ '^(91)?[0-9]{10}$' then raise exception 'Enter a valid phone number'; end if;
    v_new := v_new || jsonb_build_object(v_key, v_val);
    v_prev := v_prev || jsonb_build_object(v_key, v_cur -> v_key);
  end loop;
  if v_new = '{}'::jsonb then raise exception 'Nothing has changed'; end if;
  return jsonb_build_object('changes', v_new, 'previous', v_prev);
end;
$$;

create or replace function public._apply_change(p_user uuid, c jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.profiles
     set full_name       = coalesce(c ->> 'full_name', full_name),
         phone           = coalesce(c ->> 'phone', phone),
         date_of_birth   = coalesce((c ->> 'date_of_birth')::date, date_of_birth),
         date_of_joining = coalesce((c ->> 'date_of_joining')::date, date_of_joining)
   where id = p_user;
  if c ? 'email' then perform public._set_login_email(p_user, c ->> 'email'); end if;
  update public.kyc_submissions
     set emergency_name         = coalesce(c ->> 'emergency_name', emergency_name),
         emergency_relationship = coalesce(c ->> 'emergency_relationship', emergency_relationship),
         emergency_phone        = coalesce(c ->> 'emergency_phone', emergency_phone),
         updated_at             = now()
   where employee_id = p_user and (c ? 'emergency_name' or c ? 'emergency_relationship' or c ? 'emergency_phone');
end;
$$;

-- Employee asks → admin approves
create or replace function public.request_profile_change(p_changes jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v jsonb; v_id uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and status = 'active') then
    raise exception 'Only active users can request changes';
  end if;
  if exists (select 1 from public.change_requests where employee_id = v_uid and status = 'pending') then
    raise exception 'A change request is already waiting — finish that one first';
  end if;
  v := public._prepare_change(v_uid, p_changes);
  insert into public.change_requests (employee_id, changes, previous, note, requested_by, created_by)
  values (v_uid, v -> 'changes', v -> 'previous', nullif(trim(p_note), ''), 'employee', v_uid)
  returning id into v_id;
  perform public._fin_log('emd', v_uid, current_date, 'Change requested by employee', null,
    jsonb_build_object('request_id', v_id, 'fields', (select jsonb_agg(k) from jsonb_object_keys(v -> 'changes') k)));
  return v_id;
end;
$$;

create or replace function public.withdraw_change_request(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.change_requests set status = 'withdrawn', decided_at = now()
   where id = p_id and employee_id = auth.uid() and status = 'pending' and requested_by = 'employee';
  if not found then raise exception 'This request is no longer waiting'; end if;
end;
$$;

create or replace function public.admin_decide_change(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare
  r public.change_requests;
  c jsonb;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into r from public.change_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'This request is no longer waiting'; end if;
  if r.requested_by = 'admin' then raise exception 'HR asked for this change — the employee approves it'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Write why the change is rejected'; end if;
  -- Bank details need a bank proof now: older requests that ask for a bank change can only be rejected
  if p_approve and (r.changes ? 'bank_account_number' or r.changes ? 'bank_ifsc') then
    raise exception 'Bank details now need a bank proof — reject this and ask them to use My KYC → Bank details';
  end if;
  if p_approve then
    c := r.changes;
    perform public._apply_change(r.employee_id, c);
  end if;
  update public.change_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  perform public._fin_log('emd', r.employee_id, current_date,
    case when p_approve then 'Change request approved' else 'Change request rejected' end, null,
    jsonb_build_object('request_id', p_id, 'changes', r.changes, 'note', nullif(trim(p_note), '')));
end;
$$;

-- Admin asks → employee approves
create or replace function public.admin_request_change(p_user uuid, p_changes jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v jsonb; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if p_user = auth.uid() then raise exception 'Use your own profile to change your details'; end if;
  if not exists (select 1 from public.profiles where id = p_user and status = 'active') then raise exception 'Employee not found'; end if;
  if exists (select 1 from public.change_requests where employee_id = p_user and status = 'pending') then
    raise exception 'A change request for this employee is already waiting — finish that one first';
  end if;
  v := public._prepare_change(p_user, p_changes);
  insert into public.change_requests (employee_id, changes, previous, note, requested_by, created_by)
  values (p_user, v -> 'changes', v -> 'previous', nullif(trim(p_note), ''), 'admin', auth.uid())
  returning id into v_id;
  perform public._fin_log('emd', p_user, current_date, 'Change asked by HR (needs the employee''s approval)', null,
    jsonb_build_object('request_id', v_id, 'fields', (select jsonb_agg(k) from jsonb_object_keys(v -> 'changes') k)));
  return v_id;
end;
$$;

create or replace function public.employee_decide_change(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.change_requests;
begin
  select * into r from public.change_requests where id = p_id and status = 'pending' for update;
  if not found or r.employee_id is distinct from auth.uid() then raise exception 'This request is no longer waiting'; end if;
  if r.requested_by <> 'admin' then raise exception 'You asked for this change — HR approves it'; end if;
  if p_approve then perform public._apply_change(r.employee_id, r.changes); end if;
  update public.change_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  perform public._fin_log('emd', r.employee_id, current_date,
    case when p_approve then 'Employee approved HR''s change' else 'Employee rejected HR''s change' end, null,
    jsonb_build_object('request_id', p_id, 'changes', r.changes, 'note', nullif(trim(p_note), '')));
end;
$$;

create or replace function public.admin_withdraw_change(p_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  update public.change_requests set status = 'withdrawn', decided_by = auth.uid(), decided_at = now()
   where id = p_id and status = 'pending' and requested_by = 'admin';
  if not found then raise exception 'This request is no longer waiting'; end if;
end;
$$;

-- Employee portal: who asked for each change
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.my_portal()'::regprocedure);
  if position('''requested_by''' in d) = 0 then
    n := replace(d, '''status'', c.status, ''admin_note'', c.admin_note', '''status'', c.status, ''requested_by'', c.requested_by, ''admin_note'', c.admin_note');
    if n = d then raise exception 'my_portal: requests line not found'; end if;
    execute n;
  end if;
end $$;

revoke execute on function public._safe_dob(text) from public, anon, authenticated;
revoke execute on function public._set_login_email(uuid, text) from public, anon, authenticated;
revoke execute on function public._prepare_change(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public._apply_change(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public._current_details(uuid) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.admin_reject_for_edit(uuid, text) from public, anon;
grant execute on function public.admin_reject_for_edit(uuid, text) to authenticated;
revoke execute on function public.resubmit_signup(text, text, date, text) from public, anon;
grant execute on function public.resubmit_signup(text, text, date, text) to authenticated;
revoke execute on function public.admin_remove_unidentified(uuid) from public, anon;
grant execute on function public.admin_remove_unidentified(uuid) to authenticated;
revoke execute on function public.request_profile_change(jsonb, text) from public, anon;
grant execute on function public.request_profile_change(jsonb, text) to authenticated;
revoke execute on function public.withdraw_change_request(uuid) from public, anon;
grant execute on function public.withdraw_change_request(uuid) to authenticated;
revoke execute on function public.admin_decide_change(uuid, boolean, text) from public, anon;
grant execute on function public.admin_decide_change(uuid, boolean, text) to authenticated;
revoke execute on function public.admin_request_change(uuid, jsonb, text) from public, anon;
grant execute on function public.admin_request_change(uuid, jsonb, text) to authenticated;
revoke execute on function public.employee_decide_change(uuid, boolean, text) from public, anon;
grant execute on function public.employee_decide_change(uuid, boolean, text) to authenticated;
revoke execute on function public.admin_withdraw_change(uuid) from public, anon;
grant execute on function public.admin_withdraw_change(uuid) to authenticated;
