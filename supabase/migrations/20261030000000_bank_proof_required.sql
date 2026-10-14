-- =====================================================================
-- Altius HRMS — bank details always come with a bank proof
--
--  * admin_decide_bank: bank details without a proof can't be approved
--    (send them back to ask for it).
--  * submit_bank_details: an employee whose details are waiting without
--    a proof (from before the proof was asked for) can submit them again
--    with one; it replaces the waiting entry. Verified details without a
--    proof can get one even while the KYC is open.
--  * admin_decide_change: older "Request a change" entries that change
--    bank details can only be rejected (no proof with them).
-- Re-runnable. Nothing is removed.
-- =====================================================================

create or replace function public.submit_bank_details(p jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_acc  text := regexp_replace(coalesce(p ->> 'account_number', ''), '\s', '', 'g');
  v_ifsc text := upper(trim(coalesce(p ->> 'ifsc', '')));
  v_doc  text := nullif(trim(p ->> 'doc_path'), '');
  k      public.kyc_submissions;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and status = 'active') then raise exception 'Only active employees can do this'; end if;
  select * into k from public.kyc_submissions where employee_id = v_uid;
  if k.employee_id is null then raise exception 'Submit your KYC first — bank details are part of it'; end if;
  if public.can_edit_kyc() and not public._bank_verified(v_uid) then raise exception 'Your KYC is open — put the bank details in the KYC form'; end if;
  if exists (select 1 from public.bank_requests where employee_id = v_uid and status = 'pending' and doc_path is not null) then
    raise exception 'Your bank details are already waiting for approval';
  end if;
  if v_acc !~ '^[0-9]{9,18}$' then raise exception 'Invalid bank account number'; end if;
  if v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'Invalid IFSC code'; end if;
  if v_doc is null then raise exception 'Upload a bank proof (cancelled cheque, passbook or statement)'; end if;
  if left(v_doc, length(v_uid::text) + 1) <> v_uid::text || '/' then raise exception 'Invalid document path'; end if;
  -- Details waiting without a proof are replaced by this submission (which has one)
  update public.bank_requests set status = 'withdrawn', decided_at = now() where employee_id = v_uid and status = 'pending' and doc_path is null;
  insert into public.bank_requests (employee_id, account_number, ifsc, doc_path, previous, source, note)
  values (v_uid, v_acc, v_ifsc, v_doc,
          case when public._bank_verified(v_uid) then jsonb_build_object('account_number', k.bank_account_number, 'ifsc', k.bank_ifsc) end,
          'change', nullif(trim(p ->> 'note'), ''))
  returning id into v_id;
  perform public._fin_log('emd', v_uid, current_date, 'Bank details submitted for approval', null, jsonb_build_object('request_id', v_id));
  return v_id;
end;
$$;

create or replace function public.admin_decide_bank(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.bank_requests;
begin
  if not public.is_admin() then raise exception 'Only admin can do this'; end if;
  select * into r from public.bank_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'These bank details are no longer waiting'; end if;
  if r.employee_id = auth.uid() then raise exception 'Another admin has to approve your own bank details'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Write what needs to be fixed'; end if;
  if p_approve and r.doc_path is null then raise exception 'There is no bank proof yet — send it back to ask for one'; end if;
  if p_approve then
    update public.kyc_submissions
       set bank_account_number = r.account_number, bank_ifsc = r.ifsc,
           bank_doc_path = coalesce(r.doc_path, bank_doc_path), bank_verified_at = now(), updated_at = now()
     where employee_id = r.employee_id;
  end if;
  update public.bank_requests
     set status = case when p_approve then 'approved' else 'sent_back' end,
         admin_note = nullif(trim(p_note), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  perform public._fin_log('emd', r.employee_id, current_date,
    case when p_approve then 'Bank details approved' else 'Bank details sent back' end, null,
    jsonb_build_object('request_id', p_id, 'account_last4', right(r.account_number, 4), 'ifsc', r.ifsc, 'note', nullif(trim(p_note), '')));
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
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Write why the change is rejected'; end if;
  -- Bank details need a bank proof now: older requests that ask for a bank change can only be rejected
  if p_approve and (r.changes ? 'bank_account_number' or r.changes ? 'bank_ifsc') then
    raise exception 'Bank details now need a bank proof — reject this and ask them to use My KYC → Bank details';
  end if;
  if p_approve then
    c := r.changes;
    update public.profiles
       set full_name     = coalesce(c ->> 'full_name', full_name),
           phone         = coalesce(c ->> 'phone', phone),
           date_of_birth = coalesce((c ->> 'date_of_birth')::date, date_of_birth)
     where id = r.employee_id;
    update public.kyc_submissions
       set bank_account_number    = coalesce(c ->> 'bank_account_number', bank_account_number),
           bank_ifsc              = coalesce(c ->> 'bank_ifsc', bank_ifsc),
           emergency_name         = coalesce(c ->> 'emergency_name', emergency_name),
           emergency_relationship = coalesce(c ->> 'emergency_relationship', emergency_relationship),
           emergency_phone        = coalesce(c ->> 'emergency_phone', emergency_phone),
           updated_at             = now()
     where employee_id = r.employee_id;
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

revoke execute on function public.submit_bank_details(jsonb) from public, anon;
grant execute on function public.submit_bank_details(jsonb) to authenticated;
revoke execute on function public.admin_decide_bank(uuid, boolean, text) from public, anon;
grant execute on function public.admin_decide_bank(uuid, boolean, text) to authenticated;
revoke execute on function public.admin_decide_change(uuid, boolean, text) from public, anon;
grant execute on function public.admin_decide_change(uuid, boolean, text) to authenticated;
