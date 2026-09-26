-- Performance pass + data for the new Admin console.
-- 1. Index every foreign key that has no covering index (joins and RLS EXISTS checks).
-- 2. RLS policies call has_permission(auth.uid(), ...) / role_scope(auth.uid()) once per ROW.
--    Wrapping them in a scalar sub-select makes Postgres run them once per QUERY (initPlan).
--    Same logic, same result; only the evaluation count changes.
-- 3. current_user_context(): the signed-in user's portal, role and permission keys in one call
--    (the app used 4 sequential round trips for this on every page).
-- 4. admin_ops_summary() / admin_nav_badges(): the Admin overview in one SQL call instead of
--    downloading customers and orders to the web server.

-- 1. Foreign-key indexes -------------------------------------------------------------------
do $$
declare r record; idx text;
begin
  for r in
    select c.conrelid::regclass as tbl, c.conrelid, c.conkey,
           string_agg(quote_ident(a.attname), ', ' order by k.ord) as cols,
           string_agg(a.attname, '_' order by k.ord) as colnames,
           (select relname from pg_class where oid = c.conrelid) as relname
    from pg_constraint c
    join lateral unnest(c.conkey) with ordinality k(attnum, ord) on true
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
    where c.contype = 'f' and c.connamespace = 'public'::regnamespace
      and not exists (
        select 1 from pg_index i
        where i.indrelid = c.conrelid
          and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey::int2[]
          and c.conkey::int2[] @> (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1]
      )
    group by c.oid, c.conrelid, c.conkey
  loop
    idx := left(r.relname || '_' || r.colnames, 55) || '_fkx';
    execute format('create index if not exists %I on %s (%s)', idx, r.tbl, r.cols);
  end loop;
end $$;

-- Hot filters used by dashboards, queues and recovery screens.
create index if not exists orders_status_placed_at_idx on public.orders (status, placed_at desc);
create index if not exists orders_placed_at_idx on public.orders (placed_at desc);
create index if not exists payment_collections_status_collected_idx on public.payment_collections (status, collected_at desc);
create index if not exists payment_collections_collected_at_idx on public.payment_collections (collected_at desc);
create index if not exists beat_visits_agent_date_idx on public.beat_visits (agent_id, planned_date);
create index if not exists delivery_runs_run_date_idx on public.delivery_runs (run_date desc);
create index if not exists customers_business_name_idx on public.customers (business_name);
create index if not exists customers_internal_agent_idx on public.customers (is_internal_account, assigned_agent_id);
create index if not exists notifications_user_read_idx on public.notifications (user_id, created_at desc);

-- 2. RLS: evaluate permission helpers once per statement ------------------------------------
do $$
declare
  p record; q text; w text; nq text; nw text; cmd text;
begin
  for p in select schemaname, tablename, policyname, qual, with_check from pg_policies where schemaname = 'public' loop
    q := p.qual; w := p.with_check;
    nq := q; nw := w;
    if nq is not null then
      nq := regexp_replace(nq, 'has_permission\(auth\.uid\(\), (''[a-z_.]+''::text)\)', '(SELECT has_permission(auth.uid(), \1))', 'g');
      nq := regexp_replace(nq, 'role_scope\(auth\.uid\(\)\)', '(SELECT role_scope(auth.uid()))', 'g');
      nq := regexp_replace(nq, 'vendor_customer_for_user\(auth\.uid\(\)\)', '(SELECT vendor_customer_for_user(auth.uid()))', 'g');
      nq := regexp_replace(nq, 'is_vendor_portal_user\(\)', '(SELECT is_vendor_portal_user())', 'g');
    end if;
    if nw is not null then
      nw := regexp_replace(nw, 'has_permission\(auth\.uid\(\), (''[a-z_.]+''::text)\)', '(SELECT has_permission(auth.uid(), \1))', 'g');
      nw := regexp_replace(nw, 'role_scope\(auth\.uid\(\)\)', '(SELECT role_scope(auth.uid()))', 'g');
      nw := regexp_replace(nw, 'vendor_customer_for_user\(auth\.uid\(\)\)', '(SELECT vendor_customer_for_user(auth.uid()))', 'g');
      nw := regexp_replace(nw, 'is_vendor_portal_user\(\)', '(SELECT is_vendor_portal_user())', 'g');
    end if;
    if nq is distinct from q or nw is distinct from w then
      cmd := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
      if nq is not null then cmd := cmd || format(' using (%s)', nq); end if;
      if nw is not null then cmd := cmd || format(' with check (%s)', nw); end if;
      execute cmd;
    end if;
  end loop;
end $$;

-- 3. Signed-in user context -----------------------------------------------------------------
create or replace function public.current_user_context()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'user_id', u.id,
    'email', u.email,
    'full_name', u.full_name,
    'is_active', u.is_active,
    'role_name', r.name,
    'role_active', r.is_active,
    'portal', lower(r.portal_access::text),
    'data_scope', r.data_scope::text,
    'permissions', coalesce((
      select jsonb_agg(distinct pm.key order by pm.key)
      from public.role_permissions rp join public.permissions pm on pm.id = rp.permission_id
      where rp.role_id = r.id and u.is_active and r.is_active
    ), '[]'::jsonb)
  )
  from public.users u
  left join public.roles r on r.id = u.role_id
  where u.id = auth.uid();
$$;
revoke all on function public.current_user_context() from public, anon;
grant execute on function public.current_user_context() to authenticated, service_role;

-- 4. Admin overview ------------------------------------------------------------------------
-- Customers in the caller's data scope (GLOBAL sees every customer, including unassigned).
create or replace function public.admin_scope_customer_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select c.id from public.customers c
  where (select public.role_scope(auth.uid())) = 'GLOBAL'
     or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()));
$$;
revoke all on function public.admin_scope_customer_ids() from public, anon;
grant execute on function public.admin_scope_customer_ids() to authenticated, service_role;

create or replace function public.admin_ops_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  can_rev boolean;
  can_ledger boolean;
  can_coll boolean;
  today date := (now() at time zone 'Asia/Karachi')::date;
  m0 date := date_trunc('month', (now() at time zone 'Asia/Karachi'))::date;
  m_prev date := (date_trunc('month', (now() at time zone 'Asia/Karachi')) - interval '1 month')::date;
  m_first date := (date_trunc('month', (now() at time zone 'Asia/Karachi')) - interval '5 months')::date;
  t0 timestamptz := (date_trunc('month', (now() at time zone 'Asia/Karachi')) at time zone 'Asia/Karachi');
  result jsonb;
begin
  if uid is null or not public.has_permission(uid, 'dashboard.view') then
    raise exception 'Missing permission: dashboard.view' using errcode = '42501';
  end if;
  can_rev := public.has_permission(uid, 'financials.view_revenue');
  can_ledger := public.has_permission(uid, 'ledger.view');
  can_coll := public.has_permission(uid, 'collection.view');

  with
  scope as materialized (select public.admin_scope_customer_ids() as id),
  cust as (
    select c.* from public.customers c join scope s on s.id = c.id
  ),
  ord as (
    select o.*, (o.placed_at at time zone 'Asia/Karachi')::date as placed_day
    from public.orders o join scope s on s.id = o.customer_id
    where o.placed_at >= (m_first::timestamp at time zone 'Asia/Karachi')
  ),
  rev as (
    select * from ord where status in ('PLACED','CONFIRMED','PICKED','DISPATCHED','DELIVERED')
  ),
  pending as (
    select o.id, o.total_pkr, c.current_balance_pkr, c.credit_limit_pkr
    from public.orders o join cust c on c.id = o.customer_id
    where o.status = 'PENDING_APPROVAL'
  ),
  pay as (
    select pc.customer_id, max(pc.cleared_at) filter (where pc.status = 'CLEARED') as last_paid
    from public.payment_collections pc join scope s on s.id = pc.customer_id group by pc.customer_id
  ),
  last_order as (
    select o.customer_id, max(o.placed_at) as last_at
    from public.orders o join scope s on s.id = o.customer_id
    where o.status <> 'CANCELLED' group by o.customer_id
  ),
  owing as (
    select c.id, c.business_name, c.area_code, c.assigned_agent_id, greatest(c.current_balance_pkr, 0) as bal,
      greatest(0, today - coalesce(p.last_paid::date, lo.last_at::date, today)) as age
    from cust c left join pay p on p.customer_id = c.id left join last_order lo on lo.customer_id = c.id
    where not c.is_internal_account and c.current_balance_pkr > 0
  ),
  coll as (
    select pc.* from public.payment_collections pc join scope s on s.id = pc.customer_id
  ),
  agent_names as (
    select sa.id, coalesce(nullif(u.full_name, ''), sa.agent_code) as name, sa.territory
    from public.sales_agents sa left join public.users u on u.id = sa.user_id
    where sa.id in (select public.accessible_agent_ids(uid))
  ),
  visits as (
    select bv.agent_id, count(*) as planned, count(*) filter (where bv.status = 'VISITED') as done
    from public.beat_visits bv where bv.planned_date >= m0 and bv.planned_date < (m0 + interval '1 month')::date
    group by bv.agent_id
  )
  select jsonb_build_object(
    'can', jsonb_build_object('revenue', can_rev, 'ledger', can_ledger, 'collections', can_coll),
    'revenueMtd', case when can_rev then (select coalesce(sum(total_pkr), 0) from rev where placed_day >= m0) end,
    'revenuePrevMonth', case when can_rev then (select coalesce(sum(total_pkr), 0) from rev where placed_day >= m_prev and placed_day < m0) end,
    'ordersMtd', (select count(*) from rev where placed_day >= m0),
    'ordersPrevMonth', (select count(*) from rev where placed_day >= m_prev and placed_day < m0),
    'pendingApprovals', jsonb_build_object(
      'count', (select count(*) from pending),
      'amount', (select coalesce(sum(total_pkr), 0) from pending),
      'overLimit', (select count(*) from pending where credit_limit_pkr > 0 and current_balance_pkr + total_pkr > credit_limit_pkr)),
    'activeCustomers', (select count(distinct customer_id) from rev where placed_day >= m0),
    'receivables', case when can_ledger then (select coalesce(sum(bal), 0) from owing) end,
    'ageing', case when can_ledger then coalesce((
      select jsonb_agg(jsonb_build_object('bucket', b, 'amount', amt, 'customers', n) order by ord)
      from (
        select case when age <= 30 then '0_30' when age <= 60 then '31_60' when age <= 90 then '61_90' else '90_plus' end as b,
               min(case when age <= 30 then 1 when age <= 60 then 2 when age <= 90 then 3 else 4 end) as ord,
               sum(bal) as amt, count(*) as n
        from owing group by 1
      ) x), '[]'::jsonb) else '[]'::jsonb end,
    'topOverdue', case when can_ledger then coalesce((
      select jsonb_agg(jsonb_build_object('customerId', o.id, 'name', o.business_name, 'area', o.area_code, 'agentName', an.name, 'amount', o.bal, 'daysOverdue', o.age) order by o.age desc, o.bal desc)
      from (select * from owing order by age desc, bal desc limit 6) o left join agent_names an on an.id = o.assigned_agent_id
    ), '[]'::jsonb) else '[]'::jsonb end,
    'collectedMtd', case when can_coll then (select coalesce(sum(amount_pkr), 0) from coll where collected_at >= t0 and status not in ('BOUNCED','CANCELLED')) end,
    'collectionTarget', case when can_coll then (select sum(rt.target_amount_pkr) from public.recovery_targets rt where rt.month = m0 and rt.agent_id in (select id from agent_names)) end,
    'pendingDeposits', jsonb_build_object(
      'count', case when can_coll then (select count(*) from coll where status = 'COLLECTED') else 0 end,
      'amount', case when can_coll then (select coalesce(sum(amount_pkr), 0) from coll where status = 'COLLECTED') else 0 end),
    'bouncedCheques', jsonb_build_object(
      'count', case when can_coll then (select count(*) from coll where status = 'BOUNCED' and collected_at >= now() - interval '90 days') else 0 end,
      'amount', case when can_coll then (select coalesce(sum(amount_pkr), 0) from coll where status = 'BOUNCED' and collected_at >= now() - interval '90 days') else 0 end),
    'delivery', jsonb_build_object(
      'confirmed', (select count(*) from public.orders o join scope s on s.id = o.customer_id where o.status = 'CONFIRMED'),
      'picked', (select count(*) from public.orders o join scope s on s.id = o.customer_id where o.status = 'PICKED'),
      'dispatched', (select count(*) from public.orders o join scope s on s.id = o.customer_id where o.status = 'DISPATCHED'),
      'deliveredToday', (select count(*) from public.orders o join scope s on s.id = o.customer_id where o.status = 'DELIVERED' and (o.delivered_at at time zone 'Asia/Karachi')::date = today),
      'failedToday', (select count(*) from public.delivery_stops ds join scope s on s.id = ds.customer_id join public.delivery_runs dr on dr.id = ds.run_id where ds.status = 'FAILED' and dr.run_date = today),
      'delayedRuns', (select count(*) from public.delivery_runs dr where dr.run_date < today and dr.status in ('PLANNED','LOADED','IN_TRANSIT'))),
    'deliveredMtd', (select count(*) from rev where placed_day >= m0 and status = 'DELIVERED'),
    'revenueByMonth', case when can_rev then (
      select jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'value', coalesce((select sum(total_pkr) from rev where date_trunc('month', placed_day) = m), 0)) order by m)
      from generate_series(m_first::timestamp, m0::timestamp, interval '1 month') m
    ) else '[]'::jsonb end,
    'revenueByCategory', case when can_rev then coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'nameUr', name_ur, 'value', value) order by value desc)
      from (
        select coalesce(cat.name_en, '—') as name, cat.name_ur, sum(ol.line_total_pkr) as value
        from rev o join public.order_lines ol on ol.order_id = o.id
        join public.products p on p.id = ol.product_id left join public.categories cat on cat.id = p.category_id
        where o.placed_day >= m0 group by 1, 2 order by 3 desc limit 8
      ) x), '[]'::jsonb) else '[]'::jsonb end,
    'topCustomers', case when can_rev then coalesce((
      select jsonb_agg(jsonb_build_object('name', c.business_name, 'area', c.area_code, 'value', x.value) order by x.value desc)
      from (select customer_id, sum(total_pkr) as value from rev where placed_day >= m0 group by 1 order by 2 desc limit 5) x
      join cust c on c.id = x.customer_id), '[]'::jsonb) else '[]'::jsonb end,
    'agents', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', an.id, 'name', an.name, 'beatLabel', an.territory,
        'revenue', case when can_rev then (select coalesce(sum(r.total_pkr), 0) from rev r join cust c on c.id = r.customer_id where c.assigned_agent_id = an.id and r.placed_day >= m0) else 0 end,
        'orders', (select count(*) from rev r join cust c on c.id = r.customer_id where c.assigned_agent_id = an.id and r.placed_day >= m0),
        'visitsPlanned', coalesce(v.planned, 0), 'visitsDone', coalesce(v.done, 0),
        'collected', case when can_coll then (select coalesce(sum(amount_pkr), 0) from coll where agent_id = an.id and collected_at >= t0 and status not in ('BOUNCED','CANCELLED')) else 0 end,
        'collectionTarget', coalesce((select target_amount_pkr from public.recovery_targets rt where rt.agent_id = an.id and rt.month = m0), 0),
        'customers', (select count(*) from cust c where c.assigned_agent_id = an.id),
        'profilesComplete', (select case when count(*) = 0 then 0 else round(100.0 * count(*) filter (where c.data_complete) / count(*)) end from cust c where c.assigned_agent_id = an.id)
      ) order by an.name)
      from agent_names an left join visits v on v.agent_id = an.id), '[]'::jsonb),
    'dataHealth', (
      select jsonb_build_object(
        'totalRecords', count(*),
        'dealerCount', count(*) filter (where not is_internal_account),
        'internalCount', count(*) filter (where is_internal_account),
        'completeProfiles', count(*) filter (where not is_internal_account and data_complete),
        'withAgent', count(*) filter (where not is_internal_account and assigned_agent_id is not null),
        'noArea', count(*) filter (where not is_internal_account and (area_code is null or area_code !~ '[A-Za-z0-9]' or area_code not in (select code from public.area_codes))),
        'typeOther', count(*) filter (where not is_internal_account and customer_type = 'OTHER'),
        'typeSuggestions', count(*) filter (where not is_internal_account and customer_type = 'OTHER' and customer_type_suggestion is not null and customer_type_suggestion <> 'OTHER'),
        'duplicatesFlagged', count(*) filter (where duplicate_review_required))
      from cust)
  ) into result;
  return result;
end;
$$;
revoke all on function public.admin_ops_summary() from public, anon;
grant execute on function public.admin_ops_summary() to authenticated, service_role;

-- Sidebar counters: cheap counts only.
create or replace function public.admin_nav_badges()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with s as (select public.admin_scope_customer_ids() as id)
  select jsonb_build_object(
    'approvals', case when (select public.has_permission(auth.uid(), 'order.approve'))
      then (select count(*) from public.orders o join s on s.id = o.customer_id where o.status = 'PENDING_APPROVAL') else 0 end,
    'recovery', case when (select public.has_permission(auth.uid(), 'collection.view'))
      then (select count(*) from public.payment_collections pc join s on s.id = pc.customer_id where pc.status = 'BOUNCED' and pc.collected_at >= now() - interval '90 days') else 0 end,
    'enrichment', case when (select public.has_permission(auth.uid(), 'customer.view'))
      then (select count(*) from public.customers c join s on s.id = c.id where not c.is_internal_account and not c.data_complete) else 0 end
  );
$$;
revoke all on function public.admin_nav_badges() from public, anon;
grant execute on function public.admin_nav_badges() to authenticated, service_role;

-- Bulk customer maintenance used by the Admin customers table (checks the same permissions
-- as the single-row actions and writes one audit row per call).
create or replace function public.admin_bulk_update_customers(p_customer_ids uuid[], p_agent_id uuid default null, p_unassign boolean default false, p_customer_type text default null, p_accept_suggestion boolean default false)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer := 0;
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_customer_ids is null or cardinality(p_customer_ids) = 0 then return 0; end if;
  if cardinality(p_customer_ids) > 500 then raise exception 'Too many customers' using errcode = '22023'; end if;

  if p_agent_id is not null or p_unassign then
    if not public.has_permission(auth.uid(), 'customer.reassign_agent') then raise exception 'Missing permission: customer.reassign_agent' using errcode = '42501'; end if;
    if p_agent_id is not null and not exists (select 1 from public.sales_agents where id = p_agent_id) then raise exception 'Unknown Sales Agent' using errcode = '22023'; end if;
    update public.customers c set assigned_agent_id = case when p_unassign then null else p_agent_id end, updated_at = now()
    where c.id = any(p_customer_ids) and c.id in (select public.admin_scope_customer_ids());
    get diagnostics n = row_count;
  elsif p_customer_type is not null or p_accept_suggestion then
    if not (public.has_permission(auth.uid(), 'customer.update') or public.has_permission(auth.uid(), 'customer.enrich')) then
      raise exception 'Missing permission: customer.update' using errcode = '42501';
    end if;
    update public.customers c
    set customer_type = case when p_accept_suggestion then coalesce(nullif(c.customer_type_suggestion::text, 'OTHER'), c.customer_type::text)::"CustomerType" else p_customer_type::"CustomerType" end,
        updated_at = now()
    where c.id = any(p_customer_ids) and c.id in (select public.admin_scope_customer_ids());
    get diagnostics n = row_count;
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, changes_json)
  values (auth.uid(), 'BULK_UPDATE', 'CUSTOMER', 'bulk',
          jsonb_build_object('customer_ids', to_jsonb(p_customer_ids), 'agent_id', p_agent_id, 'unassign', p_unassign, 'customer_type', p_customer_type, 'accept_suggestion', p_accept_suggestion, 'updated', n));
  return n;
end;
$$;
revoke all on function public.admin_bulk_update_customers(uuid[], uuid, boolean, text, boolean) from public, anon;
grant execute on function public.admin_bulk_update_customers(uuid[], uuid, boolean, text, boolean) to authenticated, service_role;
