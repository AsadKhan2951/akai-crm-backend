-- AKAI CRM 0009 vendor portal workflows (RECONSTRUCTED).
-- The original file was missing from the recovered source. Rebuilt from the README, the contract tests,
-- the Vendor server actions that call these functions, and the later wrappers in 0037/0038.
-- Every function checks that the caller is linked to the customer, re-checks product visibility through
-- resolve_visible_products and snapshots prices at the moment they are written.

-- The customer account a vendor user belongs to (customer_users or vendor_accounts).
create or replace function public.vendor_customer_for_user(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select linked.customer_id from (
    select cu.customer_id, 1 as priority from public.customer_users cu where cu.user_id = p_user_id
    union all
    select va.customer_id, 2 as priority from public.vendor_accounts va where va.user_id = p_user_id
  ) linked
  where p_user_id = auth.uid() or public.has_permission(auth.uid(), 'user.view')
  order by linked.priority
  limit 1;
$$;
grant execute on function public.vendor_customer_for_user(uuid) to authenticated;

create or replace function public.require_vendor_customer(p_permission text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_customer_id uuid;
begin
  if auth.uid() is null or not public.has_permission(auth.uid(), p_permission) then
    raise exception using errcode = '42501', message = 'This vendor action is not permitted.';
  end if;
  v_customer_id := public.vendor_customer_for_user(auth.uid());
  if v_customer_id is null then
    raise exception using errcode = '42501', message = 'Your Vendor account is not linked to a customer.';
  end if;
  return v_customer_id;
end;
$$;
revoke all on function public.require_vendor_customer(text) from public;
grant execute on function public.require_vendor_customer(text) to authenticated;

create or replace function public.active_vendor_cart(p_customer_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_cart_id uuid;
begin
  select c.id into v_cart_id from public.carts c where c.customer_id = p_customer_id and c.status = 'ACTIVE' for update;
  if v_cart_id is null then
    insert into public.carts (customer_id, status, last_priced_at) values (p_customer_id, 'ACTIVE', now()) returning id into v_cart_id;
  end if;
  return v_cart_id;
end;
$$;
revoke all on function public.active_vendor_cart(uuid) from public;

-- Add a visible, orderable product to the vendor's active cart. Returns the cart line id.
create or replace function public.add_vendor_cart_line(p_product_id uuid, p_quantity numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('order.create');
  v_cart_id uuid;
  visible_product record;
  price_row record;
  v_line_id uuid;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception using errcode = '22023', message = 'Quantity must be greater than zero.';
  end if;
  select * into visible_product from public.resolve_visible_products(v_customer_id) vp where vp.id = p_product_id and vp.is_active;
  if not found then raise exception using errcode = '42501', message = 'This product is not available to your account.'; end if;
  if visible_product.is_quote_only then raise exception using errcode = '22023', message = 'This product is available by quote only.'; end if;
  select * into price_row from public.effective_product_price(p_product_id, now());
  v_cart_id := public.active_vendor_cart(v_customer_id);
  insert into public.cart_lines as cl (cart_id, product_id, quantity, unit_price_pkr, price_list_id, price_list_item_id)
    values (v_cart_id, p_product_id, p_quantity, visible_product.price_pkr, price_row.price_list_id, price_row.price_list_item_id)
    on conflict on constraint cart_lines_cart_id_product_id_key do update set quantity = cl.quantity + excluded.quantity, updated_at = now()
    returning cl.id into v_line_id;
  update public.carts c set updated_at = now() where c.id = v_cart_id;
  return v_line_id;
end;
$$;
grant execute on function public.add_vendor_cart_line(uuid, numeric) to authenticated;

-- Change a cart quantity; zero or less removes the line.
create or replace function public.update_vendor_cart_line(p_cart_line_id uuid, p_quantity numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('order.create');
  line_cart uuid;
begin
  select cl.cart_id into line_cart from public.cart_lines cl join public.carts c on c.id = cl.cart_id
    where cl.id = p_cart_line_id and c.customer_id = v_customer_id and c.status = 'ACTIVE';
  if line_cart is null then raise exception using errcode = '42501', message = 'This cart line is outside your account.'; end if;
  if p_quantity is null or p_quantity <= 0 then
    delete from public.cart_lines where id = p_cart_line_id;
  else
    update public.cart_lines set quantity = p_quantity, updated_at = now() where id = p_cart_line_id;
  end if;
  update public.carts set updated_at = now() where id = line_cart;
end;
$$;
grant execute on function public.update_vendor_cart_line(uuid, numeric) to authenticated;

-- Cart totals are always computed in PostgreSQL.
create or replace function public.vendor_cart_totals(p_cart_id uuid)
returns table (line_count integer, item_quantity numeric, subtotal_pkr numeric, requires_price_review boolean)
language sql
stable
security invoker
set search_path = public
as $$
  select count(cl.id)::integer, coalesce(sum(cl.quantity), 0), coalesce(sum((cl.unit_price_pkr * cl.quantity)::numeric(12,2)), 0)::numeric(12,2), c.requires_price_review
  from public.carts c
  left join public.cart_lines cl on cl.cart_id = c.id
  where c.id = p_cart_id
  group by c.id, c.requires_price_review;
$$;
grant execute on function public.vendor_cart_totals(uuid) to authenticated;

-- Points redemption at checkout. Uses the loyalty service when it exists (0043+).
create or replace function public.redeem_order_points(p_customer_id uuid, p_order_id uuid, p_points integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare current_points integer;
begin
  if p_points <= 0 then return; end if;
  if to_regprocedure('public.apply_loyalty_delta(uuid,integer,text,uuid,uuid,text,uuid)') is not null then
    execute 'select public.apply_loyalty_delta($1, $2, $3, $4, null, $5, $6)'
      using p_customer_id, -p_points, 'ORDER_POINTS_REDEEMED', p_order_id, 'order:' || p_order_id::text || ':redeemed', auth.uid();
  else
    select loyalty_points_balance into current_points from public.customers where id = p_customer_id for update;
    if current_points < p_points then raise exception using errcode = 'P0001', message = 'You do not have enough points.'; end if;
    perform set_config('app.loyalty_balance_mutation', 'on', true);
    update public.customers set loyalty_points_balance = current_points - p_points, updated_at = now() where id = p_customer_id;
    insert into public.loyalty_transactions (customer_id, order_id, points, reason) values (p_customer_id, p_order_id, -p_points, 'ORDER_POINTS_REDEEMED');
  end if;
end;
$$;
revoke all on function public.redeem_order_points(uuid, uuid, integer) from public;

-- Place an order from the active cart. 0010 replaces this with a payment-method-aware version.
create or replace function public.create_vendor_order_from_cart(p_cart_id uuid, p_notes text default null, p_points_to_redeem integer default 0)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('order.create');
  v_order_id uuid := gen_random_uuid();
  subtotal numeric(12,2);
  points_value numeric(12,2);
  points_discount numeric(12,2) := 0;
  balance_points integer;
begin
  if not exists (select 1 from public.carts c where c.id = p_cart_id and c.customer_id = v_customer_id and c.status = 'ACTIVE') then
    raise exception using errcode = '42501', message = 'The active cart could not be found.';
  end if;
  perform 1 from public.carts where id = p_cart_id for update;
  perform public.remove_invisible_cart_lines(v_customer_id);
  perform public.assert_cart_ready_for_checkout(p_cart_id);
  select coalesce(sum((cl.unit_price_pkr * cl.quantity)::numeric(12,2)), 0) into subtotal from public.cart_lines cl where cl.cart_id = p_cart_id;
  if subtotal <= 0 then raise exception using errcode = '22023', message = 'Add at least one product before placing the order.'; end if;

  if coalesce(p_points_to_redeem, 0) > 0 then
    select loyalty_points_balance into balance_points from public.customers where id = v_customer_id;
    if balance_points < p_points_to_redeem then raise exception using errcode = 'P0001', message = 'You do not have enough points.'; end if;
    points_value := coalesce((select (value_json->>'value_pkr')::numeric from public.settings where key = 'loyalty_point_value_pkr'), 1);
    points_discount := least(subtotal, (p_points_to_redeem * points_value)::numeric(12,2));
  end if;

  insert into public.orders (id, order_number, customer_id, placed_by_user_id, placed_via, status, approval_required,
    subtotal_pkr, discount_pkr, points_redeemed, points_discount_pkr, total_pkr, points_earned, notes, placed_at)
  values (v_order_id, 'AK-' || to_char((now() at time zone 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 6)),
    v_customer_id, auth.uid(), 'VENDOR_PORTAL', 'PLACED', false,
    subtotal, 0, coalesce(p_points_to_redeem, 0), points_discount, subtotal - points_discount, 0, nullif(trim(p_notes), ''), now());

  insert into public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr, price_list_id, price_list_item_id)
    select v_order_id, cl.product_id, cl.quantity, cl.unit_price_pkr, (cl.unit_price_pkr * cl.quantity)::numeric(12,2), cl.price_list_id, cl.price_list_item_id
    from public.cart_lines cl where cl.cart_id = p_cart_id;

  perform public.redeem_order_points(v_customer_id, v_order_id, coalesce(p_points_to_redeem, 0));
  update public.carts set status = 'CHECKED_OUT', updated_at = now() where id = p_cart_id;
  return v_order_id;
end;
$$;
grant execute on function public.create_vendor_order_from_cart(uuid, text, integer) to authenticated;

-- Turn the cart into a quote request (prices are set later by Sales).
create or replace function public.create_vendor_quote_from_cart(p_cart_id uuid, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('quote.create');
  v_quote_id uuid := gen_random_uuid();
begin
  if not exists (select 1 from public.carts c where c.id = p_cart_id and c.customer_id = v_customer_id and c.status = 'ACTIVE') then
    raise exception using errcode = '42501', message = 'The active cart could not be found.';
  end if;
  if not exists (select 1 from public.cart_lines where cart_id = p_cart_id) then
    raise exception using errcode = '22023', message = 'Add at least one product before requesting a quote.';
  end if;
  insert into public.quotes (id, quote_number, customer_id, requested_by_user_id, status, customer_notes, total_pkr)
    values (v_quote_id, 'AQ-' || to_char((now() at time zone 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(v_quote_id::text, '-', ''), 1, 6)),
      v_customer_id, auth.uid(), 'REQUESTED', nullif(trim(p_notes), ''), 0);
  insert into public.quote_lines (quote_id, product_id, quantity)
    select v_quote_id, cl.product_id, cl.quantity from public.cart_lines cl
    join public.resolve_visible_products(v_customer_id) vp on vp.id = cl.product_id
    where cl.cart_id = p_cart_id;
  update public.carts set status = 'CHECKED_OUT', updated_at = now() where id = p_cart_id;
  return v_quote_id;
end;
$$;
grant execute on function public.create_vendor_quote_from_cart(uuid, text) to authenticated;

-- Quote request for a single product (used for quote-only products).
create or replace function public.request_vendor_quote_for_product(p_product_id uuid, p_quantity numeric, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('quote.create');
  v_quote_id uuid := gen_random_uuid();
begin
  if p_quantity is null or p_quantity <= 0 then raise exception using errcode = '22023', message = 'Quantity must be greater than zero.'; end if;
  if not exists (select 1 from public.resolve_visible_products(v_customer_id) vp where vp.id = p_product_id) then
    raise exception using errcode = '42501', message = 'This product is not available to your account.';
  end if;
  insert into public.quotes (id, quote_number, customer_id, requested_by_user_id, status, customer_notes, total_pkr)
    values (v_quote_id, 'AQ-' || to_char((now() at time zone 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(v_quote_id::text, '-', ''), 1, 6)),
      v_customer_id, auth.uid(), 'REQUESTED', nullif(trim(p_notes), ''), 0);
  insert into public.quote_lines (quote_id, product_id, quantity) values (v_quote_id, p_product_id, p_quantity);
  return v_quote_id;
end;
$$;
grant execute on function public.request_vendor_quote_for_product(uuid, numeric, text) to authenticated;

-- Accept a priced quote: the order uses the held quoted_unit_price_pkr, never today's price.
create or replace function public.accept_vendor_quote(p_quote_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('order.create');
  quote_row record;
  v_order_id uuid := gen_random_uuid();
  subtotal numeric(12,2);
begin
  select * into quote_row from public.quotes q where q.id = p_quote_id and q.customer_id = v_customer_id for update;
  if not found then raise exception using errcode = '42501', message = 'This quote is outside your account.'; end if;
  if quote_row.status <> 'QUOTED' then raise exception using errcode = 'P0001', message = 'Only priced quotes can be accepted.'; end if;
  if quote_row.valid_until is not null and quote_row.valid_until < now() then
    update public.quotes set status = 'EXPIRED' where id = p_quote_id;
    raise exception using errcode = 'P0001', message = 'This quote has expired.';
  end if;
  if exists (select 1 from public.quote_lines where quote_id = p_quote_id and quoted_unit_price_pkr is null) then
    raise exception using errcode = 'P0001', message = 'Every quote line must be priced before acceptance.';
  end if;
  select coalesce(sum((ql.quoted_unit_price_pkr * ql.quantity)::numeric(12,2)), 0) into subtotal from public.quote_lines ql where ql.quote_id = p_quote_id;

  insert into public.orders (id, order_number, customer_id, placed_by_user_id, placed_via, source_quote_id, status, approval_required,
    subtotal_pkr, discount_pkr, points_redeemed, points_discount_pkr, total_pkr, points_earned, notes, placed_at)
  values (v_order_id, 'AK-' || to_char((now() at time zone 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 6)),
    v_customer_id, auth.uid(), 'QUOTE_CONVERSION', p_quote_id, 'PLACED', false, subtotal, 0, 0, 0, subtotal, 0, quote_row.customer_notes, now());

  insert into public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr, price_list_id, price_list_item_id)
    select v_order_id, ql.product_id, ql.quantity, ql.quoted_unit_price_pkr, (ql.quoted_unit_price_pkr * ql.quantity)::numeric(12,2), ql.price_list_id, ql.price_list_item_id
    from public.quote_lines ql where ql.quote_id = p_quote_id;

  update public.quotes set status = 'CONVERTED', converted_order_id = v_order_id, responded_at = now() where id = p_quote_id;
  return v_order_id;
end;
$$;
grant execute on function public.accept_vendor_quote(uuid) to authenticated;

create or replace function public.decline_vendor_quote(p_quote_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_customer_id uuid := public.require_vendor_customer('quote.create');
begin
  update public.quotes q set status = 'REJECTED', rejection_reason = nullif(trim(p_reason), ''), responded_at = now()
    where q.id = p_quote_id and q.customer_id = v_customer_id and status in ('REQUESTED', 'IN_REVIEW', 'QUOTED');
  if not found then raise exception using errcode = 'P0001', message = 'This quote can no longer be declined.'; end if;
end;
$$;
grant execute on function public.decline_vendor_quote(uuid, text) to authenticated;

-- Copy a previous order into the cart. Lines that are no longer visible or orderable are skipped.
-- Returns the number of skipped products.
create or replace function public.reorder_vendor_order(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('order.create');
  line record;
  skipped integer := 0;
begin
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.customer_id = v_customer_id) then
    raise exception using errcode = '42501', message = 'This order is outside your account.';
  end if;
  for line in select ol.product_id, sum(ol.quantity) as quantity from public.order_lines ol where ol.order_id = p_order_id and not ol.is_free_item group by ol.product_id loop
    if exists (select 1 from public.resolve_visible_products(v_customer_id) vp where vp.id = line.product_id and vp.is_active and not vp.is_quote_only) then
      perform public.add_vendor_cart_line(line.product_id, line.quantity);
    else
      skipped := skipped + 1;
    end if;
  end loop;
  return skipped;
end;
$$;
grant execute on function public.reorder_vendor_order(uuid) to authenticated;

-- Frequently ordered products that are still visible to the vendor (quick reorder list).
create or replace function public.vendor_reorder_products(p_customer_id uuid, p_limit integer default 12)
returns table (product_id uuid, name_en text, name_ur text, times_ordered bigint, total_quantity numeric, last_ordered_at timestamptz)
language sql
stable
security invoker
set search_path = public
as $$
  select vp.id, vp.name_en, vp.name_ur, count(distinct o.id), sum(ol.quantity), max(o.placed_at)
  from public.orders o
  join public.order_lines ol on ol.order_id = o.id and not ol.is_free_item
  join public.resolve_visible_products(p_customer_id) vp on vp.id = ol.product_id
  where o.customer_id = p_customer_id and o.status <> 'CANCELLED'
    and (public.vendor_customer_for_user(auth.uid()) = p_customer_id or public.has_permission(auth.uid(), 'order.view'))
  group by vp.id, vp.name_en, vp.name_ur
  order by count(distinct o.id) desc, max(o.placed_at) desc
  limit greatest(coalesce(p_limit, 12), 1);
$$;
grant execute on function public.vendor_reorder_products(uuid, integer) to authenticated;

-- Points redemption request from the vendor portal (delegates to the loyalty service from 0043/0044).
create or replace function public.request_vendor_redemption(p_reward_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  redemption_id uuid;
  v_customer_id uuid;
  reward_row record;
begin
  if to_regprocedure('public.request_loyalty_redemption(uuid)') is not null then
    execute 'select public.request_loyalty_redemption($1)' into redemption_id using p_reward_id;
    return redemption_id;
  end if;
  v_customer_id := public.require_vendor_customer('redemption.request');
  select * into reward_row from public.rewards where id = p_reward_id and is_active;
  if not found then raise exception using errcode = 'P0002', message = 'This reward is not currently available.'; end if;
  insert into public.redemptions (customer_id, reward_id, points_spent, status, requested_at)
    values (v_customer_id, p_reward_id, reward_row.points_cost, 'REQUESTED', now()) returning id into redemption_id;
  return redemption_id;
end;
$$;
grant execute on function public.request_vendor_redemption(uuid) to authenticated;

-- Customer-scoped boundaries: a vendor user can read their own customer record and vendor group,
-- which resolve_visible_products (security invoker) needs to build the vendor catalogue.
drop policy if exists customers_vendor_self_read on public.customers;
create policy customers_vendor_self_read on public.customers for select to authenticated
  using (
    exists (select 1 from public.customer_users cu where cu.customer_id = customers.id and cu.user_id = auth.uid())
    or exists (select 1 from public.vendor_accounts va where va.customer_id = customers.id and va.user_id = auth.uid())
  );

drop policy if exists vendor_groups_vendor_read on public.vendor_groups;
create policy vendor_groups_vendor_read on public.vendor_groups for select to authenticated
  using (exists (
    select 1 from public.customers c join public.customer_users cu on cu.customer_id = c.id
    where c.vendor_group_id = vendor_groups.id and cu.user_id = auth.uid()
  ));
