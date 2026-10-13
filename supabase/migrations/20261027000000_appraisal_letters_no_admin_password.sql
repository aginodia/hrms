-- =====================================================================
-- Altius HRMS — appraisal letters; admins no longer set passwords
--
--  * appraisals.letter_file_id / letter_file_name / letter_at: the
--    appraisal (increment / promotion) letter saved to Google Drive when an
--    appraisal is issued. admin_record_appraisal_letter() stores it;
--    my_appraisals() gives the employee its Drive id to download.
--  * Forgotten passwords are reset with an emailed one-time code, so the
--    admin "set a temporary password" function is switched off (kept in
--    the database, but nobody signed in can call it any more).
-- Re-runnable. Nothing is removed.
-- =====================================================================

alter table public.appraisals add column if not exists letter_file_id text;
alter table public.appraisals add column if not exists letter_file_name text;
alter table public.appraisals add column if not exists letter_at timestamptz;

create or replace function public.admin_record_appraisal_letter(p_id uuid, p_file_id text, p_file_name text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  if coalesce(trim(p_file_id), '') = '' then raise exception 'The Drive file is missing'; end if;
  update public.appraisals set letter_file_id = trim(p_file_id), letter_file_name = nullif(trim(p_file_name), ''), letter_at = now()
   where id = p_id and status = 'issued' and removed_at is null;
  if not found then raise exception 'Only an issued appraisal gets a letter'; end if;
end;
$$;

create or replace function public.my_appraisals()
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public._i_have_left() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'cycle_month', a.cycle_month, 'current_salary', a.current_salary, 'increment_pct', a.increment_pct,
           'new_salary', a.new_salary, 'current_designation', a.current_designation, 'new_designation', a.new_designation,
           'rating', a.rating, 'review', a.review, 'status', a.status, 'updated_at', a.updated_at, 'issued_at', a.issued_at,
           'letter_file_id', case when a.status = 'issued' then a.letter_file_id end, 'letter_file_name', case when a.status = 'issued' then a.letter_file_name end)
         order by a.cycle_month desc), '[]'::jsonb) end
    from public.appraisals a where a.employee_id = auth.uid() and a.removed_at is null;
$$;

revoke execute on function public.admin_record_appraisal_letter(uuid, text, text) from public, anon;
grant execute on function public.admin_record_appraisal_letter(uuid, text, text) to authenticated;
revoke execute on function public.my_appraisals() from public, anon;
grant execute on function public.my_appraisals() to authenticated;

-- Admins can no longer set someone else's password
revoke execute on function public.admin_set_password(uuid, text) from public, anon, authenticated;
