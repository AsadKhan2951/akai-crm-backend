-- Phase 11 hardening is additive. Do not edit 0014_payment_recovery.

create or replace function public.set_collection_reminder_preference(
  p_customer_id uuid,
  p_opted_out boolean,
  p_preferred_locale text default 'en'
) returns uuid
language plpgsql security invoker set search_path = public as $$
begin
  if not public.has_permission(auth.uid(),'collection.reminder') then
    raise exception using errcode='42501', message='Collection reminder permission is required.';
  end if;
  if p_preferred_locale not in ('en','ur') then
    raise exception using errcode='22023', message='Locale must be en or ur.';
  end if;
  if not exists (
    select 1 from public.customers c
    where c.id=p_customer_id
      and c.is_internal_account=false
      and (c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or public.role_scope(auth.uid())='GLOBAL')
  ) then
    raise exception using errcode='42501', message='This customer is outside your recovery scope.';
  end if;
  insert into public.collection_reminder_preferences(customer_id,opted_out,preferred_locale,updated_by_user_id)
  values(p_customer_id,p_opted_out,p_preferred_locale,auth.uid())
  on conflict(customer_id) do update set opted_out=excluded.opted_out,preferred_locale=excluded.preferred_locale,updated_by_user_id=auth.uid(),updated_at=now()
  returning customer_id;
end; $$;
grant execute on function public.set_collection_reminder_preference(uuid,boolean,text) to authenticated;

create or replace function public.admin_deposited_cheques()
returns table(collection_id uuid,customer_id uuid,business_name text,agent_name text,amount_pkr numeric(12,2),receipt_number text,cheque_number text,cheque_date date,bank_name text,deposited_at timestamptz)
language sql stable security invoker set search_path=public as $$
  select pc.id,pc.customer_id,c.business_name,u.full_name,pc.amount_pkr,pc.receipt_number,pc.cheque_number,pc.cheque_date,pc.bank_name,pc.deposited_at
  from public.payment_collections pc
  join public.customers c on c.id=pc.customer_id
  join public.sales_agents sa on sa.id=pc.agent_id
  join public.users u on u.id=sa.user_id
  where public.has_permission(auth.uid(),'collection.verify_deposit')
    and pc.method='CHEQUE' and pc.status='DEPOSITED'
  order by pc.deposited_at asc;
$$;
grant execute on function public.admin_deposited_cheques() to authenticated;

create or replace function public.save_credit_risk_snapshot(p_customer_id uuid)
returns uuid
language plpgsql security invoker set search_path=public as $$
declare score_row record; snapshot_id uuid;
begin
  if not public.has_permission(auth.uid(),'collection.view') then
    raise exception using errcode='42501', message='Recovery view permission is required.';
  end if;
  if not exists (
    select 1 from public.customers c where c.id=p_customer_id and (c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or public.role_scope(auth.uid())='GLOBAL')
  ) then
    raise exception using errcode='42501', message='This customer is outside your recovery scope.';
  end if;
  select * into score_row from public.credit_risk_score(p_customer_id);
  if not found then raise exception using errcode='P0002', message='Risk score data is not available.'; end if;
  insert into public.credit_risk_snapshots(customer_id,score,reasons_json,model_version)
  values(p_customer_id,score_row.score,score_row.reasons_json,'sql-v1') returning id into snapshot_id;
  return snapshot_id;
end; $$;
grant execute on function public.save_credit_risk_snapshot(uuid) to authenticated;

-- Deterministic reminder drafts are queued by a system job; the queue is never sent here.
create or replace function public.queue_due_recovery_reminders(p_threshold_days integer default 30)
returns integer
language plpgsql security definer set search_path=public as $$
declare queued_count integer;
begin
  if p_threshold_days <= 0 then raise exception using errcode='22023', message='Threshold must be positive.'; end if;
  insert into public.recovery_reminder_queue(customer_id,agent_id,channel,locale,threshold_days,body,against_invoice_numbers,status,scheduled_for,created_by_user_id)
  select c.id,c.assigned_agent_id,'WHATSAPP',coalesce(crp.preferred_locale,'en'),p_threshold_days,
    case when coalesce(crp.preferred_locale,'en')='ur' then 'آپ کے account میں overdue balance موجود ہے۔ براہ کرم AKAI سے رابطہ کریں۔' else 'Your AKAI account has an overdue balance. Please contact AKAI to arrange payment.' end,
    '{}','QUEUED',now(),coalesce(c.assigned_agent_id,'00000000-0000-0000-0000-000000000000'::uuid)
  from public.customers c
  left join public.collection_reminder_preferences crp on crp.customer_id=c.id
  where c.is_internal_account=false and c.current_balance_pkr>0
    and coalesce(crp.opted_out,false)=false and coalesce(crp.open_dispute,false)=false
    and not exists(select 1 from public.recovery_reminder_queue q where q.customer_id=c.id and q.threshold_days=p_threshold_days and q.status in ('QUEUED','SENT') and q.created_at >= now()-interval '7 days');
  get diagnostics queued_count = row_count;
  return queued_count;
end; $$;
revoke all on function public.queue_due_recovery_reminders(integer) from public, authenticated;

create index if not exists payment_collections_customer_status_amount_idx on public.payment_collections(customer_id,status,amount_pkr);
create index if not exists collection_reminder_preferences_opted_out_idx on public.collection_reminder_preferences(opted_out,open_dispute);

-- Corrected queue ownership and cheque reversal linkage.
create or replace function public.queue_due_recovery_reminders(p_threshold_days integer default 30)
returns integer
language plpgsql security definer set search_path=public as $$
declare queued_count integer;
begin
  if p_threshold_days <= 0 then raise exception using errcode='22023', message='Threshold must be positive.'; end if;
  insert into public.recovery_reminder_queue(customer_id,agent_id,channel,locale,threshold_days,body,against_invoice_numbers,status,scheduled_for,created_by_user_id)
  select c.id,c.assigned_agent_id,'WHATSAPP',coalesce(crp.preferred_locale,'en'),p_threshold_days,
    case when coalesce(crp.preferred_locale,'en')='ur' then 'آپ کے account میں overdue balance موجود ہے۔ براہ کرم AKAI سے رابطہ کریں۔' else 'Your AKAI account has an overdue balance. Please contact AKAI to arrange payment.' end,
    '{}','QUEUED',now(),sa.user_id
  from public.customers c
  join public.sales_agents sa on sa.id=c.assigned_agent_id
  left join public.collection_reminder_preferences crp on crp.customer_id=c.id
  where c.is_internal_account=false and c.current_balance_pkr>0
    and coalesce(crp.opted_out,false)=false and coalesce(crp.open_dispute,false)=false
    and not exists(select 1 from public.recovery_reminder_queue q where q.customer_id=c.id and q.threshold_days=p_threshold_days and q.status in ('QUEUED','SENT') and q.created_at >= now()-interval '7 days');
  get diagnostics queued_count = row_count;
  return queued_count;
end; $$;
revoke all on function public.queue_due_recovery_reminders(integer) from public, authenticated;

create or replace function public.bounce_cheque_collection(p_collection_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare row_data record; reversal_entry_id uuid;
begin
  if not public.has_permission(auth.uid(),'collection.verify_deposit') then raise exception using errcode='42501', message='Cheque bounce confirmation is not permitted.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception using errcode='22023', message='Add the cheque bounce reason.'; end if;
  select * into row_data from public.payment_collections where id=p_collection_id and method='CHEQUE' and status in ('DEPOSITED','CLEARED') for update;
  if not found then raise exception using errcode='22023', message='Only a deposited or cleared cheque can be bounced.'; end if;
  if row_data.status='CLEARED' then
    reversal_entry_id := public.apply_customer_ledger_delta(row_data.customer_id,row_data.amount_pkr,'BOUNCE-'||row_data.receipt_number,'Cheque bounced: '||trim(p_reason),'ADJUSTMENT');
  end if;
  update public.payment_collections set status='BOUNCED',bounced_reason=trim(p_reason) where id=p_collection_id;
  insert into public.collection_reminder_preferences(customer_id,open_dispute,updated_by_user_id) values(row_data.customer_id,true,auth.uid()) on conflict(customer_id) do update set open_dispute=true,updated_by_user_id=auth.uid(),updated_at=now();
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'BOUNCE_CHEQUE','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('status','BOUNCED','reason',trim(p_reason),'reversal_entry_id',reversal_entry_id,'original_ledger_entry_id',row_data.ledger_entry_id));
  insert into public.notifications(user_id,type,title_en,title_ur,body,link_url) select distinct row_data.created_by_user_id,'CHEQUE_BOUNCED','Cheque bounced','Cheque bounced','Cheque '||row_data.receipt_number||' bounced: '||trim(p_reason),'/en/sales/recovery';
  return p_collection_id;
end; $$;
grant execute on function public.bounce_cheque_collection(uuid,text) to authenticated;
