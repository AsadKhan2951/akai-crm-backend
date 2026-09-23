-- Additive Admin portal migration. Do not edit migrations 0001-0012.
-- All date grouping uses Asia/Karachi while stored timestamps remain UTC.

create table public.admin_report_definitions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  entity text not null check (entity in ('orders','customers','products','activities','ledger')),
  columns_json jsonb not null default '[]'::jsonb,
  filters_json jsonb not null default '{}'::jsonb,
  output_format text not null default 'CSV' check (output_format in ('CSV','XLSX','PDF')),
  schedule_cron text,
  recipients_json jsonb not null default '[]'::jsonb,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz(6) not null default now(),
  updated_at timestamptz(6) not null default now()
);
create index admin_report_definitions_created_by_active_idx on public.admin_report_definitions(created_by_user_id, is_active, updated_at desc);

create table public.admin_report_runs (
  id uuid primary key default gen_random_uuid(),
  definition_id uuid not null references public.admin_report_definitions(id) on delete cascade,
  status text not null default 'QUEUED' check (status in ('QUEUED','RUNNING','COMPLETED','FAILED')),
  started_at timestamptz(6),
  completed_at timestamptz(6),
  artifact_url text,
  row_count integer,
  error_message text,
  created_at timestamptz(6) not null default now()
);
create index admin_report_runs_definition_created_idx on public.admin_report_runs(definition_id, created_at desc);
create index admin_report_runs_status_created_idx on public.admin_report_runs(status, created_at);

create table public.admin_impersonation_sessions (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.users(id) on delete restrict,
  target_user_id uuid references public.users(id) on delete restrict,
  target_customer_id uuid references public.customers(id) on delete restrict,
  mode text not null check (mode in ('ROLE_PREVIEW','VENDOR_IMPERSONATION')),
  started_at timestamptz(6) not null default now(),
  expires_at timestamptz(6) not null,
  ended_at timestamptz(6),
  created_at timestamptz(6) not null default now(),
  check (expires_at <= started_at + interval '30 minutes'),
  check (target_user_id is not null or target_customer_id is not null),
  check (admin_user_id <> target_user_id)
);
create index admin_impersonation_active_idx on public.admin_impersonation_sessions(admin_user_id, ended_at, expires_at);
create index admin_impersonation_target_idx on public.admin_impersonation_sessions(target_user_id, target_customer_id, started_at desc);

create table public.admin_anomaly_alerts (
  id uuid primary key default gen_random_uuid(),
  alert_type text not null check (alert_type in ('CUSTOMER_ORDER_DROP','AGENT_ACTIVITY_DROP','PRODUCT_AREA_DROP')),
  entity_id uuid,
  title text not null,
  body text not null,
  supporting_metrics_json jsonb not null default '{}'::jsonb,
  status text not null default 'OPEN' check (status in ('OPEN','ACKNOWLEDGED','RESOLVED')),
  created_at timestamptz(6) not null default now(),
  acknowledged_by_user_id uuid references public.users(id) on delete set null,
  acknowledged_at timestamptz(6)
);
create index admin_anomaly_alerts_status_created_idx on public.admin_anomaly_alerts(status, created_at desc);
create index admin_anomaly_alerts_type_entity_idx on public.admin_anomaly_alerts(alert_type, entity_id, created_at desc);

create table public.admin_dashboard_cache (
  user_id uuid not null references public.users(id) on delete cascade,
  range_start date not null,
  range_end date not null,
  payload_json jsonb not null,
  generated_at timestamptz(6) not null default now(),
  expires_at timestamptz(6) not null,
  primary key (user_id, range_start, range_end)
);
create index admin_dashboard_cache_expiry_idx on public.admin_dashboard_cache(expires_at);

alter table public.admin_report_definitions enable row level security;
alter table public.admin_report_runs enable row level security;
alter table public.admin_impersonation_sessions enable row level security;
alter table public.admin_anomaly_alerts enable row level security;
alter table public.admin_dashboard_cache enable row level security;

create policy admin_report_definitions_read on public.admin_report_definitions for select to authenticated
  using (public.has_permission(auth.uid(), 'report.build') and created_by_user_id = auth.uid());
create policy admin_report_definitions_global_read on public.admin_report_definitions for select to authenticated
  using (public.has_permission(auth.uid(), 'report.build') and public.role_scope(auth.uid()) = 'GLOBAL');
create policy admin_report_definitions_write on public.admin_report_definitions for all to authenticated
  using (public.has_permission(auth.uid(), 'report.build') and (created_by_user_id = auth.uid() or public.role_scope(auth.uid()) = 'GLOBAL'))
  with check (public.has_permission(auth.uid(), 'report.build') and created_by_user_id = auth.uid());

create policy admin_report_runs_read on public.admin_report_runs for select to authenticated
  using (
    public.has_permission(auth.uid(), 'report.export')
    and exists (select 1 from public.admin_report_definitions d where d.id = definition_id and (d.created_by_user_id = auth.uid() or public.role_scope(auth.uid()) = 'GLOBAL'))
  );
create policy admin_report_runs_write on public.admin_report_runs for all to authenticated
  using (public.has_permission(auth.uid(), 'report.export'))
  with check (public.has_permission(auth.uid(), 'report.export'));

create policy admin_impersonation_read on public.admin_impersonation_sessions for select to authenticated
  using (public.has_permission(auth.uid(), 'impersonate.vendor') and admin_user_id = auth.uid());
create policy admin_impersonation_write on public.admin_impersonation_sessions for all to authenticated
  using (public.has_permission(auth.uid(), 'impersonate.vendor') and admin_user_id = auth.uid())
  with check (public.has_permission(auth.uid(), 'impersonate.vendor') and admin_user_id = auth.uid());

create policy admin_anomaly_read on public.admin_anomaly_alerts for select to authenticated
  using (public.has_permission(auth.uid(), 'dashboard.view'));
create policy admin_anomaly_write on public.admin_anomaly_alerts for all to authenticated
  using (public.has_permission(auth.uid(), 'dashboard.view'))
  with check (public.has_permission(auth.uid(), 'dashboard.view'));

create policy admin_dashboard_cache_read on public.admin_dashboard_cache for select to authenticated
  using (public.has_permission(auth.uid(), 'dashboard.view') and user_id = auth.uid());
create policy admin_dashboard_cache_write on public.admin_dashboard_cache for all to authenticated
  using (public.has_permission(auth.uid(), 'dashboard.view') and user_id = auth.uid())
  with check (public.has_permission(auth.uid(), 'dashboard.view') and user_id = auth.uid());

create or replace view public.admin_approval_queue
with (security_invoker = true)
as
select
  o.id,
  o.order_number,
  o.customer_id,
  c.business_name,
  c.current_balance_pkr,
  c.credit_limit_pkr,
  o.total_pkr,
  o.placed_at,
  o.placed_by_user_id,
  o.placed_via,
  coalesce((select count(*) from public.orders previous where previous.customer_id = o.customer_id and previous.id <> o.id and previous.status <> 'CANCELLED'), 0)::integer as previous_order_count
from public.orders o
join public.customers c on c.id = o.customer_id
where o.status = 'PENDING_APPROVAL'
  and public.has_permission(auth.uid(), 'order.approve')
  and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()));

create or replace function public.admin_dashboard_summary(p_range_start date default null, p_range_end date default null)
returns table(
  revenue_this_month numeric(12,2),
  revenue_last_month numeric(12,2),
  revenue_change_percent numeric(7,2),
  orders_this_month integer,
  quotes_pending integer,
  active_customers integer,
  outstanding_receivables numeric(12,2),
  orders_awaiting_approval integer
)
language sql stable security invoker set search_path = public
as $$
  with dates as (
    select coalesce(p_range_start, date_trunc('month', now() at time zone 'Asia/Karachi')::date) as start_date,
           coalesce(p_range_end, (now() at time zone 'Asia/Karachi')::date + 1) as end_date,
           date_trunc('month', now() at time zone 'Asia/Karachi')::date as this_start,
           (date_trunc('month', now() at time zone 'Asia/Karachi') - interval '1 month')::date as last_start,
           date_trunc('month', now() at time zone 'Asia/Karachi')::date as last_end
  ), scoped_customers as (
    select c.* from public.customers c
    where c.is_internal_account = false
      and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
  ), scoped_orders as (
    select o.* from public.orders o join scoped_customers c on c.id = o.customer_id
    where o.status <> 'CANCELLED'
  ), revenue as (
    select coalesce(sum(o.total_pkr) filter (where (o.placed_at at time zone 'Asia/Karachi')::date >= d.this_start), 0)::numeric(12,2) as this_month,
           coalesce(sum(o.total_pkr) filter (where (o.placed_at at time zone 'Asia/Karachi')::date >= d.last_start and (o.placed_at at time zone 'Asia/Karachi')::date < d.last_end), 0)::numeric(12,2) as last_month
    from scoped_orders o cross join dates d
  )
  select case when public.has_permission(auth.uid(), 'financials.view_revenue') then r.this_month else null end,
         case when public.has_permission(auth.uid(), 'financials.view_revenue') then r.last_month else null end,
         case when public.has_permission(auth.uid(), 'financials.view_revenue') and r.last_month <> 0 then round(((r.this_month-r.last_month)/r.last_month*100), 2)::numeric(7,2) else null end,
         (select count(*)::integer from scoped_orders o, dates d where (o.placed_at at time zone 'Asia/Karachi')::date >= d.this_start),
         (select count(*)::integer from public.quotes q join scoped_customers c on c.id = q.customer_id where q.status in ('REQUESTED','IN_REVIEW')),
         (select count(*)::integer from scoped_customers where status = 'ACTIVE'),
         case when public.has_permission(auth.uid(), 'ledger.view') then (select coalesce(sum(greatest(current_balance_pkr,0)),0)::numeric(12,2) from scoped_customers) else null end,
         (select count(*)::integer from public.orders o join scoped_customers c on c.id = o.customer_id where o.status = 'PENDING_APPROVAL')
  from revenue r;
$$;
grant execute on function public.admin_dashboard_summary(date,date) to authenticated;

create or replace function public.admin_dashboard_analytics(p_range_start date default null, p_range_end date default null)
returns jsonb
language plpgsql stable security invoker set search_path = public
as $$
declare
  start_date date := coalesce(p_range_start, ((now() at time zone 'Asia/Karachi')::date - interval '11 months')::date);
  end_date date := coalesce(p_range_end, (now() at time zone 'Asia/Karachi')::date + 1);
  result jsonb;
begin
  if not public.has_permission(auth.uid(), 'dashboard.view') then
    raise exception using errcode = '42501', message = 'Dashboard access is not permitted.';
  end if;
  select jsonb_build_object(
    'revenue_by_month', coalesce((select jsonb_agg(x order by x.month) from (
      select to_char(date_trunc('month', o.placed_at at time zone 'Asia/Karachi'), 'YYYY-MM') as month, sum(o.total_pkr)::numeric(12,2) as revenue_pkr
      from public.orders o join public.customers c on c.id=o.customer_id
      where public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by 1 order by 1
    ) x), '[]'::jsonb),
    'revenue_by_agent', coalesce((select jsonb_agg(x order by x.revenue_pkr desc) from (
      select coalesce(u.full_name,'Unassigned') as agent, sum(o.total_pkr)::numeric(12,2) as revenue_pkr
      from public.orders o join public.customers c on c.id=o.customer_id left join public.sales_agents sa on sa.id=c.assigned_agent_id left join public.users u on u.id=sa.user_id
      where public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by 1
    ) x), '[]'::jsonb),
    'revenue_by_category', coalesce((select jsonb_agg(x order by x.revenue_pkr desc) from (
      select cat.name_en as category, sum(ol.line_total_pkr)::numeric(12,2) as revenue_pkr
      from public.order_lines ol join public.orders o on o.id=ol.order_id join public.customers c on c.id=o.customer_id join public.products p on p.id=ol.product_id join public.categories cat on cat.id=p.category_id
      where public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by cat.name_en
    ) x), '[]'::jsonb),
    'revenue_by_brand', coalesce((select jsonb_agg(x order by x.revenue_pkr desc) from (
      select coalesce(b.name_en,'Unbranded') as brand, sum(ol.line_total_pkr)::numeric(12,2) as revenue_pkr
      from public.order_lines ol join public.orders o on o.id=ol.order_id join public.customers c on c.id=o.customer_id join public.products p on p.id=ol.product_id left join public.brands b on b.id=p.brand_id
      where public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by 1
    ) x), '[]'::jsonb),
    'orders_by_customer_type', coalesce((select jsonb_agg(x order by x.customer_type) from (
      select c.customer_type::text as customer_type, count(*)::integer as orders_count
      from public.orders o join public.customers c on c.id=o.customer_id
      where o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by c.customer_type
    ) x), '[]'::jsonb),
    'top_customers', coalesce((select jsonb_agg(x order by x.revenue_pkr desc) from (
      select c.business_name, sum(o.total_pkr)::numeric(12,2) as revenue_pkr
      from public.orders o join public.customers c on c.id=o.customer_id
      where public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= date_trunc('quarter', now() at time zone 'Asia/Karachi')::date
      group by c.id, c.business_name order by revenue_pkr desc limit 10
    ) x), '[]'::jsonb),
    'top_products', coalesce((select jsonb_agg(x order by x.units_sold desc) from (
      select p.name_en, p.sku, sum(ol.quantity)::numeric(12,3) as units_sold
      from public.order_lines ol join public.orders o on o.id=ol.order_id join public.customers c on c.id=o.customer_id join public.products p on p.id=ol.product_id
      where o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by p.id, p.name_en, p.sku order by units_sold desc limit 10
    ) x), '[]'::jsonb),
    'revenue_by_area', coalesce((select jsonb_agg(x order by x.revenue_pkr desc) from (
      select c.area_code, sum(o.total_pkr)::numeric(12,2) as revenue_pkr
      from public.orders o join public.customers c on c.id=o.customer_id
      where public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= start_date and (o.placed_at at time zone 'Asia/Karachi')::date < end_date
      group by c.area_code order by revenue_pkr desc limit 15
    ) x), '[]'::jsonb),
    'lead_funnel', coalesce((select jsonb_agg(x order by x.stage) from (select l.stage::text as stage, count(*)::integer as count from public.leads l where l.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) group by l.stage) x), '[]'::jsonb),
    'quote_conversion_by_agent', coalesce((select jsonb_agg(x order by x.agent) from (select coalesce(u.full_name,'Unassigned') as agent, count(*) filter (where q.status='CONVERTED')::integer as converted, count(*) filter (where q.status in ('CONVERTED','REJECTED','ACCEPTED'))::integer as responded from public.quotes q left join public.users u on u.id=q.assigned_to_user_id join public.customers c on c.id=q.customer_id where c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) group by 1) x), '[]'::jsonb),
    'activity_heatmap', coalesce((select jsonb_agg(x order by x.agent, x.day) from (select coalesce(u.full_name,'Unassigned') as agent, (a.occurred_at at time zone 'Asia/Karachi')::date as day, count(*) filter (where a.type='CALL')::integer as calls, count(*) filter (where a.type='VISIT')::integer as visits from public.activities a left join public.users u on u.id=a.agent_id where a.agent_id in (select public.accessible_agent_ids(auth.uid())) and (a.occurred_at at time zone 'Asia/Karachi')::date >= (now() at time zone 'Asia/Karachi')::date - 29 group by 1,2) x), '[]'::jsonb),
    'customer_map', coalesce((select jsonb_agg(x order by x.area_code, x.business_name) from (select c.business_name, c.area_code, c.latitude, c.longitude, case when max(o.placed_at) is null then 'RED' when (now() at time zone 'Asia/Karachi')::date - (max(o.placed_at) at time zone 'Asia/Karachi')::date > 90 then 'RED' when (now() at time zone 'Asia/Karachi')::date - (max(o.placed_at) at time zone 'Asia/Karachi')::date > 30 then 'AMBER' else 'GREEN' end as recency_band from public.customers c left join public.orders o on o.customer_id=c.id and o.status <> 'CANCELLED' where c.is_internal_account=false and c.latitude is not null and c.longitude is not null and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) group by c.id,c.business_name,c.area_code,c.latitude,c.longitude) x), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;
grant execute on function public.admin_dashboard_analytics(date,date) to authenticated;

create or replace function public.approve_admin_order(p_order_id uuid)
returns uuid language plpgsql security invoker set search_path = public as $$
declare v_customer_id uuid; order_total numeric(12,2); begin
  if not public.has_permission(auth.uid(),'order.approve') then raise exception using errcode='42501', message='Order approval is not permitted.'; end if;
  select o.customer_id,o.total_pkr into v_customer_id,order_total from public.orders o join public.customers c on c.id=o.customer_id where o.id=p_order_id and o.status='PENDING_APPROVAL' and (public.role_scope(auth.uid())='GLOBAL' or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))) for update of o;
  if not found then raise exception using errcode='42501', message='This order is outside your scope or is no longer awaiting approval.'; end if;
  update public.orders set status='CONFIRMED', approval_required=false, approved_by_user_id=auth.uid(), approved_at=now(), rejection_reason=null where id=p_order_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'APPROVE','ORDER',p_order_id::text,jsonb_build_object('status','CONFIRMED','total_pkr',order_total));
  insert into public.notifications(user_id,type,title_en,title_ur,body,link_url)
  select distinct x.user_id,'ORDER_APPROVED','Order approved','Order approved','Your order has been approved.','/en/vendor/orders/'||p_order_id::text from public.customer_users x where x.customer_id=v_customer_id;
  return p_order_id;
end; $$;
grant execute on function public.approve_admin_order(uuid) to authenticated;

create or replace function public.reject_admin_order(p_order_id uuid, p_reason text)
returns uuid language plpgsql security invoker set search_path = public as $$
declare v_customer_id uuid; begin
  if not public.has_permission(auth.uid(),'order.approve') then raise exception using errcode='42501', message='Order rejection is not permitted.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception using errcode='22023', message='A rejection reason is required.'; end if;
  select o.customer_id into v_customer_id from public.orders o join public.customers c on c.id=o.customer_id where o.id=p_order_id and o.status='PENDING_APPROVAL' and (public.role_scope(auth.uid())='GLOBAL' or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))) for update of o;
  if not found then raise exception using errcode='42501', message='This order is outside your scope or is no longer awaiting approval.'; end if;
  update public.orders set status='CANCELLED', approval_required=false, approved_by_user_id=auth.uid(), approved_at=now(), rejection_reason=trim(p_reason) where id=p_order_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'REJECT','ORDER',p_order_id::text,jsonb_build_object('status','CANCELLED','reason',trim(p_reason)));
  insert into public.notifications(user_id,type,title_en,title_ur,body,link_url)
  select distinct x.user_id,'ORDER_REJECTED','Order needs attention','Order needs attention','Your order was rejected: '||trim(p_reason),'/en/vendor/orders/'||p_order_id::text from public.customer_users x where x.customer_id=v_customer_id;
  return p_order_id;
end; $$;
grant execute on function public.reject_admin_order(uuid,text) to authenticated;

create or replace function public.record_admin_ledger_payment(p_customer_id uuid, p_amount_pkr numeric, p_reference text, p_description text, p_entry_date timestamptz default now())
returns uuid language plpgsql security invoker set search_path = public as $$
declare entry_id uuid; begin
  if not public.has_permission(auth.uid(),'ledger.record_payment') then raise exception using errcode='42501', message='Recording a payment is not permitted.'; end if;
  if p_amount_pkr <= 0 or nullif(trim(p_reference),'') is null or nullif(trim(p_description),'') is null then raise exception using errcode='22023', message='Enter a positive payment, reference, and description.'; end if;
  if not exists(select 1 from public.customers c where c.id=p_customer_id and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))) then raise exception using errcode='42501', message='This customer is outside your scope.'; end if;
  perform 1 from public.customers where id=p_customer_id for update;
  insert into public.ledger_entries(id,customer_id,type,amount_pkr,reference_number,description,entry_date,recorded_by_user_id) values(gen_random_uuid(),p_customer_id,'PAYMENT',(-abs(p_amount_pkr))::numeric(12,2),trim(p_reference),trim(p_description),p_entry_date,auth.uid()) returning id into entry_id;
  update public.customers set current_balance_pkr=(current_balance_pkr-abs(p_amount_pkr))::numeric(12,2), updated_at=now() where id=p_customer_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'RECORD_PAYMENT','LEDGER',entry_id::text,jsonb_build_object('customer_id',p_customer_id,'amount_pkr',(-abs(p_amount_pkr))::numeric(12,2)));
  return entry_id;
end; $$;
grant execute on function public.record_admin_ledger_payment(uuid,numeric,text,text,timestamptz) to authenticated;

create or replace function public.admin_receivables_ageing()
returns table(bucket text, customer_count integer, balance_pkr numeric(12,2)) language sql stable security invoker set search_path = public as $$
  with latest as (select c.id, greatest(0,c.current_balance_pkr)::numeric(12,2) balance, coalesce(max(l.entry_date),min(o.placed_at)) last_activity from public.customers c left join public.ledger_entries l on l.customer_id=c.id left join public.orders o on o.customer_id=c.id and o.status <> 'CANCELLED' where public.has_permission(auth.uid(),'ledger.view') and c.is_internal_account=false and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) group by c.id,c.current_balance_pkr)
  select bucket, count(*)::integer, coalesce(sum(balance),0)::numeric(12,2) from (select case when (now()-last_activity) <= interval '30 days' then '0-30' when (now()-last_activity) <= interval '60 days' then '31-60' when (now()-last_activity) <= interval '90 days' then '61-90' else '90+' end bucket, balance from latest where balance>0) x group by bucket order by case bucket when '0-30' then 1 when '31-60' then 2 when '61-90' then 3 else 4 end;
$$;
grant execute on function public.admin_receivables_ageing() to authenticated;

create or replace function public.start_admin_impersonation(p_mode text, p_target_user_id uuid default null, p_target_customer_id uuid default null)
returns uuid language plpgsql security invoker set search_path=public as $$
declare session_id uuid; begin
  if not public.has_permission(auth.uid(),'impersonate.vendor') then raise exception using errcode='42501', message='Impersonation is not permitted.'; end if;
  if p_mode not in ('ROLE_PREVIEW','VENDOR_IMPERSONATION') then raise exception using errcode='22023', message='Invalid preview mode.'; end if;
  if p_target_user_id is null and p_target_customer_id is null then raise exception using errcode='22023', message='Select a target before starting preview.'; end if;
  insert into public.admin_impersonation_sessions(admin_user_id,target_user_id,target_customer_id,mode,expires_at) values(auth.uid(),p_target_user_id,p_target_customer_id,p_mode,now()+interval '30 minutes') returning id into session_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'IMPERSONATION_START','ADMIN_IMPERSONATION',session_id::text,jsonb_build_object('target_user_id',p_target_user_id,'target_customer_id',p_target_customer_id,'mode',p_mode));
  return session_id;
end; $$;
grant execute on function public.start_admin_impersonation(text,uuid,uuid) to authenticated;

create or replace function public.end_admin_impersonation(p_session_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
begin
  if not public.has_permission(auth.uid(),'impersonate.vendor') then raise exception using errcode='42501', message='Impersonation is not permitted.'; end if;
  update public.admin_impersonation_sessions set ended_at=now() where id=p_session_id and admin_user_id=auth.uid() and ended_at is null;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'IMPERSONATION_END','ADMIN_IMPERSONATION',p_session_id::text,jsonb_build_object('ended_at',now()));
end; $$;
grant execute on function public.end_admin_impersonation(uuid) to authenticated;

create or replace function public.acknowledge_admin_anomaly(p_alert_id uuid, p_status text)
returns uuid language plpgsql security invoker set search_path=public as $$
begin
  if not public.has_permission(auth.uid(),'dashboard.view') then raise exception using errcode='42501', message='Anomaly review is not permitted.'; end if;
  if p_status not in ('ACKNOWLEDGED','RESOLVED') then raise exception using errcode='22023', message='Invalid anomaly status.'; end if;
  update public.admin_anomaly_alerts set status=p_status, acknowledged_by_user_id=auth.uid(), acknowledged_at=now() where id=p_alert_id;
  return p_alert_id;
end; $$;
grant execute on function public.acknowledge_admin_anomaly(uuid,text) to authenticated;

create or replace view public.admin_sales_team_metrics
with (security_invoker = true)
as
select
  sa.id as agent_id,
  u.full_name as agent_name,
  count(distinct o.id) filter (where o.status <> 'CANCELLED')::integer as orders_count,
  case when public.has_permission(auth.uid(),'financials.view_revenue') then coalesce(sum(o.total_pkr) filter (where o.status <> 'CANCELLED'),0)::numeric(12,2) else null end as revenue_pkr,
  count(distinct a.id)::integer as activities_count,
  count(distinct q.id)::integer as quoted_count,
  count(distinct q.id) filter (where q.status='CONVERTED')::integer as converted_quotes_count,
  case when count(distinct q.id) filter (where q.status in ('CONVERTED','REJECTED','ACCEPTED')) = 0 then 0::numeric(5,2) else round(100.0 * count(distinct q.id) filter (where q.status='CONVERTED') / count(distinct q.id) filter (where q.status in ('CONVERTED','REJECTED','ACCEPTED')),2)::numeric(5,2) end as quote_conversion_rate,
  sa.monthly_target_pkr,
  case when public.has_permission(auth.uid(),'financials.view_revenue') and sa.monthly_target_pkr > 0 then round(coalesce(sum(o.total_pkr) filter (where o.status <> 'CANCELLED' and date_trunc('month',o.placed_at at time zone 'Asia/Karachi') = date_trunc('month',now() at time zone 'Asia/Karachi')),0) / sa.monthly_target_pkr * 100,2)::numeric(7,2) else null end as target_progress_percent,
  count(distinct a.id) filter (where a.type='VISIT' and a.distance_from_customer_meters > 1000)::integer as visit_flags_count
from public.sales_agents sa
join public.users u on u.id=sa.user_id
left join public.customers c on c.assigned_agent_id=sa.id and c.is_internal_account=false
left join public.orders o on o.customer_id=c.id
left join public.activities a on a.agent_id=sa.user_id
left join public.quotes q on q.customer_id=c.id
where public.has_permission(auth.uid(),'dashboard.view')
  and sa.id in (select public.accessible_agent_ids(auth.uid()))
group by sa.id,u.full_name,sa.monthly_target_pkr;


create table public.admin_user_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  full_name text not null,
  phone text,
  role_id text not null references public.roles(id) on delete restrict,
  manager_id uuid references public.users(id) on delete set null,
  preferred_locale text not null default 'en' check (preferred_locale in ('en','ur')),
  status text not null default 'PENDING' check (status in ('PENDING','SENT','ACCEPTED','EXPIRED','CANCELLED')),
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz(6) not null default now(),
  expires_at timestamptz(6) not null default (now() + interval '7 days')
);
create index admin_user_invites_status_created_idx on public.admin_user_invites(status, created_at desc);
create index admin_user_invites_email_idx on public.admin_user_invites(email);
alter table public.admin_user_invites enable row level security;
create policy admin_user_invites_read on public.admin_user_invites for select to authenticated
  using (public.has_permission(auth.uid(),'user.view') and (created_by_user_id=auth.uid() or public.role_scope(auth.uid())='GLOBAL'));
create policy admin_user_invites_write on public.admin_user_invites for all to authenticated
  using (public.has_permission(auth.uid(),'user.create') and created_by_user_id=auth.uid())
  with check (public.has_permission(auth.uid(),'user.create') and created_by_user_id=auth.uid());

create or replace function public.queue_due_admin_reports()
returns integer language plpgsql security definer set search_path=public as $$
declare queued_count integer;
begin
  insert into public.admin_report_runs(definition_id,status)
  select d.id,'QUEUED' from public.admin_report_definitions d
  where d.is_active and d.schedule_cron is not null
    and not exists (select 1 from public.admin_report_runs r where r.definition_id=d.id and r.created_at >= now() - interval '23 hours');
  get diagnostics queued_count = row_count;
  return queued_count;
end; $$;
revoke all on function public.queue_due_admin_reports() from public, authenticated;
grant execute on function public.queue_due_admin_reports() to service_role;

create or replace function public.generate_admin_anomaly_alerts()
returns integer language plpgsql security definer set search_path=public as $$
declare alert_count integer; extra_count integer;
begin
  insert into public.admin_anomaly_alerts(alert_type,entity_id,title,body,supporting_metrics_json)
  select 'AGENT_ACTIVITY_DROP', sa.id, 'Sales activity dropped', u.full_name || ' recorded no activity in the last 7 business days.', jsonb_build_object('recent_activity_count',0,'comparison_window_days',30)
  from public.sales_agents sa join public.users u on u.id=sa.user_id
  where not exists (select 1 from public.activities a where a.agent_id=sa.user_id and a.occurred_at >= now()-interval '7 days')
    and exists (select 1 from public.activities a where a.agent_id=sa.user_id and a.occurred_at >= now()-interval '30 days' and a.occurred_at < now()-interval '7 days')
    and not exists (select 1 from public.admin_anomaly_alerts x where x.alert_type='AGENT_ACTIVITY_DROP' and x.entity_id=sa.id and x.created_at >= now()-interval '7 days');
  get diagnostics alert_count = row_count;
  insert into public.admin_anomaly_alerts(alert_type,entity_id,title,body,supporting_metrics_json)
  select 'CUSTOMER_ORDER_DROP', c.id, 'Customer order activity dropped', c.business_name || ' has no order in the last 30 days after ordering in the previous 30 days.', jsonb_build_object('recent_order_count',0,'comparison_window_days',30)
  from public.customers c
  where not c.is_internal_account
    and c.assigned_agent_id is not null
    and not exists (select 1 from public.orders o where o.customer_id=c.id and o.status <> 'CANCELLED' and o.placed_at >= now()-interval '30 days')
    and exists (select 1 from public.orders o where o.customer_id=c.id and o.status <> 'CANCELLED' and o.placed_at >= now()-interval '60 days' and o.placed_at < now()-interval '30 days')
    and not exists (select 1 from public.admin_anomaly_alerts x where x.alert_type='CUSTOMER_ORDER_DROP' and x.entity_id=c.id and x.created_at >= now()-interval '7 days');
  get diagnostics extra_count = row_count;
  alert_count := alert_count + extra_count;
  return alert_count;
end; $$;
revoke all on function public.generate_admin_anomaly_alerts() from public, authenticated;
grant execute on function public.generate_admin_anomaly_alerts() to service_role;

create or replace function public.admin_customers_stopped_ordering(p_area_code text, p_days integer default 60)
returns table(customer_id uuid, business_name text, area_code text, last_order_at timestamptz, previous_order_count integer)
language sql stable security invoker set search_path=public as $$
  with scoped as (
    select c.id,c.business_name,c.area_code,max(o.placed_at) filter (where o.status <> 'CANCELLED') as last_order_at,count(o.id) filter (where o.status <> 'CANCELLED' and o.placed_at >= now()-interval '180 days')::integer as recent_count
    from public.customers c left join public.orders o on o.customer_id=c.id
    where public.has_permission(auth.uid(),'ai.analytics') and not c.is_internal_account and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (nullif(trim(p_area_code),'') is null or c.area_code ilike trim(p_area_code))
    group by c.id,c.business_name,c.area_code
  )
  select id,business_name,area_code,last_order_at,recent_count from scoped where last_order_at is not null and last_order_at < now() - make_interval(days => greatest(1,least(p_days,365))) and recent_count > 0 order by last_order_at asc limit 100;
$$;
grant execute on function public.admin_customers_stopped_ordering(text,integer) to authenticated;

create or replace function public.admin_brand_revenue_comparison(p_brand_a text, p_brand_b text)
returns table(brand text, revenue_pkr numeric(12,2), orders_count integer)
language sql stable security invoker set search_path=public as $$
  select b.name_en, coalesce(sum(ol.line_total_pkr),0)::numeric(12,2), count(distinct o.id)::integer
  from public.brands b join public.products p on p.brand_id=b.id join public.order_lines ol on ol.product_id=p.id join public.orders o on o.id=ol.order_id join public.customers c on c.id=o.customer_id
  where public.has_permission(auth.uid(),'ai.analytics') and public.has_permission(auth.uid(),'financials.view_revenue') and o.status <> 'CANCELLED' and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and (o.placed_at at time zone 'Asia/Karachi')::date >= date_trunc('quarter',now() at time zone 'Asia/Karachi')::date and (b.name_en ilike trim(p_brand_a) or b.name_en ilike trim(p_brand_b))
  group by b.name_en order by b.name_en;
$$;
grant execute on function public.admin_brand_revenue_comparison(text,text) to authenticated;

create or replace function public.admin_permission_risks()
returns table(risk_type text, subject text, detail text, severity text)
language sql stable security invoker set search_path=public as $$
  select 'SENSITIVE_BROAD', p.key, count(distinct u.id)::text || ' active user(s) hold this sensitive permission.', 'HIGH'
  from public.permissions p join public.role_permissions rp on rp.permission_id=p.id join public.roles r on r.id=rp.role_id join public.users u on u.role_id=r.id
  where public.has_permission(auth.uid(),'role.view') and p.is_sensitive and u.is_active
  group by p.key having count(distinct u.id) >= 3
  union all
  select 'INACTIVE_SENSITIVE_USER', u.email, 'Inactive for more than 90 days while retaining a sensitive permission.', 'HIGH'
  from public.users u join public.roles r on r.id=u.role_id join public.role_permissions rp on rp.role_id=r.id join public.permissions p on p.id=rp.permission_id
  where public.has_permission(auth.uid(),'role.view') and p.is_sensitive and u.is_active=false and coalesce(u.last_login_at,u.created_at) < now()-interval '90 days'
  group by u.id,u.email
  union all
  select 'NEAR_IDENTICAL_ROLES', string_agg(r.name, ' / ' order by r.name), 'Roles share the same scope, portal, and permission set.', 'MEDIUM'
  from public.roles r join public.role_permissions rp on rp.role_id=r.id
  where public.has_permission(auth.uid(),'role.view')
  group by r.data_scope,r.portal_access,(select array_agg(rp2.permission_id order by rp2.permission_id) from public.role_permissions rp2 where rp2.role_id=r.id)
  having count(distinct r.id) > 1;
$$;
grant execute on function public.admin_permission_risks() to authenticated;
