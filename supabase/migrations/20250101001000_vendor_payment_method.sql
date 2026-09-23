-- AKAI CRM 0010 vendor payment method (RECONSTRUCTED).
-- The original file was missing from the recovered source. Rebuilt from the README:
-- order placement records the selected payment_method; the PaymentMethod enum is BALANCE or CREDIT.

create type "PaymentMethod" as enum ('BALANCE', 'CREDIT');
alter table public.orders add column if not exists payment_method "PaymentMethod" not null default 'BALANCE';

drop function if exists public.create_vendor_order_from_cart(uuid, text, integer);

-- Credit orders that would exceed the customer's credit limit wait for Admin approval.
create or replace function public.create_vendor_order_from_cart(
  p_cart_id uuid,
  p_notes text default null,
  p_points_to_redeem integer default 0,
  p_payment_method "PaymentMethod" default 'BALANCE'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := public.require_vendor_customer('order.create');
  customer_row record;
  v_order_id uuid := gen_random_uuid();
  subtotal numeric(12,2);
  points_value numeric(12,2);
  points_discount numeric(12,2) := 0;
  order_total numeric(12,2);
  needs_approval boolean := false;
begin
  if not exists (select 1 from public.carts c where c.id = p_cart_id and c.customer_id = v_customer_id and c.status = 'ACTIVE') then
    raise exception using errcode = '42501', message = 'The active cart could not be found.';
  end if;
  perform 1 from public.carts where id = p_cart_id for update;
  perform public.remove_invisible_cart_lines(v_customer_id);
  perform public.assert_cart_ready_for_checkout(p_cart_id);
  select coalesce(sum((cl.unit_price_pkr * cl.quantity)::numeric(12,2)), 0) into subtotal from public.cart_lines cl where cl.cart_id = p_cart_id;
  if subtotal <= 0 then raise exception using errcode = '22023', message = 'Add at least one product before placing the order.'; end if;

  select * into customer_row from public.customers c where c.id = v_customer_id for update;
  if coalesce(p_points_to_redeem, 0) > 0 then
    if customer_row.loyalty_points_balance < p_points_to_redeem then raise exception using errcode = 'P0001', message = 'You do not have enough points.'; end if;
    points_value := coalesce((select (value_json->>'value_pkr')::numeric from public.settings where key = 'loyalty_point_value_pkr'), 1);
    points_discount := least(subtotal, (p_points_to_redeem * points_value)::numeric(12,2));
  end if;
  order_total := subtotal - points_discount;
  needs_approval := p_payment_method = 'CREDIT' and customer_row.current_balance_pkr + order_total > customer_row.credit_limit_pkr;

  insert into public.orders (id, order_number, customer_id, placed_by_user_id, placed_via, payment_method, status, approval_required,
    subtotal_pkr, discount_pkr, points_redeemed, points_discount_pkr, total_pkr, points_earned, notes, placed_at)
  values (v_order_id, 'AK-' || to_char((now() at time zone 'Asia/Karachi')::date, 'YYYYMMDD') || '-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 6)),
    v_customer_id, auth.uid(), 'VENDOR_PORTAL', p_payment_method,
    case when needs_approval then 'PENDING_APPROVAL'::"OrderStatus" else 'PLACED'::"OrderStatus" end, needs_approval,
    subtotal, 0, coalesce(p_points_to_redeem, 0), points_discount, order_total, 0, nullif(trim(p_notes), ''), now());

  insert into public.order_lines (order_id, product_id, quantity, unit_price_pkr, line_total_pkr, price_list_id, price_list_item_id)
    select v_order_id, cl.product_id, cl.quantity, cl.unit_price_pkr, (cl.unit_price_pkr * cl.quantity)::numeric(12,2), cl.price_list_id, cl.price_list_item_id
    from public.cart_lines cl where cl.cart_id = p_cart_id;

  perform public.redeem_order_points(v_customer_id, v_order_id, coalesce(p_points_to_redeem, 0));
  update public.carts set status = 'CHECKED_OUT', updated_at = now() where id = p_cart_id;
  return v_order_id;
end;
$$;
grant execute on function public.create_vendor_order_from_cart(uuid, text, integer, "PaymentMethod") to authenticated;
