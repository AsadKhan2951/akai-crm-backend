-- Corrective Phase 11 migration. Do not edit earlier recovery migrations.
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
  perform public.recovery_audit('BOUNCE_CHEQUE','PAYMENT_COLLECTION',p_collection_id::text,jsonb_build_object('status','BOUNCED','reason',trim(p_reason),'reversal_entry_id',reversal_entry_id,'original_ledger_entry_id',row_data.ledger_entry_id));
  insert into public.notifications(id,user_id,type,title_en,title_ur,body,link_url) values(gen_random_uuid(),row_data.created_by_user_id,'CHEQUE_BOUNCED','Cheque bounced','Cheque bounced','Cheque '||row_data.receipt_number||' bounced: '||trim(p_reason),'/en/sales/recovery');
  return p_collection_id;
end; $$;
grant execute on function public.bounce_cheque_collection(uuid,text) to authenticated;
