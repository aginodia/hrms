-- =====================================================================
-- Altius HRMS — signatory signature for grant letters
--
--  * doc_assets: small images used on documents. The signature is only
--    readable by admins (it is printed on grant letters, which employees
--    then download from Drive) — it is never sent to employees' browsers.
--  * admin_set_doc_asset(): Super Admins upload / remove it (a data: URL).
--  * Our letterhead's signatory title becomes "Authorized Signatory" (as on our
--    grant letters) unless someone already changed it.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create table if not exists public.doc_assets (
  key         text primary key check (key in ('signature')),
  data        text not null,
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now()
);
alter table public.doc_assets enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'doc_assets' and policyname = 'doc_assets_admin_select') then
    create policy doc_assets_admin_select on public.doc_assets for select to authenticated using (public.is_admin());
  end if;
end $$;
revoke all on public.doc_assets from anon;
grant select on public.doc_assets to authenticated;

create or replace function public.admin_set_doc_asset(p_key text, p_data text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Only a Super Admin can do this'; end if;
  if p_key not in ('signature') then raise exception 'Unknown document image'; end if;
  if p_data is null or p_data = '' then
    update public.doc_assets set data = '', updated_by = auth.uid(), updated_at = now() where key = p_key;
    return;
  end if;
  if p_data !~ '^data:image/(png|jpeg);base64,' then raise exception 'Upload a PNG or JPG image'; end if;
  if length(p_data) > 700000 then raise exception 'The image is too large — keep it under 500 KB'; end if;
  insert into public.doc_assets (key, data, updated_by) values (p_key, p_data, auth.uid())
  on conflict (key) do update set data = excluded.data, updated_by = excluded.updated_by, updated_at = now();
end;
$$;

revoke execute on function public.admin_set_doc_asset(text, text) from public, anon;
grant execute on function public.admin_set_doc_asset(text, text) to authenticated;

update public.app_settings
   set value = value || '{"signatory_title": "Authorized Signatory"}'::jsonb
 where key = 'company' and value ->> 'signatory_title' = 'Director' and coalesce(value ->> 'signatory_name', '') = '';
