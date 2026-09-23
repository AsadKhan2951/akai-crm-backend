-- Catalogue PDF cache access.
-- 1. The 0006 storage policies let any user with product.view (every Vendor) read or
--    write any object in the private catalogue-pdfs bucket, which exposed other
--    dealers' customer-specific catalogues. They are now staff-only; Vendors keep the
--    customer-folder policies from 0011 (vendors/<their customer id>/...).
-- 2. Vendors cannot read price_lists, but the PDF cache is keyed by the active list.
--    active_price_list_id() returns only that id.

drop policy if exists catalogue_pdfs_storage_read on storage.objects;
create policy catalogue_pdfs_storage_read on storage.objects for select to authenticated
  using (bucket_id = 'catalogue-pdfs' and public.has_permission(auth.uid(), 'pricelist.view'));

drop policy if exists catalogue_pdfs_storage_write on storage.objects;
create policy catalogue_pdfs_storage_write on storage.objects for insert to authenticated
  with check (bucket_id = 'catalogue-pdfs' and public.has_permission(auth.uid(), 'pricelist.create'));

create or replace function public.active_price_list_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.price_lists where status = 'ACTIVE' order by activated_at desc nulls last limit 1;
$$;
revoke all on function public.active_price_list_id() from public, anon;
grant execute on function public.active_price_list_id() to authenticated, service_role;

-- vendor_accounts links count too (0011 only checked customer_users).
drop policy if exists catalogue_pdfs_vendor_read on public.catalogue_pdfs;
create policy catalogue_pdfs_vendor_read on public.catalogue_pdfs for select to authenticated
  using (customer_id is not null and customer_id = public.vendor_customer_for_user(auth.uid()));
drop policy if exists catalogue_pdfs_vendor_insert on public.catalogue_pdfs;
create policy catalogue_pdfs_vendor_insert on public.catalogue_pdfs for insert to authenticated
  with check (customer_id is not null and customer_id = public.vendor_customer_for_user(auth.uid()));
drop policy if exists catalogue_pdfs_vendor_update on public.catalogue_pdfs;
create policy catalogue_pdfs_vendor_update on public.catalogue_pdfs for update to authenticated
  using (customer_id is not null and customer_id = public.vendor_customer_for_user(auth.uid()))
  with check (customer_id is not null and customer_id = public.vendor_customer_for_user(auth.uid()));

-- The preset Vendor role holds pricelist.view, so "pricelist.view" alone does not mean
-- staff. Vendor-portal users only see price-list rows for products they can see, and no
-- other dealer's cached PDF.
drop policy if exists catalogue_pdfs_storage_read on storage.objects;
create policy catalogue_pdfs_storage_read on storage.objects for select to authenticated
  using (bucket_id = 'catalogue-pdfs' and public.has_permission(auth.uid(), 'pricelist.view') and not public.is_vendor_portal_user());

drop policy if exists catalogue_pdfs_staff_read on public.catalogue_pdfs;
create policy catalogue_pdfs_staff_read on public.catalogue_pdfs for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view') and not public.is_vendor_portal_user());

drop policy if exists price_list_items_read on public.price_list_items;
create policy price_list_items_read on public.price_list_items for select to authenticated
  using (
    public.has_permission(auth.uid(), 'pricelist.view')
    and (not public.is_vendor_portal_user() or product_id in (select public.current_vendor_product_ids()))
  );
