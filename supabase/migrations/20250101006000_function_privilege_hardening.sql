-- Security hardening: internal SECURITY DEFINER functions were executable by
-- every logged-in user (Supabase grants EXECUTE on public functions to anon and
-- authenticated by default). Several of them have no permission check of their
-- own, e.g. apply_loyalty_delta could give any Vendor free loyalty points and
-- apply_customer_ledger_delta could rewrite any customer balance.
--
-- Rule after this migration:
--   * system-job functions  -> service_role only (cron routes use the system client)
--   * internal helpers      -> no direct EXECUTE for anon/authenticated; they are
--                              reached only through permission-checked callers
--   * permission-checked user entry points that call an internal helper are
--     SECURITY DEFINER, so the helper no longer needs a user grant.

-- 1. The user-facing callers of internal helpers become SECURITY DEFINER.
--    Each one already checks has_permission(auth.uid(), ...) first; auth.uid()
--    still returns the calling user under SECURITY DEFINER.
alter function public.approve_loyalty_redemption(uuid, uuid) security definer;
alter function public.approve_loyalty_redemption(uuid, uuid) set search_path = public;
alter function public.adjust_loyalty_points(uuid, integer, text) security definer;
alter function public.adjust_loyalty_points(uuid, integer, text) set search_path = public;
alter function public.record_admin_ledger_payment(uuid, numeric, text, text, timestamptz) security definer;
alter function public.record_admin_ledger_payment(uuid, numeric, text, text, timestamptz) set search_path = public;
alter function public.resolve_claim(uuid, numeric, text) security definer;
alter function public.resolve_claim(uuid, numeric, text) set search_path = public;
alter function public.activate_price_list(uuid) security definer;
alter function public.activate_price_list(uuid) set search_path = public;

-- 2. Lock down internal helpers and system jobs.
do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        -- system jobs (called only by cron routes through the service-role client)
        'activate_due_price_lists', 'claim_communications_messages', 'claim_sla_admin_user_ids',
        'claim_sla_breach_rows', 'claim_voice_notes', 'delete_expired_voice_notes',
        'generate_admin_anomaly_alerts', 'list_expired_voice_notes', 'mark_voice_note_failed',
        'purge_expired_voice_notes', 'queue_due_admin_reports', 'queue_due_recovery_reminders',
        'reconcile_loyalty_balances',
        -- internal helpers (reached only from permission-checked SECURITY DEFINER code or triggers)
        'accrue_order_loyalty', 'reverse_order_loyalty', 'activate_price_list_internal',
        'active_vendor_cart', 'apply_customer_ledger_delta', 'apply_loyalty_delta',
        'assert_cart_ready_for_checkout', 'recovery_audit', 'redeem_order_points',
        'record_delivery_cod_collection', 'refresh_cart_prices'
      )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn.sig);
    execute format('grant execute on function %s to service_role', fn.sig);
  end loop;
end $$;

-- 3. vendor_customer_for_user(uuid) must not reveal another user's customer link.
create or replace function public.vendor_customer_for_user(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select linked.customer_id
  from (
    select cu.customer_id, 1 as priority from public.customer_users cu where cu.user_id = p_user_id
    union all
    select va.customer_id, 2 as priority from public.vendor_accounts va where va.user_id = p_user_id
  ) linked
  where p_user_id = auth.uid()
     or public.has_permission(auth.uid(), 'user.view')
     or auth.role() = 'service_role'
  order by linked.priority
  limit 1;
$$;
revoke all on function public.vendor_customer_for_user(uuid) from public, anon;
grant execute on function public.vendor_customer_for_user(uuid) to authenticated, service_role;

-- 4. A GLOBAL-scope admin must be able to record a payment for a customer
--    that has no Sales Agent yet (assigned_agent_id is null).
create or replace function public.record_admin_ledger_payment(p_customer_id uuid, p_amount_pkr numeric, p_reference text, p_description text, p_entry_date timestamp with time zone default now())
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare entry_id uuid;
begin
  if not public.has_permission(auth.uid(),'ledger.record_payment') then raise exception using errcode='42501', message='Recording a payment is not permitted.'; end if;
  if p_amount_pkr <= 0 or nullif(trim(p_reference),'') is null or nullif(trim(p_description),'') is null then raise exception using errcode='22023', message='Enter a positive payment, reference, and description.'; end if;
  if not exists(
    select 1 from public.customers c
    where c.id = p_customer_id
      and (public.role_scope(auth.uid()) = 'GLOBAL' or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())))
  ) then raise exception using errcode='42501', message='This customer is outside your scope.'; end if;
  entry_id := public.apply_customer_ledger_delta(p_customer_id,-abs(p_amount_pkr),p_reference,p_description,'PAYMENT',p_entry_date);
  insert into public.audit_logs(user_id,action,entity_type,entity_id,changes_json) values(auth.uid(),'RECORD_PAYMENT','LEDGER',entry_id::text,jsonb_build_object('customer_id',p_customer_id,'amount_pkr',(-abs(p_amount_pkr))::numeric(12,2)));
  return entry_id;
end; $$;
