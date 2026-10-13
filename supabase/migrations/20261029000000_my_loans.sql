-- =====================================================================
-- Altius HRMS — employee portal: each loan with its repayment log
--
--  my_loans(): the caller's own loans (only when "Bonus, variable &
--  loans" is switched on in Team Access, and not after leaving), each
--  with every repayment: deductions from Variable / Bonus and direct
--  repayments, oldest first. Read only.
-- Re-runnable. Nothing is removed.
-- =====================================================================

create or replace function public.my_loans()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare
  see_fin boolean := coalesce(((select value from public.app_settings where key = 'team_visibility') ->> 'finance')::boolean, true);
begin
  if auth.uid() is null or not see_fin or public._i_have_left() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', l.id, 'taken_on', l.taken_on, 'amount', l.amount, 'note', l.note,
      'remaining', public.loan_remaining(l.id),
      'log', coalesce((select jsonb_agg(x order by x ->> 'on', x ->> 'at') from (
          select jsonb_build_object('kind', d.source, 'amount', d.amount, 'at', d.created_at,
                   'on', case when d.source = 'variable' then coalesce(vp.pay_month, d.pay_month, d.created_at::date)
                              else coalesce(b.pay_date, b.pay_month, d.pay_month, d.created_at::date) end,
                   'month', case when d.source = 'variable' then coalesce(vp.pay_month, d.pay_month) else coalesce(b.pay_month, d.pay_month) end,
                   'label', case when d.source = 'bonus' then b.description end) x
            from public.loan_deductions d
            left join public.variable_payouts vp on d.source = 'variable' and vp.id = d.source_id
            left join public.bonus_payments b on d.source = 'bonus' and b.id = d.source_id
           where d.loan_id = l.id and d.voided_at is null
          union all
          select jsonb_build_object('kind', 'repayment', 'amount', r.amount, 'at', r.created_at, 'on', r.paid_on, 'label', r.note)
            from public.loan_repayments r
           where r.loan_id = l.id and r.voided_at is null) s), '[]'::jsonb)
    ) order by l.taken_on desc, l.created_at desc)
    from public.loans l where l.employee_id = auth.uid() and l.removed_at is null), '[]'::jsonb);
end;
$$;

revoke execute on function public.my_loans() from public, anon;
grant execute on function public.my_loans() to authenticated;
