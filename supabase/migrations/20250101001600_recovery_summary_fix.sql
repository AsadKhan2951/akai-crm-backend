-- Corrective Phase 11 migration. Do not edit 0014 or 0015.
create or replace function public.admin_recovery_summary()
returns table(bucket text, customer_count integer, receivable_pkr numeric(12,2))
language sql stable security invoker set search_path=public as $$
  with payments as (
    select pc.customer_id, max(pc.cleared_at) filter (where pc.status='CLEARED') as last_payment_at
    from public.payment_collections pc
    group by pc.customer_id
  ),
  customer_ageing as (
    select
      greatest(0, current_date - coalesce(p.last_payment_at::date, max(o.placed_at)::date, current_date)) as age_days,
      greatest(c.current_balance_pkr,0)::numeric(12,2) as balance_pkr
    from public.customers c
    left join payments p on p.customer_id=c.id
    left join public.orders o on o.customer_id=c.id and o.status <> 'CANCELLED'
    where public.has_permission(auth.uid(),'collection.view')
      and public.has_permission(auth.uid(),'financials.view_revenue')
      and c.is_internal_account=false
      and c.current_balance_pkr>0
    group by c.id,c.current_balance_pkr,p.last_payment_at
  ),
  bucketed as (
    select case when age_days <= 30 then '0-30' when age_days <= 60 then '31-60' when age_days <= 90 then '61-90' else '90+' end as bucket, balance_pkr from customer_ageing
  )
  select bucket, count(*)::integer, sum(balance_pkr)::numeric(12,2)
  from bucketed
  group by bucket
  order by case bucket when '0-30' then 1 when '31-60' then 2 when '61-90' then 3 else 4 end;
$$;
grant execute on function public.admin_recovery_summary() to authenticated;
