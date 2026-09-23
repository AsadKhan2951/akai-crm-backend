-- AKAI CRM 0005 catalogue administration (RECONSTRUCTED).
-- The original file was missing from the recovered source. Rebuilt from the README description,
-- the legacy Prisma schema and the later migrations that depend on it.

alter table public.categories add column if not exists "description" text;
alter table public.categories add column if not exists "notes" text;

-- Product cost lives only in the protected product_costs relation.
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'cost_pkr') then
    insert into public.product_costs (product_id, cost_pkr)
      select id, cost_pkr from public.products where cost_pkr is not null
      on conflict (product_id) do nothing;
    alter table public.products drop column cost_pkr;
  end if;
end $$;

-- Catalogue image buckets. Size/type limits are also enforced by 0007 storage policies.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('product-images', 'product-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('category-images', 'category-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('brand-logos', 'brand-logos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists catalogue_images_public_read on storage.objects;
create policy catalogue_images_public_read on storage.objects for select to anon, authenticated
  using (bucket_id in ('product-images', 'category-images', 'brand-logos'));

drop policy if exists catalogue_images_manage on storage.objects;
create policy catalogue_images_manage on storage.objects for all to authenticated
  using (bucket_id in ('product-images', 'category-images', 'brand-logos') and (public.has_permission(auth.uid(), 'product.manage_images') or public.has_permission(auth.uid(), 'category.update') or public.has_permission(auth.uid(), 'brand.update')))
  with check (bucket_id in ('product-images', 'category-images', 'brand-logos') and (public.has_permission(auth.uid(), 'product.manage_images') or public.has_permission(auth.uid(), 'category.update') or public.has_permission(auth.uid(), 'brand.update')));

-- Create or update one product in a single transaction. Cost is written only with product.view_cost.
create or replace function public.save_catalogue_product(p_product jsonb, p_cost_pkr numeric default null)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_product_id uuid := nullif(p_product->>'id', '')::uuid;
begin
  if v_product_id is null then
    if not public.has_permission(auth.uid(), 'product.create') then
      raise exception using errcode = '42501', message = 'Creating products is not permitted.';
    end if;
    insert into public.products (sku, name, name_en, name_ur, description_en, description_ur, category_id, brand_id,
      unit_of_measure, pack_size, price_pkr, compare_at_price_pkr, loyalty_points_per_unit, stock_quantity,
      low_stock_threshold, is_active, is_quote_only)
    values (
      trim(p_product->>'sku'), trim(p_product->>'name_en'), trim(p_product->>'name_en'), trim(p_product->>'name_ur'),
      nullif(trim(p_product->>'description_en'), ''), nullif(trim(p_product->>'description_ur'), ''),
      (p_product->>'category_id')::uuid, nullif(p_product->>'brand_id', '')::uuid,
      coalesce(nullif(trim(p_product->>'unit_of_measure'), ''), 'PCS'), nullif(p_product->>'pack_size', '')::numeric,
      coalesce(nullif(p_product->>'price_pkr', '')::numeric, 0)::numeric(12,2), nullif(p_product->>'compare_at_price_pkr', '')::numeric(12,2),
      coalesce(nullif(p_product->>'loyalty_points_per_unit', '')::integer, 0),
      coalesce(nullif(p_product->>'stock_quantity', '')::numeric, 0), coalesce(nullif(p_product->>'low_stock_threshold', '')::numeric, 0),
      coalesce((p_product->>'is_active')::boolean, true), coalesce((p_product->>'is_quote_only')::boolean, false)
    ) returning id into v_product_id;
  else
    if not public.has_permission(auth.uid(), 'product.update') then
      raise exception using errcode = '42501', message = 'Updating products is not permitted.';
    end if;
    update public.products set
      sku = coalesce(nullif(trim(p_product->>'sku'), ''), sku),
      name = coalesce(nullif(trim(p_product->>'name_en'), ''), name),
      name_en = coalesce(nullif(trim(p_product->>'name_en'), ''), name_en),
      name_ur = coalesce(nullif(trim(p_product->>'name_ur'), ''), name_ur),
      description_en = case when p_product ? 'description_en' then nullif(trim(p_product->>'description_en'), '') else description_en end,
      description_ur = case when p_product ? 'description_ur' then nullif(trim(p_product->>'description_ur'), '') else description_ur end,
      category_id = coalesce(nullif(p_product->>'category_id', '')::uuid, category_id),
      brand_id = case when p_product ? 'brand_id' then nullif(p_product->>'brand_id', '')::uuid else brand_id end,
      unit_of_measure = coalesce(nullif(trim(p_product->>'unit_of_measure'), ''), unit_of_measure),
      pack_size = case when p_product ? 'pack_size' then nullif(p_product->>'pack_size', '')::numeric else pack_size end,
      loyalty_points_per_unit = coalesce(nullif(p_product->>'loyalty_points_per_unit', '')::integer, loyalty_points_per_unit),
      stock_quantity = coalesce(nullif(p_product->>'stock_quantity', '')::numeric, stock_quantity),
      low_stock_threshold = coalesce(nullif(p_product->>'low_stock_threshold', '')::numeric, low_stock_threshold),
      is_active = coalesce((p_product->>'is_active')::boolean, is_active),
      is_quote_only = coalesce((p_product->>'is_quote_only')::boolean, is_quote_only),
      updated_at = now()
    where id = v_product_id;
    if not found then raise exception using errcode = 'P0002', message = 'The product was not found.'; end if;
  end if;

  if p_cost_pkr is not null then
    if not public.has_permission(auth.uid(), 'product.view_cost') then
      raise exception using errcode = '42501', message = 'Editing product cost is not permitted.';
    end if;
    insert into public.product_costs (product_id, cost_pkr) values (v_product_id, p_cost_pkr::numeric(12,2))
      on conflict (product_id) do update set cost_pkr = excluded.cost_pkr;
  end if;
  return v_product_id;
end;
$$;
grant execute on function public.save_catalogue_product(jsonb, numeric) to authenticated;

-- Bulk import: every row succeeds or the whole import is rolled back. Rows are matched by SKU.
create or replace function public.import_catalogue_products(p_rows jsonb)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  row_data jsonb;
  existing_id uuid;
  imported integer := 0;
begin
  if not public.has_permission(auth.uid(), 'product.bulk_import') then
    raise exception using errcode = '42501', message = 'Bulk product import is not permitted.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'The import file has no product rows.';
  end if;
  for row_data in select value from jsonb_array_elements(p_rows) loop
    if nullif(trim(row_data->>'sku'), '') is null then
      raise exception using errcode = '22023', message = 'Every imported product needs a SKU.';
    end if;
    select id into existing_id from public.products where sku = trim(row_data->>'sku');
    perform public.save_catalogue_product(
      case when existing_id is null then row_data - 'id' else row_data || jsonb_build_object('id', existing_id) end,
      nullif(row_data->>'cost_pkr', '')::numeric
    );
    imported := imported + 1;
  end loop;
  return imported;
end;
$$;
grant execute on function public.import_catalogue_products(jsonb) to authenticated;

-- Replace the primary image of a product.
create or replace function public.replace_product_primary_image(p_product_id uuid, p_image_url text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.has_permission(auth.uid(), 'product.manage_images') then
    raise exception using errcode = '42501', message = 'Managing product images is not permitted.';
  end if;
  update public.product_images set is_primary = false where product_id = p_product_id and is_primary;
  insert into public.product_images (product_id, url, is_primary, display_order)
    values (p_product_id, p_image_url, true, 0);
end;
$$;
grant execute on function public.replace_product_primary_image(uuid, text) to authenticated;

-- Deletion checks product counts and fails with an actionable message instead of cascading.
create or replace function public.delete_catalogue_category(p_category_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare product_count integer;
begin
  if not public.has_permission(auth.uid(), 'category.delete') then
    raise exception using errcode = '42501', message = 'Deleting categories is not permitted.';
  end if;
  select count(*) into product_count from public.products where category_id = p_category_id;
  if product_count > 0 then
    raise exception using errcode = '23503', message = format('This category still has %s products. Move them to another category first.', product_count);
  end if;
  delete from public.categories where id = p_category_id;
end;
$$;
grant execute on function public.delete_catalogue_category(uuid) to authenticated;

create or replace function public.delete_catalogue_brand(p_brand_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare product_count integer;
begin
  if not public.has_permission(auth.uid(), 'brand.delete') then
    raise exception using errcode = '42501', message = 'Deleting brands is not permitted.';
  end if;
  select count(*) into product_count from public.products where brand_id = p_brand_id;
  if product_count > 0 then
    raise exception using errcode = '23503', message = format('This brand still has %s products. Move them to another brand first.', product_count);
  end if;
  delete from public.brands where id = p_brand_id;
end;
$$;
grant execute on function public.delete_catalogue_brand(uuid) to authenticated;

-- Audit log columns used by the admin, recovery, delivery and security migrations (user_id, changes_json,
-- ip_address, generated id) alongside the 0002 columns (actor_user_id, before_data, after_data).
alter table public.audit_logs
  add column if not exists user_id uuid references public.users(id) on delete set null,
  add column if not exists changes_json jsonb,
  add column if not exists ip_address text;
alter table public.audit_logs alter column id set default gen_random_uuid()::text;
create index if not exists audit_logs_user_id_created_at_idx on public.audit_logs (user_id, created_at);

create or replace function public.normalize_audit_log()
returns trigger language plpgsql set search_path = public as $$
begin
  new.user_id := coalesce(new.user_id, new.actor_user_id);
  new.actor_user_id := coalesce(new.actor_user_id, new.user_id);
  if new.changes_json is null and (new.before_data is not null or new.after_data is not null) then
    new.changes_json := jsonb_strip_nulls(jsonb_build_object('before', new.before_data, 'after', new.after_data));
  end if;
  return new;
end;
$$;
drop trigger if exists audit_logs_normalize on public.audit_logs;
create trigger audit_logs_normalize before insert on public.audit_logs
  for each row execute function public.normalize_audit_log();

-- Business functions run as the signed-in user and append their own audit entries.
-- Users may only append entries attributed to themselves; audit rows stay read-only afterwards.
drop policy if exists audit_logs_append_own on public.audit_logs;
create policy audit_logs_append_own on public.audit_logs for insert to authenticated
  with check (coalesce(user_id, actor_user_id) = auth.uid());

-- In-app notifications are side effects of business actions (order approval, redemption requests,
-- claim updates) that run as the signed-in user and notify other users. Any active CRM user may
-- create a notification; reading and updating stay limited to the recipient.
drop policy if exists notifications_active_user_insert on public.notifications;
create policy notifications_active_user_insert on public.notifications for insert to authenticated
  with check (exists (select 1 from public.users u where u.id = auth.uid() and u.is_active));
