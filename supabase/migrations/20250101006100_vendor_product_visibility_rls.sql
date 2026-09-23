-- Catalogue visibility must hold at the database boundary, not only in the app.
-- Before this migration a Vendor with product.view could read every row of
-- public.products / public.product_images straight from the REST API, including
-- products hidden from their VendorGroup. After it, a Vendor-portal user sees
-- only products returned by resolve_visible_products(their customer), plus the
-- products already on their own orders, quotes and carts (history must still
-- show product names).

create or replace function public.is_vendor_portal_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.users u
    join public.roles r on r.id = u.role_id
    where u.id = auth.uid() and r.portal_access = 'VENDOR'
  );
$$;

create or replace function public.current_vendor_product_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with me as (select public.vendor_customer_for_user(auth.uid()) as customer_id)
  select v.id from me, public.resolve_visible_products(me.customer_id) v where me.customer_id is not null
  union
  select ol.product_id from me join public.orders o on o.customer_id = me.customer_id join public.order_lines ol on ol.order_id = o.id
  union
  select ql.product_id from me join public.quotes q on q.customer_id = me.customer_id join public.quote_lines ql on ql.quote_id = q.id
  union
  select cl.product_id from me join public.carts c on c.customer_id = me.customer_id join public.cart_lines cl on cl.cart_id = c.id;
$$;

revoke all on function public.is_vendor_portal_user() from public, anon;
revoke all on function public.current_vendor_product_ids() from public, anon;
grant execute on function public.is_vendor_portal_user() to authenticated, service_role;
grant execute on function public.current_vendor_product_ids() to authenticated, service_role;

drop policy if exists products_select on public.products;
drop policy if exists products_read on public.products;
create policy products_read on public.products for select to authenticated
  using (
    public.has_permission(auth.uid(), 'product.view')
    and (not public.is_vendor_portal_user() or id in (select public.current_vendor_product_ids()))
  );

drop policy if exists product_images_read on public.product_images;
create policy product_images_read on public.product_images for select to authenticated
  using (
    public.has_permission(auth.uid(), 'product.view')
    and (not public.is_vendor_portal_user() or product_id in (select public.current_vendor_product_ids()))
  );

