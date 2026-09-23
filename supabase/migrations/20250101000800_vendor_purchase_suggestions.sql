-- AKAI CRM 0008 vendor purchase suggestions (RECONSTRUCTED).
-- The original file was missing from the recovered source. Rebuilt from the contract tests.
-- Suggests up to two categories from a vendor's purchase history to help administrators
-- configure catalogue visibility. SQL-only and read-only: it never writes visibility rules.

create or replace function public.vendor_purchase_category_suggestion(p_customer_id uuid)
returns table (category_id uuid, name_en text, name_ur text, order_count bigint, total_quantity numeric, last_ordered_at timestamptz)
language sql
stable
security invoker
set search_path = public
as $$
  select c.id, c.name_en, c.name_ur, count(distinct o.id), sum(ol.quantity), max(o.placed_at)
  from public.orders o
  join public.order_lines ol on ol.order_id = o.id and not ol.is_free_item
  join public.products p on p.id = ol.product_id
  join public.categories c on c.id = p.category_id
  where o.customer_id = p_customer_id
    and o.status <> 'CANCELLED'
    and public.has_permission(auth.uid(), 'catalogvisibility.manage')
  group by c.id, c.name_en, c.name_ur
  order by count(distinct o.id) desc, sum(ol.quantity) desc
  limit 2;
$$;
grant execute on function public.vendor_purchase_category_suggestion(uuid) to authenticated;
