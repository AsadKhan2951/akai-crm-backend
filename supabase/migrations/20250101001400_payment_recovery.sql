-- Payment recovery and cash handling. Additive migration; never edit 0001-0013.

create type public."CollectionMethod" as enum ('CASH','CHEQUE','BANK_TRANSFER','ONLINE');
create type public."CollectionStatus" as enum ('COLLECTED','DEPOSITED','CLEARED','BOUNCED','CANCELLED');
create type public."CashDepositStatus" as enum ('PENDING','VERIFIED','DISPUTED');
create type public."RecoveryReminderStatus" as enum ('DRAFT','QUEUED','SENT','FAILED','CANCELLED');

create table public.collection_receipt_counters (
  month date primary key,
  last_number integer not null default 0 check (last_number >= 0)
);

create table public.payment_collections (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  agent_id uuid not null references public.sales_agents(id) on delete restrict,
  amount_pkr numeric(12,2) not null check (amount_pkr > 0),
  method public."CollectionMethod" not null,
  cheque_number text,
  cheque_date date,
  bank_name text,
  receipt_number text not null unique,
  against_invoice_numbers text[] not null default '{}',
  status public."CollectionStatus" not null default 'COLLECTED',
  collected_at timestamptz not null default now(),
  deposited_at timestamptz,
  cleared_at timestamptz,
  bounced_reason text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  photo_url text,
  notes text,
  ledger_entry_id uuid unique references public.ledger_entries(id) on delete set null,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint payment_collections_cheque_fields check (method <> 'CHEQUE' or (nullif(trim(cheque_number),'') is not null and cheque_date is not null and nullif(trim(bank_name),'') is not null)),
  constraint payment_collections_status_dates check ((status in ('DEPOSITED','CLEARED','BOUNCED') and deposited_at is not null) or status in ('COLLECTED','CANCELLED') or (status='CLEARED' and cleared_at is not null))
);
create index payment_collections_agent_status_collected_idx on public.payment_collections(agent_id,status,collected_at);
create index payment_collections_customer_status_collected_idx on public.payment_collections(customer_id,status,collected_at);
create index payment_collections_status_collected_idx on public.payment_collections(status,collected_at);
create index payment_collections_method_status_idx on public.payment_collections(method,status);
create index payment_collections_cheque_number_idx on public.payment_collections(cheque_number) where cheque_number is not null;

create table public.cash_deposits (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.sales_agents(id) on delete restrict,
  total_amount_pkr numeric(12,2) not null check (total_amount_pkr > 0),
  deposit_slip_url text,
  deposited_at timestamptz not null default now(),
  verified_by_user_id uuid references public.users(id) on delete set null,
  verified_at timestamptz,
  status public."CashDepositStatus" not null default 'PENDING',
  notes text,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index cash_deposits_agent_status_deposited_idx on public.cash_deposits(agent_id,status,deposited_at);
create index cash_deposits_status_deposited_idx on public.cash_deposits(status,deposited_at);

create table public.cash_deposit_collections (
  deposit_id uuid not null references public.cash_deposits(id) on delete cascade,
  collection_id uuid not null references public.payment_collections(id) on delete restrict,
  primary key(deposit_id,collection_id)
);
create index cash_deposit_collections_collection_idx on public.cash_deposit_collections(collection_id);

create table public.recovery_targets (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.sales_agents(id) on delete cascade,
  month date not null,
  target_amount_pkr numeric(12,2) not null check (target_amount_pkr >= 0),
  created_at timestamptz not null default now(),
  unique(agent_id,month)
);
create index recovery_targets_month_agent_idx on public.recovery_targets(month,agent_id);

create table public.collection_reminder_preferences (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  opted_out boolean not null default false,
  preferred_locale text not null default 'en' check (preferred_locale in ('en','ur')),
  open_dispute boolean not null default false,
  updated_by_user_id uuid references public.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.recovery_reminder_queue (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  agent_id uuid not null references public.sales_agents(id) on delete restrict,
  channel public."MessageChannel" not null default 'WHATSAPP',
  locale text not null default 'en' check (locale in ('en','ur')),
  threshold_days integer not null check (threshold_days > 0),
  body text not null,
  against_invoice_numbers text[] not null default '{}',
  status public."RecoveryReminderStatus" not null default 'DRAFT',
  scheduled_for timestamptz,
  sent_at timestamptz,
  cancelled_at timestamptz,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index recovery_reminder_queue_status_schedule_idx on public.recovery_reminder_queue(status,scheduled_for);
create index recovery_reminder_queue_customer_status_idx on public.recovery_reminder_queue(customer_id,status);

create table public.credit_risk_snapshots (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  score numeric(5,2) not null check (score between 0 and 100),
  reasons_json jsonb not null default '[]'::jsonb,
  computed_at timestamptz not null default now(),
  model_version text not null default 'sql-v1'
);
create index credit_risk_snapshots_customer_computed_idx on public.credit_risk_snapshots(customer_id,computed_at desc);

alter table public.payment_collections enable row level security;
alter table public.cash_deposits enable row level security;
alter table public.cash_deposit_collections enable row level security;
alter table public.recovery_targets enable row level security;
alter table public.collection_reminder_preferences enable row level security;
alter table public.recovery_reminder_queue enable row level security;
alter table public.credit_risk_snapshots enable row level security;
alter table public.collection_receipt_counters enable row level security;

create policy payment_collections_select on public.payment_collections for select to authenticated
using (public.has_permission(auth.uid(),'collection.view') and (agent_id in (select public.accessible_agent_ids(auth.uid())) or public.role_scope(auth.uid())='GLOBAL'));
create policy payment_collections_insert on public.payment_collections for insert to authenticated
with check (false);
create policy payment_collections_update on public.payment_collections for update to authenticated
using (false) with check (false);
create policy payment_collections_delete on public.payment_collections for delete to authenticated
using (false);

create policy cash_deposits_select on public.cash_deposits for select to authenticated
using (public.has_permission(auth.uid(),'collection.view') and (agent_id in (select public.accessible_agent_ids(auth.uid())) or public.role_scope(auth.uid())='GLOBAL'));
create policy cash_deposits_insert on public.cash_deposits for insert to authenticated
with check (false);
create policy cash_deposits_update on public.cash_deposits for update to authenticated
using (false) with check (false);
create policy cash_deposits_delete on public.cash_deposits for delete to authenticated
using (false);

create policy cash_deposit_collections_select on public.cash_deposit_collections for select to authenticated
using (public.has_permission(auth.uid(),'collection.view'));
create policy cash_deposit_collections_write on public.cash_deposit_collections for all to authenticated
using (false) with check (false);

create policy recovery_targets_select on public.recovery_targets for select to authenticated
using (public.has_permission(auth.uid(),'collection.view') and (agent_id in (select public.accessible_agent_ids(auth.uid())) or public.has_permission(auth.uid(),'settings.manage')));
create policy recovery_targets_manage on public.recovery_targets for all to authenticated
using (public.has_permission(auth.uid(),'settings.manage')) with check (public.has_permission(auth.uid(),'settings.manage'));

create policy collection_reminder_preferences_select on public.collection_reminder_preferences for select to authenticated
using (public.has_permission(auth.uid(),'collection.view') and exists(select 1 from public.customers c where c.id=customer_id and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or public.has_permission(auth.uid(),'message.campaign')));
create policy collection_reminder_preferences_manage on public.collection_reminder_preferences for all to authenticated
using (public.has_permission(auth.uid(),'message.campaign')) with check (public.has_permission(auth.uid(),'message.campaign'));

create policy recovery_reminder_queue_select on public.recovery_reminder_queue for select to authenticated
using (public.has_permission(auth.uid(),'message.send') and (agent_id in (select public.accessible_agent_ids(auth.uid())) or public.has_permission(auth.uid(),'message.campaign')));
create policy recovery_reminder_queue_write on public.recovery_reminder_queue for all to authenticated
using (false) with check (false);

create policy credit_risk_snapshots_select on public.credit_risk_snapshots for select to authenticated
using (public.has_permission(auth.uid(),'collection.view') and exists(select 1 from public.customers c where c.id=customer_id and (c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or public.has_permission(auth.uid(),'financials.view_revenue'))));
create policy credit_risk_snapshots_write on public.credit_risk_snapshots for all to authenticated
using (false) with check (false);

create or replace function public.apply_customer_ledger_delta(p_customer_id uuid, p_delta numeric, p_reference text, p_description text, p_type public."LedgerEntryType", p_entry_date timestamptz default now())
returns uuid language plpgsql security definer set search_path=public as $$
declare entry_id uuid;
begin
  if p_delta = 0 or nullif(trim(p_reference),'') is null or nullif(trim(p_description),'') is null then raise exception using errcode='22023', message='Ledger delta, reference, and description are required.'; end if;
  perform 1 from public.customers where id=p_customer_id for update;
  if not found then raise exception using errcode='P0002', message='Customer not found.'; end if;
  insert into public.ledger_entries(id,customer_id,type,amount_pkr,reference_number,description,entry_date,recorded_by_user_id)
  values(gen_random_uuid(),p_customer_id,p_type,p_delta::numeric(12,2),trim(p_reference),trim(p_description),p_entry_date,coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)) returning id into entry_id;
  update public.customers set current_balance_pkr=(current_balance_pkr+p_delta)::numeric(12,2), updated_at=now() where id=p_customer_id;
  return entry_id;
end; $$;
revoke all on function public.apply_customer_ledger_delta(uuid,numeric,text,text,public."LedgerEntryType",timestamptz) from public, authenticated;

create or replace function public.record_admin_ledger_payment(p_customer_id uuid, p_amount_pkr numeric, p_reference text, p_description text, p_entry_date timestamptz default now())
returns uuid language plpgsql security invoker set search_path = public as $$
declare entry_id uuid;
begin
  if not public.has_permission(auth.uid(),'ledger.record_payment') then raise exception using errcode='42501', message='Recording a payment is not permitted.'; end if;
  if p_amount_pkr <= 0 or nullif(trim(p_reference),'') is null or nullif(trim(p_description),'') is null then raise exception using errcode='22023', message='Enter a positive payment, reference, and description.'; end if;
  if not exists(select 1 from public.customers c where c.id=p_customer_id and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))) then raise exception using errcode='42501', message='This customer is outside your scope.'; end if;
  entry_id := public.apply_customer_ledger_delta(p_customer_id,-abs(p_amount_pkr),p_reference,p_description,'PAYMENT',p_entry_date);
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'RECORD_PAYMENT','LEDGER',entry_id::text,jsonb_build_object('customer_id',p_customer_id,'amount_pkr',(-abs(p_amount_pkr))::numeric(12,2)));
  return entry_id;
end; $$;
grant execute on function public.record_admin_ledger_payment(uuid,numeric,text,text,timestamptz) to authenticated;

create or replace function public.record_payment_collection(
  p_customer_id uuid, p_amount_pkr numeric, p_method public."CollectionMethod", p_cheque_number text default null, p_cheque_date date default null, p_bank_name text default null, p_against_invoice_numbers text[] default null, p_latitude numeric default null, p_longitude numeric default null, p_photo_url text default null, p_notes text default null
) returns table(collection_id uuid, receipt_number text) language plpgsql security definer set search_path=public as $$
declare agent_id uuid; month_key date; next_number integer; new_receipt text; new_id uuid;
begin
  if not public.has_permission(auth.uid(),'collection.record') then raise exception using errcode='42501', message='Recording a collection is not permitted.'; end if;
  if p_amount_pkr <= 0 then raise exception using errcode='22023', message='Collection amount must be positive.'; end if;
  if p_method='CHEQUE' and (nullif(trim(p_cheque_number),'') is null or p_cheque_date is null or nullif(trim(p_bank_name),'') is null) then raise exception using errcode='22023', message='Cheque number, cheque date, and bank are required for a cheque collection.'; end if;
  select sa.id into agent_id from public.sales_agents sa where sa.user_id=auth.uid() and exists(select 1 from public.customers c where c.id=p_customer_id and c.assigned_agent_id=sa.id) for update;
  if not found then raise exception using errcode='42501', message='This customer is outside your assigned recovery scope.'; end if;
  month_key := (now() at time zone 'Asia/Karachi')::date - ((extract(day from (now() at time zone 'Asia/Karachi'))::integer - 1) * interval '1 day');
  insert into public.collection_receipt_counters(month,last_number) values(month_key,1) on conflict(month) do update set last_number=public.collection_receipt_counters.last_number+1 returning last_number into next_number;
  new_receipt := 'AKAI-R-' || to_char(month_key,'YYYYMM') || '-' || lpad(next_number::text,4,'0');
  insert into public.payment_collections(id,customer_id,agent_id,amount_pkr,method,cheque_number,cheque_date,bank_name,receipt_number,against_invoice_numbers,latitude,longitude,photo_url,notes,created_by_user_id)
  values(gen_random_uuid(),p_customer_id,agent_id,abs(p_amount_pkr)::numeric(12,2),p_method,nullif(trim(p_cheque_number),''),p_cheque_date,nullif(trim(p_bank_name),''),new_receipt,p_against_invoice_numbers,p_latitude,p_longitude,p_photo_url,nullif(trim(p_notes),''),auth.uid()) returning id into new_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'RECORD_COLLECTION','PAYMENT_COLLECTION',new_id::text,jsonb_build_object('customer_id',p_customer_id,'amount_pkr',abs(p_amount_pkr)::numeric(12,2),'method',p_method,'receipt_number',new_receipt));
  return query select new_id,new_receipt;
end; $$;
grant execute on function public.record_payment_collection(uuid,numeric,public."CollectionMethod",text,date,text,text[],numeric,numeric,text,text) to authenticated;

create or replace function public.submit_cash_deposit(p_collection_ids uuid[], p_total_amount_pkr numeric, p_deposit_slip_url text default null, p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare agent_id uuid; deposit_id uuid; selected_total numeric(12,2);
begin
  if not public.has_permission(auth.uid(),'collection.deposit') then raise exception using errcode='42501', message='Cash deposit submission is not permitted.'; end if;
  if coalesce(array_length(p_collection_ids,1),0)=0 or p_total_amount_pkr<=0 then raise exception using errcode='22023', message='Select at least one collection and enter a positive deposit total.'; end if;
  select sa.id into agent_id from public.sales_agents sa where sa.user_id=auth.uid();
  if not found then raise exception using errcode='42501', message='Your Sales Agent account is not configured.'; end if;
  select coalesce(sum(pc.amount_pkr),0)::numeric(12,2) into selected_total from public.payment_collections pc where pc.id=any(p_collection_ids) and pc.agent_id=agent_id and pc.status='COLLECTED';
  perform 1 from public.payment_collections pc where pc.id=any(p_collection_ids) and pc.agent_id=agent_id and pc.status='COLLECTED' for update;
  if selected_total <> p_total_amount_pkr then raise exception using errcode='22023', message='Deposit total must exactly match the selected collected amounts.'; end if;
  insert into public.cash_deposits(agent_id,total_amount_pkr,deposit_slip_url,notes,created_by_user_id) values(agent_id,p_total_amount_pkr,p_deposit_slip_url,nullif(trim(p_notes),''),auth.uid()) returning id into deposit_id;
  insert into public.cash_deposit_collections(deposit_id,collection_id) select deposit_id,unnest(p_collection_ids);
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'SUBMIT_DEPOSIT','CASH_DEPOSIT',deposit_id::text,jsonb_build_object('total_amount_pkr',p_total_amount_pkr,'collection_count',array_length(p_collection_ids,1)));
  return deposit_id;
end; $$;
grant execute on function public.submit_cash_deposit(uuid[],numeric,text,text) to authenticated;

create or replace function public.verify_cash_deposit(p_deposit_id uuid, p_status public."CashDepositStatus", p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare deposit_agent uuid; collection_row record; verified_total numeric(12,2);
begin
  if not public.has_permission(auth.uid(),'collection.verify_deposit') then raise exception using errcode='42501', message='Deposit verification is not permitted.'; end if;
  if p_status not in ('VERIFIED','DISPUTED') then raise exception using errcode='22023', message='Choose VERIFIED or DISPUTED.'; end if;
  select agent_id,total_amount_pkr into deposit_agent,verified_total from public.cash_deposits where id=p_deposit_id and status='PENDING' for update;
  if not found then raise exception using errcode='42501', message='Deposit is outside your scope or is no longer pending.'; end if;
  if p_status='DISPUTED' and nullif(trim(p_note),'') is null then raise exception using errcode='22023', message='Add a note explaining the deposit dispute.'; end if;
  update public.cash_deposits set status=p_status,verified_by_user_id=auth.uid(),verified_at=now(),notes=coalesce(nullif(trim(p_note),''),notes) where id=p_deposit_id;
  if p_status='VERIFIED' then
    for collection_row in select pc.* from public.payment_collections pc join public.cash_deposit_collections cdc on cdc.collection_id=pc.id where cdc.deposit_id=p_deposit_id for update loop
      if collection_row.method='CHEQUE' then
        update public.payment_collections set status='DEPOSITED',deposited_at=now() where id=collection_row.id;
      else
        update public.payment_collections set status='CLEARED',deposited_at=now(),cleared_at=now() where id=collection_row.id;
        update public.payment_collections set ledger_entry_id=public.apply_customer_ledger_delta(collection_row.customer_id,-collection_row.amount_pkr,'COLLECTION-'||collection_row.receipt_number,'Collection cleared: '||collection_row.receipt_number,'PAYMENT') where id=collection_row.id;
      end if;
      insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'VERIFY_COLLECTION','PAYMENT_COLLECTION',collection_row.id::text,jsonb_build_object('status',case when collection_row.method='CHEQUE' then 'DEPOSITED' else 'CLEARED' end,'deposit_id',p_deposit_id));
    end loop;
  end if;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'VERIFY_DEPOSIT','CASH_DEPOSIT',p_deposit_id::text,jsonb_build_object('status',p_status,'total_amount_pkr',verified_total,'note',p_note));
  return p_deposit_id;
end; $$;
grant execute on function public.verify_cash_deposit(uuid,public."CashDepositStatus",text) to authenticated;

create or replace function public.clear_cheque_collection(p_collection_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare row_data record; entry_id uuid;
begin
  if not public.has_permission(auth.uid(),'collection.verify_deposit') then raise exception using errcode='42501', message='Cheque clearance is not permitted.'; end if;
  select * into row_data from public.payment_collections where id=p_collection_id and method='CHEQUE' and status='DEPOSITED' for update;
  if not found then raise exception using errcode='22023', message='Only a deposited cheque can be cleared.'; end if;
  entry_id := public.apply_customer_ledger_delta(row_data.customer_id,-row_data.amount_pkr,'COLLECTION-'||row_data.receipt_number,'Cheque cleared: '||row_data.receipt_number,'PAYMENT');
  update public.payment_collections set status='CLEARED',cleared_at=now(),ledger_entry_id=entry_id where id=p_collection_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'CLEAR_CHEQUE','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('status','CLEARED','ledger_entry_id',entry_id));
  return p_collection_id;
end; $$;
grant execute on function public.clear_cheque_collection(uuid) to authenticated;

create or replace function public.bounce_cheque_collection(p_collection_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare row_data record; entry_id uuid;
begin
  if not public.has_permission(auth.uid(),'collection.verify_deposit') then raise exception using errcode='42501', message='Cheque bounce confirmation is not permitted.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception using errcode='22023', message='Add the cheque bounce reason.'; end if;
  select * into row_data from public.payment_collections where id=p_collection_id and method='CHEQUE' and status in ('DEPOSITED','CLEARED') for update;
  if not found then raise exception using errcode='22023', message='Only a deposited or cleared cheque can be bounced.'; end if;
  if row_data.status='CLEARED' then entry_id := public.apply_customer_ledger_delta(row_data.customer_id,row_data.amount_pkr,'BOUNCE-'||row_data.receipt_number,'Cheque bounced: '||trim(p_reason),'ADJUSTMENT'); end if;
  update public.payment_collections set status='BOUNCED',bounced_reason=trim(p_reason),ledger_entry_id=coalesce(entry_id,ledger_entry_id) where id=p_collection_id;
  insert into public.collection_reminder_preferences(customer_id,open_dispute,updated_by_user_id) values(row_data.customer_id,true,auth.uid()) on conflict(customer_id) do update set open_dispute=true,updated_by_user_id=auth.uid(),updated_at=now();
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'BOUNCE_CHEQUE','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('status','BOUNCED','reason',trim(p_reason),'reversal_entry_id',entry_id));
  insert into public.notifications(user_id,type,title_en,title_ur,body,link_url) select distinct row_data.created_by_user_id,'CHEQUE_BOUNCED','Cheque bounced','Cheque bounced','Cheque '||row_data.receipt_number||' bounced: '||trim(p_reason),'/en/sales/recovery';
  return p_collection_id;
end; $$;
grant execute on function public.bounce_cheque_collection(uuid,text) to authenticated;

create or replace function public.cancel_payment_collection(p_collection_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare row_data record;
begin
  if not public.has_permission(auth.uid(),'collection.cancel') then raise exception using errcode='42501', message='Collection cancellation is not permitted.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception using errcode='22023', message='Add a cancellation reason.'; end if;
  select * into row_data from public.payment_collections where id=p_collection_id and status in ('COLLECTED','DEPOSITED') and (agent_id in (select public.accessible_agent_ids(auth.uid())) or public.has_permission(auth.uid(),'collection.verify_deposit')) for update;
  if not found then raise exception using errcode='42501', message='This collection cannot be cancelled from your scope or status.'; end if;
  update public.payment_collections set status='CANCELLED',notes=coalesce(notes||E'\n','')||'Cancelled: '||trim(p_reason) where id=p_collection_id;
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'CANCEL_COLLECTION','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('reason',trim(p_reason)));
  return p_collection_id;
end; $$;
grant execute on function public.cancel_payment_collection(uuid,text) to authenticated;

create or replace function public.recovery_cash_in_hand(p_agent_id uuid default null)
returns table(agent_id uuid, cash_in_hand_pkr numeric(12,2), oldest_collected_at timestamptz) language sql stable security invoker set search_path=public as $$
  select pc.agent_id, coalesce(sum(pc.amount_pkr),0)::numeric(12,2), min(pc.collected_at) from public.payment_collections pc left join public.cash_deposit_collections cdc on cdc.collection_id=pc.id left join public.cash_deposits cd on cd.id=cdc.deposit_id and cd.status='VERIFIED' where public.has_permission(auth.uid(),'collection.view') and pc.status='COLLECTED' and cd.id is null and (p_agent_id is null or pc.agent_id=p_agent_id) and pc.agent_id in (select public.accessible_agent_ids(auth.uid())) group by pc.agent_id;
$$;
grant execute on function public.recovery_cash_in_hand(uuid) to authenticated;

create or replace function public.agent_recovery_queue(p_agent_id uuid)
returns table(customer_id uuid,business_name text,area_code text,current_balance_pkr numeric(12,2),days_overdue integer,last_payment_at timestamptz,latitude numeric,longitude numeric)
language sql stable security invoker set search_path=public as $$
  with last_payment as (select pc.customer_id,max(pc.cleared_at) filter(where pc.status='CLEARED') last_payment_at from public.payment_collections pc group by pc.customer_id), base as (select c.id,c.business_name,c.area_code,greatest(c.current_balance_pkr,0)::numeric(12,2) balance,c.latitude::numeric,c.longitude::numeric,lp.last_payment_at,coalesce(lp.last_payment_at,max(o.placed_at)) last_activity from public.customers c left join last_payment lp on lp.customer_id=c.id left join public.orders o on o.customer_id=c.id and o.status <> 'CANCELLED' where public.has_permission(auth.uid(),'collection.view') and c.is_internal_account=false and c.current_balance_pkr>0 and c.assigned_agent_id=p_agent_id and p_agent_id in (select public.accessible_agent_ids(auth.uid())) group by c.id,c.business_name,c.area_code,c.current_balance_pkr,c.latitude,c.longitude,lp.last_payment_at) select id,business_name,area_code,balance,greatest(0,(current_date - coalesce(last_activity::date,current_date)))::integer,last_payment_at,latitude,longitude from base order by greatest(0,(current_date-coalesce(last_activity::date,current_date))) desc,balance desc;
$$;
grant execute on function public.agent_recovery_queue(uuid) to authenticated;

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

create or replace function public.credit_risk_score(p_customer_id uuid)
returns table(score numeric(5,2), reasons_json jsonb) language sql stable security invoker set search_path=public as $$
  with stats as (select c.id,greatest(c.current_balance_pkr,0)::numeric(12,2) exposure,count(o.id) filter(where o.status <> 'CANCELLED' and o.placed_at >= now()-interval '180 days') orders_180,count(pc.id) filter(where pc.status='BOUNCED' and pc.collected_at >= now()-interval '365 days') bounces,coalesce(avg(extract(epoch from (pc.cleared_at-pc.collected_at))/86400) filter(where pc.status='CLEARED' and pc.cleared_at is not null),0)::numeric avg_days from public.customers c left join public.orders o on o.customer_id=c.id left join public.payment_collections pc on pc.customer_id=c.id where public.has_permission(auth.uid(),'collection.view') and c.id=p_customer_id and c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) group by c.id,c.current_balance_pkr) select greatest(0,least(100,(least(50,exposure/10000)+(least(30,bounces*15))+(least(20,greatest(0,avg_days-30)/3)))::numeric(5,2)))::numeric(5,2),jsonb_build_array(jsonb_build_object('factor','current exposure','value',exposure),jsonb_build_object('factor','cheque bounces','value',bounces),jsonb_build_object('factor','average days to pay','value',round(avg_days,2))) from stats;
$$;
grant execute on function public.credit_risk_score(uuid) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('collection-photos','collection-photos',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy collection_photos_read on storage.objects for select to authenticated
using (bucket_id='collection-photos' and ((storage.foldername(name))[1]=auth.uid()::text or public.has_permission(auth.uid(),'collection.view')));
create policy collection_photos_insert on storage.objects for insert to authenticated
with check (bucket_id='collection-photos' and (storage.foldername(name))[1]=auth.uid()::text and coalesce((metadata->>'size')::bigint,0)<=5242880 and coalesce(metadata->>'mimetype','') in ('image/jpeg','image/png','image/webp','application/pdf'));
create policy collection_photos_update on storage.objects for update to authenticated
using (bucket_id='collection-photos' and (storage.foldername(name))[1]=auth.uid()::text)
with check (bucket_id='collection-photos' and (storage.foldername(name))[1]=auth.uid()::text);
create policy collection_photos_delete on storage.objects for delete to authenticated
using (bucket_id='collection-photos' and (storage.foldername(name))[1]=auth.uid()::text);

create or replace function public.admin_recovery_agent_progress(p_month date default ((now() at time zone 'Asia/Karachi')::date - ((extract(day from (now() at time zone 'Asia/Karachi'))::integer - 1) * interval '1 day'))::date)
returns table(agent_id uuid, agent_name text, target_amount_pkr numeric(12,2), recovered_amount_pkr numeric(12,2), progress_percent numeric(6,2)) language sql stable security invoker set search_path=public as $$
  with collected as (select pc.agent_id,coalesce(sum(pc.amount_pkr) filter(where pc.status in ('CLEARED','DEPOSITED')),0)::numeric(12,2) recovered from public.payment_collections pc where pc.collected_at >= p_month::timestamptz and pc.collected_at < (p_month + interval '1 month')::timestamptz group by pc.agent_id), targets as (select rt.agent_id,rt.target_amount_pkr from public.recovery_targets rt where rt.month=p_month) select sa.id,u.full_name,coalesce(t.target_amount_pkr,0)::numeric(12,2),coalesce(c.recovered,0)::numeric(12,2),case when coalesce(t.target_amount_pkr,0)>0 then round((coalesce(c.recovered,0)*100/t.target_amount_pkr),2)::numeric(6,2) else 0::numeric(6,2) end from public.sales_agents sa join public.users u on u.id=sa.user_id left join targets t on t.agent_id=sa.id left join collected c on c.agent_id=sa.id where public.has_permission(auth.uid(),'collection.view') and public.has_permission(auth.uid(),'financials.view_revenue') order by u.full_name;
$$;
grant execute on function public.admin_recovery_agent_progress(date) to authenticated;

create or replace function public.admin_pending_recovery_deposits()
returns table(deposit_id uuid,agent_id uuid,agent_name text,total_amount_pkr numeric(12,2),deposited_at timestamptz,age_days integer,collection_count integer,deposit_slip_url text,notes text) language sql stable security invoker set search_path=public as $$
  select cd.id,cd.agent_id,u.full_name,cd.total_amount_pkr,cd.deposited_at,greatest(0,(current_date-cd.deposited_at::date))::integer,count(cdc.collection_id)::integer,cd.deposit_slip_url,cd.notes from public.cash_deposits cd join public.sales_agents sa on sa.id=cd.agent_id join public.users u on u.id=sa.user_id left join public.cash_deposit_collections cdc on cdc.deposit_id=cd.id where public.has_permission(auth.uid(),'collection.verify_deposit') and cd.status='PENDING' group by cd.id,cd.agent_id,u.full_name,cd.total_amount_pkr,cd.deposited_at,cd.deposit_slip_url,cd.notes order by cd.deposited_at asc;
$$;
grant execute on function public.admin_pending_recovery_deposits() to authenticated;

create or replace function public.admin_bounced_cheques()
returns table(collection_id uuid,customer_id uuid,business_name text,agent_name text,amount_pkr numeric(12,2),receipt_number text,cheque_number text,bank_name text,bounced_reason text,collected_at timestamptz) language sql stable security invoker set search_path=public as $$
  select pc.id,pc.customer_id,c.business_name,u.full_name,pc.amount_pkr,pc.receipt_number,pc.cheque_number,pc.bank_name,pc.bounced_reason,pc.collected_at from public.payment_collections pc join public.customers c on c.id=pc.customer_id join public.sales_agents sa on sa.id=pc.agent_id join public.users u on u.id=sa.user_id where public.has_permission(auth.uid(),'collection.verify_deposit') and pc.status='BOUNCED' order by pc.collected_at desc;
$$;
grant execute on function public.admin_bounced_cheques() to authenticated;

create or replace function public.admin_top_overdue_recovery()
returns table(customer_id uuid,business_name text,assigned_agent text,balance_pkr numeric(12,2),days_overdue integer,last_payment_at timestamptz,credit_limit_pkr numeric(12,2),over_credit_limit boolean) language sql stable security invoker set search_path=public as $$
  with payments as (select pc.customer_id,max(pc.cleared_at) filter(where pc.status='CLEARED') last_payment_at from public.payment_collections pc group by pc.customer_id), orders_last as (select o.customer_id,max(o.placed_at) last_order_at from public.orders o where o.status <> 'CANCELLED' group by o.customer_id) select c.id,c.business_name,u.full_name,greatest(c.current_balance_pkr,0)::numeric(12,2),greatest(0,current_date-coalesce(p.last_payment_at::date,o.last_order_at::date,current_date))::integer,p.last_payment_at,c.credit_limit_pkr,(c.current_balance_pkr>c.credit_limit_pkr) from public.customers c left join public.sales_agents sa on sa.id=c.assigned_agent_id left join public.users u on u.id=sa.user_id left join payments p on p.customer_id=c.id left join orders_last o on o.customer_id=c.id where public.has_permission(auth.uid(),'collection.view') and public.has_permission(auth.uid(),'financials.view_revenue') and c.is_internal_account=false and c.current_balance_pkr>0 order by greatest(0,current_date-coalesce(p.last_payment_at::date,o.last_order_at::date,current_date)) desc,c.current_balance_pkr desc limit 20;
$$;
grant execute on function public.admin_top_overdue_recovery() to authenticated;
