-- Corrective Phase 11 migration. Do not edit 0014, 0015, or 0016.
create or replace function public.recovery_audit(p_action text, p_entity_type text, p_entity_id text, p_after jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.audit_logs(id,actor_user_id,entity_type,entity_id,action,after_data)
  values(gen_random_uuid()::text,auth.uid(),p_entity_type,p_entity_id,p_action,p_after);
end; $$;
revoke all on function public.recovery_audit(text,text,text,jsonb) from public,authenticated;

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
  values(gen_random_uuid(),p_customer_id,agent_id,abs(p_amount_pkr)::numeric(12,2),p_method,nullif(trim(p_cheque_number),''),p_cheque_date,nullif(trim(p_bank_name),''),new_receipt,coalesce(p_against_invoice_numbers,'{}'),p_latitude,p_longitude,p_photo_url,nullif(trim(p_notes),''),auth.uid()) returning id into new_id;
  perform public.recovery_audit('RECORD_COLLECTION','PAYMENT_COLLECTION',new_id::text,jsonb_build_object('customer_id',p_customer_id,'amount_pkr',abs(p_amount_pkr)::numeric(12,2),'method',p_method,'receipt_number',new_receipt));
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
  perform public.recovery_audit('SUBMIT_DEPOSIT','CASH_DEPOSIT',deposit_id::text,jsonb_build_object('total_amount_pkr',p_total_amount_pkr,'collection_count',array_length(p_collection_ids,1)));
  return deposit_id;
end; $$;
grant execute on function public.submit_cash_deposit(uuid[],numeric,text,text) to authenticated;

create or replace function public.verify_cash_deposit(p_deposit_id uuid, p_status public."CashDepositStatus", p_note text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare collection_row record; verified_total numeric(12,2); deposit_agent uuid;
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
        update public.payment_collections set status='CLEARED',deposited_at=now(),cleared_at=now(),ledger_entry_id=public.apply_customer_ledger_delta(collection_row.customer_id,-collection_row.amount_pkr,'COLLECTION-'||collection_row.receipt_number,'Collection cleared: '||collection_row.receipt_number,'PAYMENT') where id=collection_row.id;
      end if;
      perform public.recovery_audit('VERIFY_COLLECTION','PAYMENT_COLLECTION',collection_row.id::text,jsonb_build_object('status',case when collection_row.method='CHEQUE' then 'DEPOSITED' else 'CLEARED' end,'deposit_id',p_deposit_id));
    end loop;
  end if;
  perform public.recovery_audit('VERIFY_DEPOSIT','CASH_DEPOSIT',p_deposit_id::text,jsonb_build_object('status',p_status,'total_amount_pkr',verified_total,'note',p_note));
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
  perform public.recovery_audit('CLEAR_CHEQUE','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('status','CLEARED','ledger_entry_id',entry_id));
  return p_collection_id;
end; $$;
grant execute on function public.clear_cheque_collection(uuid) to authenticated;

create or replace function public.cancel_payment_collection(p_collection_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare row_data record;
begin
  if not public.has_permission(auth.uid(),'collection.cancel') then raise exception using errcode='42501', message='Collection cancellation is not permitted.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception using errcode='22023', message='Add a cancellation reason.'; end if;
  select * into row_data from public.payment_collections where id=p_collection_id and status in ('COLLECTED','DEPOSITED') and (agent_id in (select public.accessible_agent_ids(auth.uid())) or public.has_permission(auth.uid(),'collection.verify_deposit')) for update;
  if not found then raise exception using errcode='42501', message='This collection cannot be cancelled from your scope or status.'; end if;
  update public.payment_collections set status='CANCELLED',notes=coalesce(notes||E'\\n','')||'Cancelled: '||trim(p_reason) where id=p_collection_id;
  perform public.recovery_audit('CANCEL_COLLECTION','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('reason',trim(p_reason)));
  return p_collection_id;
end; $$;
grant execute on function public.cancel_payment_collection(uuid,text) to authenticated;
