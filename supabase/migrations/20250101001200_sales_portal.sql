-- AKAI CRM Sales portal phase.
-- Additive migration only. Never edit migrations 0001-0011.
-- All timestamps remain UTC timestamptz; business-day expressions use Asia/Karachi.

alter table public.leads
  add column "normalized_name" text,
  add column "stage_entered_at" timestamptz(6) not null default now();

update public.leads
set
  "normalized_name" = upper(regexp_replace(trim(regexp_replace("business_name", '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')),
  "stage_entered_at" = coalesce("updated_at", "created_at", now())
where "normalized_name" is null;

alter table public.leads alter column "normalized_name" set not null;
alter table public.leads add constraint "leads_normalized_name_nonempty_check" check (length("normalized_name") > 0);
alter table public.leads add constraint "leads_phone_e164_check" check ("phone" ~ '^\\+92[0-9]{10}$');

create index "leads_assigned_agent_stage_entered_at_idx" on public.leads ("assigned_agent_id", "stage", "stage_entered_at");
create index "leads_phone_idx" on public.leads ("phone");
create index "leads_normalized_name_idx" on public.leads ("normalized_name");
create index "leads_import_batch_id_idx" on public.leads ("import_batch_id");

create table public.lead_import_batches (
  "id" text primary key,
  "created_by_user_id" uuid not null references public.users("id") on delete restrict,
  "assigned_agent_id" uuid not null references public.sales_agents("id") on delete restrict,
  "source_filename" text,
  "row_count" integer not null default 0,
  "created_at" timestamptz(6) not null default now(),
  "rolled_back_at" timestamptz(6),
  "status" text not null default 'ACTIVE',
  constraint "lead_import_batches_row_count_nonnegative_check" check ("row_count" >= 0),
  constraint "lead_import_batches_status_check" check ("status" in ('ACTIVE', 'ROLLED_BACK'))
);
create index "lead_import_batches_created_by_status_idx" on public.lead_import_batches ("created_by_user_id", "status", "created_at");
create index "lead_import_batches_agent_created_at_idx" on public.lead_import_batches ("assigned_agent_id", "created_at");

alter table public.leads
  add constraint "leads_import_batch_id_fkey" foreign key ("import_batch_id") references public.lead_import_batches("id") on delete set null;

create table public.calendar_feed_tokens (
  "id" uuid primary key default gen_random_uuid(),
  "sales_agent_id" uuid not null references public.sales_agents("id") on delete cascade,
  "token_hash" text not null unique,
  "created_at" timestamptz(6) not null default now(),
  "last_used_at" timestamptz(6),
  "revoked_at" timestamptz(6)
);
create index "calendar_feed_tokens_agent_revoked_idx" on public.calendar_feed_tokens ("sales_agent_id", "revoked_at");

alter table public.customers enable row level security;
alter table public.lead_import_batches enable row level security;
alter table public.calendar_feed_tokens enable row level security;

create policy lead_import_batches_read on public.lead_import_batches for select to authenticated
  using (
    public.has_permission(auth.uid(), 'lead.import')
    and (public.role_scope(auth.uid()) = 'GLOBAL' or "assigned_agent_id" in (select public.accessible_agent_ids(auth.uid())))
  );
create policy lead_import_batches_insert on public.lead_import_batches for insert to authenticated
  with check (
    public.has_permission(auth.uid(), 'lead.import')
    and "created_by_user_id" = auth.uid()
    and "assigned_agent_id" in (select public.accessible_agent_ids(auth.uid()))
  );
create policy lead_import_batches_update on public.lead_import_batches for update to authenticated
  using (
    public.has_permission(auth.uid(), 'lead.import')
    and "created_by_user_id" = auth.uid()
    and "assigned_agent_id" in (select public.accessible_agent_ids(auth.uid()))
  )
  with check (
    public.has_permission(auth.uid(), 'lead.import')
    and "created_by_user_id" = auth.uid()
    and "assigned_agent_id" in (select public.accessible_agent_ids(auth.uid()))
  );
create policy lead_import_batches_delete on public.lead_import_batches for delete to authenticated
  using (public.has_permission(auth.uid(), 'lead.import') and "created_by_user_id" = auth.uid());

create policy leads_import_rollback_delete on public.leads for delete to authenticated
  using (
    public.has_permission(auth.uid(), 'lead.import')
    and "import_batch_id" is not null
    and exists (
      select 1 from public.lead_import_batches b
      where b.id = leads."import_batch_id"
        and b.created_by_user_id = auth.uid()
        and b.status = 'ACTIVE'
    )
    and "assigned_agent_id" in (select public.accessible_agent_ids(auth.uid()))
  );

create policy calendar_feed_tokens_read on public.calendar_feed_tokens for select to authenticated
  using (
    public.has_permission(auth.uid(), 'followup.view')
    and "sales_agent_id" in (select id from public.sales_agents where user_id = auth.uid())
  );
create policy calendar_feed_tokens_insert on public.calendar_feed_tokens for insert to authenticated
  with check (
    public.has_permission(auth.uid(), 'followup.view')
    and "sales_agent_id" in (select id from public.sales_agents where user_id = auth.uid())
  );
create policy calendar_feed_tokens_update on public.calendar_feed_tokens for update to authenticated
  using (
    public.has_permission(auth.uid(), 'followup.view')
    and "sales_agent_id" in (select id from public.sales_agents where user_id = auth.uid())
  )
  with check (
    public.has_permission(auth.uid(), 'followup.view')
    and "sales_agent_id" in (select id from public.sales_agents where user_id = auth.uid())
  );

create or replace function public.enforce_lead_lifecycle()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.stage_entered_at := coalesce(new.stage_entered_at, now());
    if new.stage = 'LOST' and nullif(trim(new.lost_reason), '') is null then
      raise exception using errcode = '22023', message = 'A lost reason is required.';
    end if;
    if new.stage = 'WON' and new.converted_customer_id is null then
      raise exception using errcode = '22023', message = 'A won lead must link a customer.';
    end if;
    return new;
  end if;

  if new.stage is distinct from old.stage then
    new.stage_entered_at := now();
    if new.stage = 'LOST' and nullif(trim(new.lost_reason), '') is null then
      raise exception using errcode = '22023', message = 'A lost reason is required.';
    end if;
    if new.stage = 'WON' and new.converted_customer_id is null then
      raise exception using errcode = '22023', message = 'Convert the lead to a customer before marking it won.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists leads_lifecycle_trigger on public.leads;
create trigger leads_lifecycle_trigger
before insert or update of "stage", "lost_reason", "converted_customer_id" on public.leads
for each row execute function public.enforce_lead_lifecycle();

create or replace function public.convert_lead_to_customer(p_lead_id uuid, p_customer_type "CustomerType" default 'OTHER')
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  lead_row record;
  customer_id uuid := gen_random_uuid();
  default_group_id uuid;
begin
  if not public.has_permission(auth.uid(), 'lead.update') or not public.has_permission(auth.uid(), 'customer.create') then
    raise exception using errcode = '42501', message = 'Lead conversion is not permitted.';
  end if;

  select * into lead_row
  from public.leads
  where id = p_lead_id
    and assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'This lead is outside your data scope.';
  end if;
  if lead_row.converted_customer_id is not null then
    return lead_row.converted_customer_id;
  end if;
  if lead_row.stage = 'LOST' then
    raise exception using errcode = '22023', message = 'A lost lead cannot be converted.';
  end if;

  select id into default_group_id from public.vendor_groups where is_default = true limit 1;
  if default_group_id is null then
    raise exception using errcode = '22023', message = 'The default VendorGroup is not configured.';
  end if;

  insert into public.customers (
    id, name, business_name, area_code, normalized_name, primary_phone,
    full_address, customer_type, vendor_group_id, assigned_agent_id,
    credit_limit_pkr, current_balance_pkr, loyalty_points_balance, status,
    data_complete, is_internal_account
  ) values (
    customer_id, lead_row.business_name, lead_row.business_name, lead_row.area_code,
    lead_row.normalized_name, lead_row.phone, lead_row.full_address, p_customer_type,
    default_group_id, lead_row.assigned_agent_id, 0, 0, 0, 'ACTIVE', false, false
  );

  update public.leads
  set converted_customer_id = customer_id, stage = 'WON', updated_at = now()
  where id = p_lead_id;

  return customer_id;
end;
$$;
grant execute on function public.convert_lead_to_customer(uuid, "CustomerType") to authenticated;

create or replace function public.rollback_lead_import(p_batch_id text)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  deleted_count integer;
begin
  if not public.has_permission(auth.uid(), 'lead.import') then
    raise exception using errcode = '42501', message = 'Lead import rollback is not permitted.';
  end if;

  if not exists (
    select 1 from public.lead_import_batches
    where id = p_batch_id and created_by_user_id = auth.uid() and status = 'ACTIVE'
  ) then
    raise exception using errcode = '22023', message = 'This import batch cannot be rolled back.';
  end if;

  delete from public.leads
  where import_batch_id = p_batch_id
    and assigned_agent_id in (select public.accessible_agent_ids(auth.uid()));
  get diagnostics deleted_count = row_count;

  update public.lead_import_batches
  set status = 'ROLLED_BACK', rolled_back_at = now()
  where id = p_batch_id;

  return deleted_count;
end;
$$;
grant execute on function public.rollback_lead_import(text) to authenticated;

create or replace view public.lead_pipeline_cards
with (security_invoker = true)
as
select
  l.id,
  l.business_name,
  l.contact_name,
  l.phone,
  l.area_code,
  l.source,
  l.stage,
  l.assigned_agent_id,
  l.estimated_value_pkr,
  l.ai_score,
  l.ai_score_reason,
  l.lost_reason,
  l.converted_customer_id,
  l.created_at,
  l.updated_at,
  l.stage_entered_at,
  greatest(0, floor(extract(epoch from (now() - l.stage_entered_at)) / 86400))::integer as days_in_stage
from public.leads l
where public.has_permission(auth.uid(), 'lead.view')
  and l.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()));

create or replace view public.sales_today_metrics
with (security_invoker = true)
as
select
  coalesce((select count(*)::integer from public.activities a
    where a.agent_id in (select public.accessible_agent_ids(auth.uid()))
      and a.type = 'CALL'
      and (a.occurred_at at time zone 'Asia/Karachi')::date = (now() at time zone 'Asia/Karachi')::date), 0) as calls_made,
  coalesce((select count(*)::integer from public.orders o
    join public.customers c on c.id = o.customer_id
    where o.status <> 'CANCELLED'
      and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
      and (o.placed_at at time zone 'Asia/Karachi')::date = (now() at time zone 'Asia/Karachi')::date), 0) as orders_placed,
  coalesce((select count(*)::integer from public.quotes q
    join public.customers c on c.id = q.customer_id
    where q.status in ('REQUESTED', 'IN_REVIEW')
      and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))), 0) as quotes_pending,
  coalesce((select sum(o.total_pkr)::numeric(12,2) from public.orders o
    join public.customers c on c.id = o.customer_id
    where o.status <> 'CANCELLED'
      and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
      and (o.placed_at at time zone 'Asia/Karachi')::date = (now() at time zone 'Asia/Karachi')::date), 0)::numeric(12,2) as revenue_booked
where public.has_permission(auth.uid(), 'dashboard.view');

create or replace view public.sales_quote_acceptance_by_agent
with (security_invoker = true)
as
select
  q.assigned_to_user_id,
  u.full_name as agent_name,
  count(*) filter (where q.status in ('ACCEPTED', 'CONVERTED'))::integer as accepted_count,
  count(*) filter (where q.status = 'REJECTED')::integer as declined_count,
  count(*) filter (where q.status in ('ACCEPTED', 'CONVERTED', 'REJECTED'))::integer as responded_count,
  case when count(*) filter (where q.status in ('ACCEPTED', 'CONVERTED', 'REJECTED')) = 0 then 0::numeric(5,2)
       else round(100.0 * count(*) filter (where q.status in ('ACCEPTED', 'CONVERTED')) / count(*) filter (where q.status in ('ACCEPTED', 'CONVERTED', 'REJECTED')), 2)::numeric(5,2)
  end as acceptance_rate
from public.quotes q
left join public.users u on u.id = q.assigned_to_user_id
join public.customers c on c.id = q.customer_id
where public.has_permission(auth.uid(), 'quote.view')
  and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
group by q.assigned_to_user_id, u.full_name;

create or replace function public.sales_daily_revenue(p_month_start date default null)
returns table(day date, revenue_pkr numeric(12,2))
language sql
stable
security invoker
set search_path = public
as $$
  select
    (o.placed_at at time zone 'Asia/Karachi')::date as day,
    coalesce(sum(o.total_pkr), 0)::numeric(12,2) as revenue_pkr
  from public.orders o
  join public.customers c on c.id = o.customer_id
  where public.has_permission(auth.uid(), 'dashboard.view')
    and (public.has_permission(auth.uid(), 'financials.view_revenue'))
    and o.status <> 'CANCELLED'
    and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    and (o.placed_at at time zone 'Asia/Karachi')::date >= coalesce(p_month_start, date_trunc('month', now() at time zone 'Asia/Karachi')::date)
    and (o.placed_at at time zone 'Asia/Karachi')::date < coalesce(p_month_start, date_trunc('month', now() at time zone 'Asia/Karachi')::date) + interval '1 month'
  group by 1
  order by 1;
$$;
grant execute on function public.sales_daily_revenue(date) to authenticated;

create or replace function public.customers_nearby(p_latitude numeric, p_longitude numeric, p_limit integer default 25)
returns table(
  customer_id uuid,
  business_name text,
  area_code text,
  latitude numeric,
  longitude numeric,
  distance_meters numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    c.id,
    c.business_name,
    c.area_code,
    c.latitude,
    c.longitude,
    round((6371000 * acos(least(1, greatest(-1,
      cos(radians(p_latitude)) * cos(radians(c.latitude)) * cos(radians(c.longitude) - radians(p_longitude))
      + sin(radians(p_latitude)) * sin(radians(c.latitude))
    ))))::numeric, 2) as distance_meters
  from public.customers c
  where public.has_permission(auth.uid(), 'customer.view')
    and c.is_internal_account = false
    and c.latitude is not null
    and c.longitude is not null
    and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
  order by distance_meters
  limit greatest(1, least(p_limit, 100));
$$;
grant execute on function public.customers_nearby(numeric, numeric, integer) to authenticated;

create index "customers_assigned_agent_coordinates_idx" on public.customers ("assigned_agent_id", "latitude", "longitude") where "latitude" is not null and "longitude" is not null;
create index "activities_visit_distance_idx" on public.activities ("occurred_at", "distance_from_customer_meters") where "type" = 'VISIT' and "distance_from_customer_meters" is not null;
create index "quotes_assigned_to_status_created_at_idx" on public.quotes ("assigned_to_user_id", "status", "created_at");

alter table public.follow_ups add constraint "follow_ups_completion_pair_check" check (("is_completed" = false and "completed_at" is null) or ("is_completed" = true and "completed_at" is not null));

create or replace function public.enforce_follow_up_completion()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.is_completed and new.completed_at is null then
    new.completed_at := now();
  elsif not new.is_completed then
    new.completed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists follow_ups_completion_trigger on public.follow_ups;
create trigger follow_ups_completion_trigger
before insert or update of "is_completed", "completed_at" on public.follow_ups
for each row execute function public.enforce_follow_up_completion();

-- The application still performs the permission-first check before each action.
-- These RLS policies and invoker views remain the authoritative data boundary.

create or replace view public.sales_customer_summary
with (security_invoker = true)
as
select
  c.id as customer_id,
  c.business_name,
  c.area_code,
  c.customer_type,
  c.primary_phone,
  c.whatsapp_phone,
  c.email,
  c.latitude,
  c.longitude,
  c.assigned_agent_id,
  max(a.occurred_at) as last_activity_at,
  max(o.placed_at) as last_order_at,
  greatest(coalesce(max(a.occurred_at), to_timestamp(0)), coalesce(max(o.placed_at), to_timestamp(0))) as last_contact_at
from public.customers c
left join public.activities a on a.customer_id = c.id
left join public.orders o on o.customer_id = c.id and o.status <> 'CANCELLED'
where public.has_permission(auth.uid(), 'customer.view')
  and c.is_internal_account = false
  and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
group by c.id, c.business_name, c.area_code, c.customer_type, c.primary_phone, c.whatsapp_phone, c.email, c.latitude, c.longitude, c.assigned_agent_id;

create index "customers_sales_filter_idx" on public.customers ("assigned_agent_id", "area_code", "customer_type", "business_name") where "is_internal_account" = false;

create or replace function public.log_sales_activity(
  p_type "ActivityType",
  p_customer_id uuid default null,
  p_lead_id uuid default null,
  p_disposition "ActivityDisposition" default 'CONNECTED',
  p_notes text default '',
  p_occurred_at timestamptz default now(),
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_follow_up_due_at timestamptz default null,
  p_follow_up_note text default null,
  p_follow_up_priority "Priority" default 'MEDIUM'
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  agent_id uuid;
  activity_id uuid := gen_random_uuid();
  customer_latitude numeric;
  customer_longitude numeric;
  distance_meters numeric;
  follow_up_due timestamptz;
begin
  if not public.has_permission(auth.uid(), 'activity.create') then
    raise exception using errcode = '42501', message = 'Activity logging is not permitted.';
  end if;

  select sa.id into agent_id from public.sales_agents sa where sa.user_id = auth.uid();
  if agent_id is null then
    raise exception using errcode = '42501', message = 'Your Sales Agent account is not configured.';
  end if;
  if agent_id not in (select public.accessible_agent_ids(auth.uid())) then
    raise exception using errcode = '42501', message = 'This Sales Agent is outside your data scope.';
  end if;

  if p_customer_id is null and p_lead_id is null then
    raise exception using errcode = '22023', message = 'Choose a customer or lead before logging activity.';
  end if;
  if p_customer_id is not null then
    select c.latitude, c.longitude into customer_latitude, customer_longitude
    from public.customers c
    where c.id = p_customer_id
      and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
      and c.is_internal_account = false;
    if not found then
      raise exception using errcode = '42501', message = 'This customer is outside your data scope.';
    end if;
  end if;
  if p_lead_id is not null and not exists (
    select 1 from public.leads l
    where l.id = p_lead_id and l.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
  ) then
    raise exception using errcode = '42501', message = 'This lead is outside your data scope.';
  end if;

  if p_type <> 'VISIT' and (p_latitude is not null or p_longitude is not null or p_accuracy_meters is not null) then
    raise exception using errcode = '22023', message = 'Location is only captured for an explicit visit log.';
  end if;
  if p_type = 'VISIT' and p_latitude is not null and p_longitude is not null and customer_latitude is not null and customer_longitude is not null then
    distance_meters := round((6371000 * acos(least(1, greatest(-1,
      cos(radians(p_latitude)) * cos(radians(customer_latitude)) * cos(radians(customer_longitude) - radians(p_longitude))
      + sin(radians(p_latitude)) * sin(radians(customer_latitude))
    ))))::numeric, 2);
  end if;

  insert into public.activities (
    id, type, lead_id, customer_id, agent_id, disposition, notes,
    latitude, longitude, location_accuracy_meters, distance_from_customer_meters,
    occurred_at
  ) values (
    activity_id, p_type, p_lead_id, p_customer_id, agent_id, p_disposition, coalesce(trim(p_notes), ''),
    case when p_type = 'VISIT' then p_latitude else null end,
    case when p_type = 'VISIT' then p_longitude else null end,
    case when p_type = 'VISIT' then p_accuracy_meters else null end,
    distance_meters,
    p_occurred_at
  );

  if p_disposition in ('CALLBACK_REQUESTED', 'FOLLOW_UP_SCHEDULED') then
    follow_up_due := coalesce(p_follow_up_due_at, (((now() at time zone 'Asia/Karachi')::date + interval '1 day' + interval '10 hours') at time zone 'Asia/Karachi'));
    insert into public.follow_ups (id, activity_id, lead_id, customer_id, agent_id, due_at, priority, note)
    values (gen_random_uuid(), activity_id, p_lead_id, p_customer_id, agent_id, follow_up_due, coalesce(p_follow_up_priority, 'MEDIUM'), coalesce(nullif(trim(p_follow_up_note), ''), nullif(trim(p_notes), ''), 'Follow up with contact.'));
  elsif p_follow_up_due_at is not null then
    insert into public.follow_ups (id, activity_id, lead_id, customer_id, agent_id, due_at, priority, note)
    values (gen_random_uuid(), activity_id, p_lead_id, p_customer_id, agent_id, p_follow_up_due_at, coalesce(p_follow_up_priority, 'MEDIUM'), coalesce(nullif(trim(p_follow_up_note), ''), nullif(trim(p_notes), ''), 'Follow up with contact.'));
  end if;

  return activity_id;
end;
$$;
grant execute on function public.log_sales_activity("ActivityType", uuid, uuid, "ActivityDisposition", text, timestamptz, numeric, numeric, numeric, timestamptz, text, "Priority") to authenticated;

create or replace function public.import_sales_leads(
  p_batch_id text,
  p_assigned_agent_id uuid,
  p_source_filename text,
  p_rows jsonb
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  inserted_count integer;
begin
  if not public.has_permission(auth.uid(), 'lead.import') then
    raise exception using errcode = '42501', message = 'Lead import is not permitted.';
  end if;
  if p_assigned_agent_id not in (select public.accessible_agent_ids(auth.uid())) then
    raise exception using errcode = '42501', message = 'The selected Sales Agent is outside your data scope.';
  end if;
  if exists (select 1 from public.lead_import_batches where id = p_batch_id) then
    raise exception using errcode = '22023', message = 'This import batch identifier has already been used.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'The import does not contain any lead rows.';
  end if;

  insert into public.lead_import_batches (id, created_by_user_id, assigned_agent_id, source_filename, row_count)
  values (p_batch_id, auth.uid(), p_assigned_agent_id, nullif(trim(p_source_filename), ''), jsonb_array_length(p_rows));

  insert into public.leads (
    id, business_name, contact_name, phone, email, area_code, full_address,
    source, stage, assigned_agent_id, normalized_name, estimated_value_pkr,
    import_batch_id
  )
  select
    gen_random_uuid(), r.business_name, coalesce(nullif(r.contact_name, ''), r.business_name), r.phone,
    nullif(r.email, ''), r.area_code, nullif(r.full_address, ''), 'IMPORT', 'NEW',
    p_assigned_agent_id,
    upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')),
    coalesce(nullif(r.estimated_value_pkr, ''), '0')::numeric(12,2), p_batch_id
  from jsonb_to_recordset(p_rows) as r(
    business_name text,
    contact_name text,
    phone text,
    email text,
    area_code text,
    full_address text,
    estimated_value_pkr text
  )
  where nullif(trim(r.business_name), '') is not null
    and r.phone ~ '^\\+92[0-9]{10}$'
    and not exists (select 1 from public.leads l where l.phone = r.phone or l.normalized_name = upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')))
    and not exists (select 1 from public.customers c where c.primary_phone = r.phone or c.normalized_name = upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')));
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;
grant execute on function public.import_sales_leads(text, uuid, text, jsonb) to authenticated;

create or replace function public.preview_sales_lead_duplicates(p_rows jsonb)
returns table(row_index integer, match_type text, matched_name text)
language sql
stable
security invoker
set search_path = public
as $$
  with incoming as (
    select
      coalesce(nullif(r.source_row, ''), (row_number() over ())::text)::integer as row_index,
      r.business_name,
      r.phone,
      upper(regexp_replace(trim(regexp_replace(r.business_name, '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g')) as normalized_name
    from jsonb_to_recordset(p_rows) as r(source_row text, business_name text, phone text)
  )
  select i.row_index, 'LEAD_BY_PHONE', l.business_name
  from incoming i
  join public.leads l on l.phone = i.phone and l.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
  where public.has_permission(auth.uid(), 'lead.import')
  union all
  select i.row_index, 'LEAD_BY_NAME', l.business_name
  from incoming i
  join public.leads l on l.normalized_name = i.normalized_name and l.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
  where public.has_permission(auth.uid(), 'lead.import')
  union all
  select i.row_index, 'CUSTOMER_BY_PHONE', c.business_name
  from incoming i
  join public.customers c on c.primary_phone = i.phone and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and not c.is_internal_account
  where public.has_permission(auth.uid(), 'lead.import')
  union all
  select i.row_index, 'CUSTOMER_BY_NAME', c.business_name
  from incoming i
  join public.customers c on c.normalized_name = i.normalized_name and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and not c.is_internal_account
  where public.has_permission(auth.uid(), 'lead.import');
$$;
grant execute on function public.preview_sales_lead_duplicates(jsonb) to authenticated;

create or replace function public.sales_calendar_feed(p_token_hash text)
returns table(
  follow_up_id uuid,
  customer_id uuid,
  business_name text,
  note text,
  due_at timestamptz,
  priority text,
  calendar_event_uid text
)
language sql
stable
security definer
set search_path = public
as $$
  select f.id, f.customer_id, c.business_name, f.note, f.due_at, f.priority::text, f.calendar_event_uid
  from public.calendar_feed_tokens t
  join public.follow_ups f on f.agent_id = t.sales_agent_id
  left join public.customers c on c.id = f.customer_id
  where t.token_hash = p_token_hash
    and t.revoked_at is null
    and f.is_completed = false;
$$;
revoke all on function public.sales_calendar_feed(text) from public;
grant execute on function public.sales_calendar_feed(text) to anon, authenticated;

create or replace function public.sales_performance_summary(p_month_start date default null)
returns table(
  orders_count integer,
  revenue_pkr numeric(12,2),
  quoted_count integer,
  converted_quotes_count integer,
  quote_conversion_rate numeric(5,2),
  monthly_target_pkr numeric(12,2),
  target_progress_percent numeric(5,2)
)
language sql
stable
security invoker
set search_path = public
as $$
  with month_window as (
    select coalesce(p_month_start, date_trunc('month', now() at time zone 'Asia/Karachi')::date) as start_date
  ),
  current_agent as (
    select sa.id, sa.monthly_target_pkr
    from public.sales_agents sa
    where sa.user_id = auth.uid()
  ),
  order_totals as (
    select count(*)::integer as orders_count, coalesce(sum(o.total_pkr), 0)::numeric(12,2) as revenue_pkr
    from public.orders o
    join public.customers c on c.id = o.customer_id
    cross join month_window m
    where public.has_permission(auth.uid(), 'dashboard.view')
      and public.has_permission(auth.uid(), 'financials.view_revenue')
      and o.status <> 'CANCELLED'
      and c.assigned_agent_id in (select id from current_agent)
      and (o.placed_at at time zone 'Asia/Karachi')::date >= m.start_date
      and (o.placed_at at time zone 'Asia/Karachi')::date < m.start_date + interval '1 month'
  ),
  quote_totals as (
    select
      count(*) filter (where q.status in ('REQUESTED', 'IN_REVIEW', 'QUOTED', 'ACCEPTED', 'REJECTED', 'CONVERTED'))::integer as quoted_count,
      count(*) filter (where q.status in ('ACCEPTED', 'CONVERTED'))::integer as converted_quotes_count
    from public.quotes q
    join public.customers c on c.id = q.customer_id
    cross join month_window m
    where public.has_permission(auth.uid(), 'quote.view')
      and c.assigned_agent_id in (select id from current_agent)
      and (q.created_at at time zone 'Asia/Karachi')::date >= m.start_date
      and (q.created_at at time zone 'Asia/Karachi')::date < m.start_date + interval '1 month'
  )
  select
    o.orders_count,
    o.revenue_pkr,
    q.quoted_count,
    q.converted_quotes_count,
    case when q.quoted_count = 0 then 0::numeric(5,2) else round(100.0 * q.converted_quotes_count / q.quoted_count, 2)::numeric(5,2) end,
    coalesce((select monthly_target_pkr from current_agent), 0)::numeric(12,2),
    case when coalesce((select monthly_target_pkr from current_agent), 0) = 0 then 0::numeric(5,2) else round(100.0 * o.revenue_pkr / (select monthly_target_pkr from current_agent), 2)::numeric(5,2) end
  from order_totals o cross join quote_totals q;
$$;
grant execute on function public.sales_performance_summary(date) to authenticated;

-- Sales order-on-behalf still uses the canonical Vendor resolver. The additional
-- current-user path is limited to scoped order.create users and does not change
-- Vendor self-service visibility.
create or replace function public.resolve_visible_products(p_customer_id uuid)
returns table (
  id uuid, sku text, name_en text, name_ur text, description_en text, description_ur text,
  category_id uuid, brand_id uuid, unit_of_measure text, pack_size numeric, price_pkr numeric,
  compare_at_price_pkr numeric, loyalty_points_per_unit integer, stock_quantity numeric,
  low_stock_threshold numeric, is_active boolean, is_quote_only boolean,
  created_at timestamptz, updated_at timestamptz
)
language sql stable security invoker set search_path = public
as $$
  with customer_context as (
    select c.id, c.vendor_group_id, coalesce(vg.show_all_by_default, false) as show_all_by_default
    from public.customers c
    left join public.vendor_groups vg on vg.id = c.vendor_group_id
    where c.id = p_customer_id
      and (
        exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
        or (public.has_permission(auth.uid(), 'order.create') and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())))
      )
  ), ranked_rules as (
    select p.id as product_id, r.mode,
      row_number() over (
        partition by p.id
        order by case
          when r.scope_type = 'VENDOR' and r.entity_type = 'PRODUCT' then 7
          when r.scope_type = 'VENDOR' and r.entity_type = 'BRAND' then 6
          when r.scope_type = 'VENDOR' and r.entity_type = 'CATEGORY' then 5
          when r.scope_type = 'GROUP' and r.entity_type = 'PRODUCT' then 4
          when r.scope_type = 'GROUP' and r.entity_type = 'BRAND' then 3
          when r.scope_type = 'GROUP' and r.entity_type = 'CATEGORY' then 2
          else 0
        end desc, r.created_at desc
      ) as rank
    from public.products p
    cross join customer_context c
    join public.catalog_visibility_rules r on
      ((r.scope_type = 'VENDOR' and r.scope_id = c.id)
       or (r.scope_type = 'GROUP' and r.scope_id = c.vendor_group_id))
      and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id)
       or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id)
       or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
    where p.is_active
  ), resolved as (
    select p.id,
      coalesce((select rr.mode = 'ALLOW' from ranked_rules rr where rr.product_id = p.id and rr.rank = 1), c.show_all_by_default) as visible
    from public.products p cross join customer_context c
    where p.is_active
  )
  select p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur,
    p.category_id, p.brand_id, p.unit_of_measure, p.pack_size, p.price_pkr,
    p.compare_at_price_pkr, p.loyalty_points_per_unit, p.stock_quantity,
    p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
  from public.products p
  join resolved r on r.id = p.id and r.visible
  where public.has_permission(auth.uid(), 'product.view');
$$;

create or replace function public.create_sales_order_for_customer(
  p_customer_id uuid,
  p_lines jsonb,
  p_notes text default null,
  p_payment_method "PaymentMethod" default 'BALANCE'
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  order_id uuid := gen_random_uuid();
  agent_id uuid;
  line record;
  visible_product record;
  subtotal numeric(12,2) := 0;
  line_total numeric(12,2);
begin
  if not public.has_permission(auth.uid(), 'order.create') then
    raise exception using errcode = '42501', message = 'Place order on behalf is not permitted.';
  end if;
  select sa.id into agent_id from public.sales_agents sa where sa.user_id = auth.uid();
  if agent_id is null or agent_id not in (select public.accessible_agent_ids(auth.uid())) then
    raise exception using errcode = '42501', message = 'Your Sales Agent account is not configured or outside scope.';
  end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) and not c.is_internal_account) then
    raise exception using errcode = '42501', message = 'This customer is outside your data scope.';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception using errcode = '22023', message = 'Add at least one visible product before placing the order.';
  end if;

  for line in select * from jsonb_to_recordset(p_lines) as r(product_id uuid, quantity numeric) loop
    if line.quantity is null or line.quantity <= 0 then
      raise exception using errcode = '22023', message = 'Every order quantity must be greater than zero.';
    end if;
    select * into visible_product from public.resolve_visible_products(p_customer_id) vp where vp.id = line.product_id;
    if not found then
      raise exception using errcode = '42501', message = 'One selected product is not visible to this customer.';
    end if;
    if visible_product.is_quote_only then
      raise exception using errcode = '22023', message = 'A quote-only product cannot be placed in a direct order.';
    end if;
    line_total := (visible_product.price_pkr * line.quantity)::numeric(12,2);
    subtotal := (subtotal + line_total)::numeric(12,2);
  end loop;

  insert into public.orders (
    id, order_number, customer_id, placed_by_user_id, placed_via, payment_method,
    status, approval_required, subtotal_pkr, discount_pkr, points_redeemed,
    points_discount_pkr, total_pkr, points_earned, notes, placed_at
  ) values (
    order_id, 'AK-' || to_char((now() at time zone 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(order_id::text, '-', ''), 1, 6)),
    p_customer_id, auth.uid(), 'SALES_AGENT', p_payment_method, 'PLACED', false,
    subtotal, 0, 0, 0, subtotal, 0, nullif(trim(p_notes), ''), now()
  );

  for line in select * from jsonb_to_recordset(p_lines) as r(product_id uuid, quantity numeric) loop
    select * into visible_product from public.resolve_visible_products(p_customer_id) vp where vp.id = line.product_id;
    insert into public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr)
    values (order_id, line.product_id, line.quantity, visible_product.price_pkr, (visible_product.price_pkr * line.quantity)::numeric(12,2));
  end loop;

  return order_id;
end;
$$;
grant execute on function public.create_sales_order_for_customer(uuid, jsonb, text, "PaymentMethod") to authenticated;

create policy notifications_sales_insert on public.notifications for insert to authenticated
  with check (
    public.has_permission(auth.uid(), 'message.send')
    and user_id = auth.uid()
    or (
      public.has_permission(auth.uid(), 'quote.price')
      and exists (
        select 1
        from public.customer_users cu
        join public.customers c on c.id = cu.customer_id
        where cu.user_id = notifications.user_id
          and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
      )
    )
  );

create or replace function public.price_sales_quote(
  p_quote_id uuid,
  p_lines jsonb,
  p_valid_until timestamptz,
  p_internal_notes text default null
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  quote_row record;
  line record;
  updated_count integer := 0;
  line_updated_count integer := 0;
  expected_count integer;
  priced_count integer;
begin
  if not public.has_permission(auth.uid(), 'quote.price') then
    raise exception using errcode = '42501', message = 'Quote pricing is not permitted.';
  end if;
  if p_valid_until is null or p_valid_until <= now() then
    raise exception using errcode = '22023', message = 'Set a validity date in the future.';
  end if;
  select q.*, c.assigned_agent_id into quote_row
  from public.quotes q
  join public.customers c on c.id = q.customer_id
  where q.id = p_quote_id
    and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    and q.status in ('REQUESTED', 'IN_REVIEW')
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'This quote is outside your scope or no longer in the pricing queue.';
  end if;
  if jsonb_typeof(p_lines) <> 'array' then raise exception using errcode = '22023', message = 'Quote line prices are required.'; end if;

  select count(*) into expected_count from public.quote_lines where quote_id = p_quote_id;
  select count(*) into priced_count from jsonb_to_recordset(p_lines) as r(line_id uuid, price_pkr numeric) where r.price_pkr is not null and r.price_pkr >= 0;
  if expected_count = 0 or priced_count <> expected_count then
    raise exception using errcode = '22023', message = 'Enter a non-negative price for every quote line.';
  end if;

  for line in select * from jsonb_to_recordset(p_lines) as r(line_id uuid, price_pkr numeric) loop
    update public.quote_lines ql
    set quoted_unit_price_pkr = line.price_pkr,
        line_total_pkr = (line.price_pkr * ql.quantity)::numeric(12,2)
    where ql.id = line.line_id and ql.quote_id = p_quote_id;
    get diagnostics line_updated_count = row_count;
    updated_count := updated_count + line_updated_count;
  end loop;

  update public.quotes
  set status = 'QUOTED', valid_until = p_valid_until, internal_notes = nullif(trim(p_internal_notes), ''), quoted_by_user_id = auth.uid(), quoted_at = now()
  where id = p_quote_id;

  insert into public.notifications (user_id, type, title_en, title_ur, body, link_url)
  select cu.user_id, 'QUOTE_PRICED', 'Quote ready', 'Quote ready', 'Your quote is ready to review.', '/en/vendor/quotes/' || p_quote_id::text
  from public.customer_users cu
  where cu.customer_id = quote_row.customer_id;

  return updated_count;
end;
$$;
grant execute on function public.price_sales_quote(uuid, jsonb, timestamptz, text) to authenticated;

create or replace function public.ensure_follow_up_calendar_uid()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.calendar_event_uid is null or trim(new.calendar_event_uid) = '' then
    new.calendar_event_uid := 'follow-up-' || new.id::text || '@akai-crm';
  end if;
  return new;
end;
$$;

drop trigger if exists follow_ups_calendar_uid_trigger on public.follow_ups;
create trigger follow_ups_calendar_uid_trigger
before insert or update of "calendar_event_uid" on public.follow_ups
for each row execute function public.ensure_follow_up_calendar_uid();
