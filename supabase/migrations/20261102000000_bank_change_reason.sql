-- =====================================================================
-- Altius HRMS — bank account changes need a reason; fuller bank log
--
--  * submit_bank_details: changing a verified bank account needs a reason
--    (it still needs HR's approval, with a bank proof).
--  * my_portal: the employee's bank log keeps the last 100 entries.
-- Re-runnable.
-- =====================================================================

create or replace function public.submit_bank_details(p jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_acc  text := regexp_replace(coalesce(p ->> 'account_number', ''), '\s', '', 'g');
  v_ifsc text := upper(trim(coalesce(p ->> 'ifsc', '')));
  v_doc  text := nullif(trim(p ->> 'doc_path'), '');
  cur    public.bank_details;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and status = 'active') then raise exception 'Only active employees can do this'; end if;
  select * into cur from public.bank_details where employee_id = v_uid;
  if exists (select 1 from public.bank_requests where employee_id = v_uid and status = 'pending' and doc_path is not null) then
    raise exception 'Your bank details are already waiting for approval';
  end if;
  if v_acc !~ '^[0-9]{9,18}$' then raise exception 'Invalid bank account number'; end if;
  if v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Invalid IFSC code'; end if;
  if v_doc is null then raise exception 'Upload a bank proof (cancelled cheque, passbook or statement)'; end if;
  if cur.employee_id is not null and coalesce(trim(p ->> 'note'), '') = '' then raise exception 'Write the reason for changing your bank account'; end if;
  if left(v_doc, length(v_uid::text) + 1) <> v_uid::text || '/' then raise exception 'Invalid document path'; end if;
  -- Details waiting without a proof are replaced by this submission (which has one)
  update public.bank_requests set status = 'withdrawn', decided_at = now() where employee_id = v_uid and status = 'pending' and doc_path is null;
  insert into public.bank_requests (employee_id, account_number, ifsc, doc_path, previous, source, note)
  values (v_uid, v_acc, v_ifsc, v_doc,
          case when cur.employee_id is not null then jsonb_build_object('account_number', cur.account_number, 'ifsc', cur.ifsc) end,
          'change', nullif(trim(p ->> 'note'), ''))
  returning id into v_id;
  perform public._fin_log('emd', v_uid, current_date, 'Bank details submitted for approval', null, jsonb_build_object('request_id', v_id));
  return v_id;
end;
$$;

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.my_portal()'::regprocedure);
  if position('where employee_id = v_uid order by created_at desc limit 10' in d) > 0 then
    n := replace(d, 'where employee_id = v_uid order by created_at desc limit 10', 'where employee_id = v_uid order by created_at desc limit 100');
    execute n;
  end if;
end $$;

revoke execute on function public.submit_bank_details(jsonb) from public, anon;
grant execute on function public.submit_bank_details(jsonb) to authenticated;
revoke execute on function public.my_portal() from public, anon;
grant execute on function public.my_portal() to authenticated;
