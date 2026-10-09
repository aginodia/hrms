-- =====================================================================
-- Altius HRMS — signed passes for the Google Drive bridge
--
-- The Drive bridge (Apps Script) no longer calls Supabase to check who is
-- signed in (some Google Workspace accounts are not allowed to approve
-- "connect to an external service"). Instead the HRMS asks the database
-- for a short-lived pass signed with a shared secret; the bridge checks the
-- signature with the same secret (script property DRIVE_SECRET).
--
--  * app_secrets: server-only secrets (no one can read it through the API).
--  * drive_ticket(): the signed-in person's pass, valid 5 minutes:
--      base64url(json{uid, admin, name, eid, exp}) || '.' || hex(hmac_sha256)
--  * admin_drive_secret(): Super Admins can copy the secret into the bridge.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.app_secrets (
  key    text primary key,
  value  text not null
);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

insert into public.app_secrets (key, value)
values ('drive_bridge', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

create or replace function public.drive_ticket()
returns text language plpgsql stable security definer set search_path = public, extensions
as $$
declare p public.profiles; v_secret text; v_payload text; v_b64 text;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.status not in ('kyc_pending', 'kyc_submitted', 'active') then
    raise exception 'Your account cannot use file storage yet';
  end if;
  select value into v_secret from public.app_secrets where key = 'drive_bridge';
  v_payload := jsonb_build_object('uid', p.id, 'admin', p.role = 'admin' and p.status = 'active',
    'name', p.full_name, 'eid', p.employee_code, 'exp', floor(extract(epoch from now())) + 300)::text;
  v_b64 := translate(encode(convert_to(v_payload, 'utf8'), 'base64'), E'+/=\n', '-_');
  return v_b64 || '.' || encode(extensions.hmac(v_b64, v_secret, 'sha256'), 'hex');
end;
$$;

create or replace function public.admin_drive_secret()
returns text language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Only a Super Admin can see this'; end if;
  return (select value from public.app_secrets where key = 'drive_bridge');
end;
$$;

revoke execute on function public.drive_ticket() from public, anon;
revoke execute on function public.admin_drive_secret() from public, anon;
grant execute on function public.drive_ticket() to authenticated;
grant execute on function public.admin_drive_secret() to authenticated;
