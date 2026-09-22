-- AKAI CRM Phase 15: confirmed customer hard-delete boundary.
-- A customer with transactional history is retained and cannot be hard-deleted.

create or replace function public.hard_delete_customer(p_customer_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.has_permission(auth.uid(), 'customer.delete') then
    raise exception using errcode = '42501', message = 'Customer deletion is not permitted.';
  end if;
  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'A customer is required.';
  end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.is_internal_account = false) then
    raise exception using errcode = '40400', message = 'Customer not found or outside your scope.';
  end if;
  if exists (select 1 from public.orders where customer_id = p_customer_id)
     or exists (select 1 from public.quotes where customer_id = p_customer_id)
     or exists (select 1 from public.ledger_entries where customer_id = p_customer_id)
     or exists (select 1 from public.payment_collections where customer_id = p_customer_id)
     or exists (select 1 from public.loyalty_transactions where customer_id = p_customer_id)
     or exists (select 1 from public.activities where customer_id = p_customer_id)
     or exists (select 1 from public.follow_ups where customer_id = p_customer_id) then
    raise exception using errcode = '23514', message = 'This customer has history and must be retained. Use the inactive status instead.';
  end if;
  delete from public.customer_users where customer_id = p_customer_id;
  delete from public.customers where id = p_customer_id;
end;
$$;

grant execute on function public.hard_delete_customer(uuid) to authenticated;
