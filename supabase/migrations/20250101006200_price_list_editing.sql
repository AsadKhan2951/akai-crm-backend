-- Price-list editing helpers used by the Admin price-list screens.
-- Prices are only edited on DRAFT lists; activation stays in activate_price_list().

create or replace function public.create_price_list_draft(p_name text, p_effective_from timestamptz, p_clone_active boolean default true, p_notes text default null)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_list_id uuid;
  v_active_id uuid;
  v_approval_required boolean := true;
begin
  if not public.has_permission(auth.uid(), 'pricelist.create') then
    raise exception using errcode = '42501', message = 'Creating price lists is not permitted.';
  end if;
  if nullif(trim(p_name), '') is null or p_effective_from is null then
    raise exception using errcode = '22023', message = 'Enter a name and an effective date.';
  end if;
  select coalesce((s.value_json->>'required')::boolean, true) into v_approval_required
    from public.settings s where s.key = 'price_list_approval_required';
  v_approval_required := coalesce(v_approval_required, true);
  select id into v_active_id from public.price_lists where status = 'ACTIVE' order by activated_at desc nulls last limit 1;

  insert into public.price_lists (name, effective_from, status, based_on_price_list_id, notes, created_by_user_id, approval_required, approval_status)
  values (trim(p_name), p_effective_from, 'DRAFT', case when p_clone_active then v_active_id end, nullif(trim(p_notes), ''), auth.uid(),
          v_approval_required, case when v_approval_required then 'PENDING'::"PriceListApprovalStatus" else 'NOT_REQUIRED'::"PriceListApprovalStatus" end)
  returning id into v_list_id;

  if p_clone_active then
    if v_active_id is not null then
      insert into public.price_list_items (price_list_id, product_id, price_pkr, compare_at_price_pkr)
      select v_list_id, pli.product_id, pli.price_pkr, pli.compare_at_price_pkr
      from public.price_list_items pli where pli.price_list_id = v_active_id;
    end if;
    -- Products that are not on the active list start from their current cached price.
    insert into public.price_list_items (price_list_id, product_id, price_pkr, compare_at_price_pkr)
    select v_list_id, p.id, p.price_pkr, p.compare_at_price_pkr
    from public.products p
    where p.is_active
    on conflict (price_list_id, product_id) do nothing;
  end if;
  return v_list_id;
end;
$$;
grant execute on function public.create_price_list_draft(text, timestamptz, boolean, text) to authenticated;

create or replace function public.set_price_list_item(p_price_list_id uuid, p_product_id uuid, p_price_pkr numeric, p_compare_at_price_pkr numeric default null, p_cost_pkr numeric default null)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare v_item_id uuid;
begin
  if not public.has_permission(auth.uid(), 'pricelist.create') then
    raise exception using errcode = '42501', message = 'Editing price lists is not permitted.';
  end if;
  if p_price_pkr is null or p_price_pkr < 0 then
    raise exception using errcode = '22023', message = 'Enter a price of zero or more.';
  end if;
  perform 1 from public.price_lists where id = p_price_list_id and status = 'DRAFT' for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'Only a DRAFT price list can be edited.';
  end if;
  insert into public.price_list_items (price_list_id, product_id, price_pkr, compare_at_price_pkr)
  values (p_price_list_id, p_product_id, p_price_pkr::numeric(12,2), p_compare_at_price_pkr::numeric(12,2))
  on conflict (price_list_id, product_id) do update set price_pkr = excluded.price_pkr, compare_at_price_pkr = excluded.compare_at_price_pkr
  returning id into v_item_id;
  if p_cost_pkr is not null then
    if not public.has_permission(auth.uid(), 'product.view_cost') then
      raise exception using errcode = '42501', message = 'Editing cost is not permitted.';
    end if;
    insert into public.price_list_item_costs (price_list_item_id, cost_pkr) values (v_item_id, p_cost_pkr::numeric(12,2))
    on conflict (price_list_item_id) do update set cost_pkr = excluded.cost_pkr;
  end if;
  return v_item_id;
end;
$$;
grant execute on function public.set_price_list_item(uuid, uuid, numeric, numeric, numeric) to authenticated;

create or replace function public.remove_price_list_item(p_price_list_id uuid, p_product_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.has_permission(auth.uid(), 'pricelist.create') then
    raise exception using errcode = '42501', message = 'Editing price lists is not permitted.';
  end if;
  perform 1 from public.price_lists where id = p_price_list_id and status = 'DRAFT';
  if not found then
    raise exception using errcode = 'P0001', message = 'Only a DRAFT price list can be edited.';
  end if;
  delete from public.price_list_items where price_list_id = p_price_list_id and product_id = p_product_id;
end;
$$;
grant execute on function public.remove_price_list_item(uuid, uuid) to authenticated;
