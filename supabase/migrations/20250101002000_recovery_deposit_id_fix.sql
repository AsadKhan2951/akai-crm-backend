-- Corrective Phase 11 migration. Do not edit earlier recovery migrations.
create or replace function public.submit_cash_deposit(p_collection_ids uuid[], p_total_amount_pkr numeric, p_deposit_slip_url text default null, p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_agent_id uuid; deposit_id uuid; selected_total numeric(12,2);
begin
  if not public.has_permission(auth.uid(),'collection.deposit') then raise exception using errcode='42501', message='Cash deposit submission is not permitted.'; end if;
  if coalesce(array_length(p_collection_ids,1),0)=0 or p_total_amount_pkr<=0 then raise exception using errcode='22023', message='Select at least one collection and enter a positive deposit total.'; end if;
  select sa.id into v_agent_id from public.sales_agents sa where sa.user_id=auth.uid();
  if not found then raise exception using errcode='42501', message='Your Sales Agent account is not configured.'; end if;
  select coalesce(sum(pc.amount_pkr),0)::numeric(12,2) into selected_total from public.payment_collections pc where pc.id=any(p_collection_ids) and pc.agent_id=v_agent_id and pc.status='COLLECTED';
  perform 1 from public.payment_collections pc where pc.id=any(p_collection_ids) and pc.agent_id=v_agent_id and pc.status='COLLECTED' for update;
  if selected_total <> p_total_amount_pkr then raise exception using errcode='22023', message='Deposit total must exactly match the selected collected amounts.'; end if;
  deposit_id := gen_random_uuid();
  insert into public.cash_deposits(id,agent_id,total_amount_pkr,deposit_slip_url,notes,created_by_user_id) values(deposit_id,v_agent_id,p_total_amount_pkr,p_deposit_slip_url,nullif(trim(p_notes),''),auth.uid());
  insert into public.cash_deposit_collections(deposit_id,collection_id) select deposit_id,unnest(p_collection_ids);
  perform public.recovery_audit('SUBMIT_DEPOSIT','CASH_DEPOSIT',deposit_id::text,jsonb_build_object('total_amount_pkr',p_total_amount_pkr,'collection_count',array_length(p_collection_ids,1)));
  return deposit_id;
end; $$;
grant execute on function public.submit_cash_deposit(uuid[],numeric,text,text) to authenticated;
