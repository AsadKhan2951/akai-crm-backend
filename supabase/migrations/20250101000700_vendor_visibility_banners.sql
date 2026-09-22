-- AKAI CRM migration 0007: vendor visibility and promotional banners.
-- This is a new migration; prior migration files remain immutable.

-- Required baseline groups. Only Standard Dealers is default and sees all active products.
update public.vendor_groups set is_default = false where is_default = true;
insert into public.vendor_groups (id, name, description, is_default, show_all_by_default, price_multiplier)
values
  ('11111111-2222-4333-8444-555555555551', 'Standard Dealers', 'Default vendor group; all active products are visible until restricted.', true, true, 1.0000),
  ('11111111-2222-4333-8444-555555555552', 'Key Accounts', 'Reserved for administrator-managed key accounts.', false, false, 1.0000),
  ('11111111-2222-4333-8444-555555555553', 'Car Care Only', 'Reserved for vendors restricted to selected catalogue categories.', false, false, 1.0000)
on conflict (name) do update set
  description = excluded.description,
  is_default = excluded.is_default,
  show_all_by_default = excluded.show_all_by_default,
  price_multiplier = excluded.price_multiplier;

-- New customers without an explicit group always receive the one configured default group.
create or replace function public.assign_default_vendor_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare default_group uuid;
begin
  if new.vendor_group_id is not null then return new; end if;
  select id into default_group from public.vendor_groups where is_default = true limit 1;
  if default_group is null then
    raise exception using errcode = '23514', message = 'Exactly one default VendorGroup must exist before creating a customer.';
  end if;
  new.vendor_group_id := default_group;
  return new;
end;
$$;

drop trigger if exists assign_default_vendor_group_trigger on public.customers;
create trigger assign_default_vendor_group_trigger
before insert on public.customers
for each row execute function public.assign_default_vendor_group();

-- Most-specific rule wins. Specificity order:
-- vendor product > vendor brand > vendor category > group product > group brand > group category > group default.
create or replace function public.resolve_visible_products(p_customer_id uuid)
returns table (
  id uuid, sku text, name_en text, name_ur text, description_en text, description_ur text,
  category_id uuid, brand_id uuid, unit_of_measure text, pack_size numeric, price_pkr numeric,
  compare_at_price_pkr numeric, loyalty_points_per_unit integer, stock_quantity numeric,
  low_stock_threshold numeric, is_active boolean, is_quote_only boolean,
  created_at timestamptz, updated_at timestamptz
)
language sql stable security invoker set search_path = public
as $$
  with customer_context as (
    select c.id, c.vendor_group_id, coalesce(vg.show_all_by_default, false) as show_all_by_default
    from public.customers c
    left join public.vendor_groups vg on vg.id = c.vendor_group_id
    where c.id = p_customer_id
      and exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  ), ranked_rules as (
    select p.id as product_id, r.mode,
      row_number() over (
        partition by p.id
        order by case
          when r.scope_type = 'VENDOR' and r.entity_type = 'PRODUCT' then 7
          when r.scope_type = 'VENDOR' and r.entity_type = 'BRAND' then 6
          when r.scope_type = 'VENDOR' and r.entity_type = 'CATEGORY' then 5
          when r.scope_type = 'GROUP' and r.entity_type = 'PRODUCT' then 4
          when r.scope_type = 'GROUP' and r.entity_type = 'BRAND' then 3
          when r.scope_type = 'GROUP' and r.entity_type = 'CATEGORY' then 2
          else 0
        end desc, r.created_at desc
      ) as rank
    from public.products p
    cross join customer_context c
    join public.catalog_visibility_rules r on
      ((r.scope_type = 'VENDOR' and r.scope_id = c.id)
       or (r.scope_type = 'GROUP' and r.scope_id = c.vendor_group_id))
      and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id)
       or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id)
       or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
    where p.is_active
  ), resolved as (
    select p.id,
      coalesce((select rr.mode = 'ALLOW' from ranked_rules rr where rr.product_id = p.id and rr.rank = 1), c.show_all_by_default) as visible
    from public.products p cross join customer_context c
    where p.is_active
  )
  select p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur,
    p.category_id, p.brand_id, p.unit_of_measure, p.pack_size, p.price_pkr,
    p.compare_at_price_pkr, p.loyalty_points_per_unit, p.stock_quantity,
    p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
  from public.products p
  join resolved r on r.id = p.id and r.visible
  where public.has_permission(auth.uid(), 'product.view');
$$;

create or replace function public.resolve_visible_product_count(p_customer_id uuid)
returns bigint language sql stable security invoker set search_path = public
as $$ select count(*) from public.resolve_visible_products(p_customer_id); $$;

-- All active banner results pass through the same product resolver for link targets.
create or replace function public.resolve_visible_banners(p_customer_id uuid, p_now timestamptz default now())
returns table (
  id uuid, title_en text, title_ur text, subtitle_en text, subtitle_ur text,
  image_url text, image_url_ur text, link_type "BannerLinkType", link_target_id uuid,
  external_url text, cta_type "BannerCtaType", audience_type "BannerAudienceType",
  display_order integer, starts_at timestamptz, ends_at timestamptz
)
language sql stable security invoker set search_path = public
as $$
  select b.id, b.title_en, b.title_ur, b.subtitle_en, b.subtitle_ur, b.image_url, b.image_url_ur,
    b.link_type, b.link_target_id, b.external_url, b.cta_type, b.audience_type,
    b.display_order, b.starts_at, b.ends_at
  from public.promo_banners b
  join public.customers c on c.id = p_customer_id
  where b.is_active and b.starts_at <= p_now and b.ends_at > p_now
    and (b.audience_type = 'ALL'
      or (b.audience_type = 'GROUP' and exists (select 1 from public.promo_banner_audiences a where a.banner_id = b.id and a.vendor_group_id = c.vendor_group_id))
      or (b.audience_type = 'SPECIFIC_VENDORS' and exists (select 1 from public.promo_banner_audiences a where a.banner_id = b.id and a.customer_id = c.id)))
    and (b.link_type in ('NONE', 'EXTERNAL_URL')
      or (b.link_type = 'PRODUCT' and exists (select 1 from public.resolve_visible_products(p_customer_id) p where p.id = b.link_target_id))
      or (b.link_type = 'CATEGORY' and exists (select 1 from public.resolve_visible_products(p_customer_id) p where p.category_id = b.link_target_id))
      or (b.link_type = 'BRAND' and exists (select 1 from public.resolve_visible_products(p_customer_id) p where p.brand_id = b.link_target_id))
      or (b.link_type = 'COLLECTION' and exists (select 1 from public.product_collections pc join public.resolve_visible_products(p_customer_id) p on p.id = pc.product_id where pc.collection_id = b.link_target_id)))
  order by b.display_order, b.starts_at desc
  limit 5;
$$;

create table if not exists public.cart_visibility_removals (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  removed_at timestamptz not null default now(),
  acknowledged_at timestamptz
);
create index if not exists cart_visibility_removals_cart_removed_idx on public.cart_visibility_removals (cart_id, removed_at desc);
create index if not exists cart_visibility_removals_product_removed_idx on public.cart_visibility_removals (product_id, removed_at desc);

create or replace function public.remove_invisible_cart_lines(p_customer_id uuid)
returns integer language plpgsql security invoker set search_path = public
as $$
declare removed_count integer := 0; cart_record record;
begin
  for cart_record in select c.id from public.carts c where c.customer_id = p_customer_id and c.status = 'ACTIVE' loop
    insert into public.cart_visibility_removals (cart_id, product_id)
      select cl.cart_id, cl.product_id
      from public.cart_lines cl
      where cl.cart_id = cart_record.id
        and not exists (select 1 from public.resolve_visible_products(p_customer_id) p where p.id = cl.product_id);
    get diagnostics removed_count = row_count;
    delete from public.cart_lines cl
      where cl.cart_id = cart_record.id
        and not exists (select 1 from public.resolve_visible_products(p_customer_id) p where p.id = cl.product_id);
    update public.carts set updated_at = now() where id = cart_record.id;
  end loop;
  return removed_count;
end;
$$;

create table if not exists public.banner_attributions (
  id uuid primary key default gen_random_uuid(),
  banner_id uuid not null references public.promo_banners(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  click_event_id uuid references public.banner_events(id) on delete set null,
  order_id uuid references public.orders(id) on delete set null,
  quote_id uuid references public.quotes(id) on delete set null,
  attributed_at timestamptz not null default now(),
  check ((order_id is not null) or (quote_id is not null))
);
create index if not exists banner_attributions_banner_attributed_idx on public.banner_attributions (banner_id, attributed_at desc);
create index if not exists banner_attributions_customer_attributed_idx on public.banner_attributions (customer_id, attributed_at desc);

create or replace function public.banner_performance(p_banner_id uuid)
returns table (impressions bigint, unique_vendors bigint, clicks bigint, ctr numeric, attributed_orders bigint, attributed_quotes bigint)
language sql stable security invoker set search_path = public
as $$
  with event_counts as (
    select count(*) filter (where event_type = 'IMPRESSION') as impressions,
      count(distinct customer_id) filter (where event_type = 'IMPRESSION') as unique_vendors,
      count(*) filter (where event_type = 'CLICK') as clicks
    from public.banner_events where banner_id = p_banner_id
  ), attribution_counts as (
    select count(*) filter (where order_id is not null) as attributed_orders,
      count(*) filter (where quote_id is not null) as attributed_quotes
    from public.banner_attributions where banner_id = p_banner_id and attributed_at <= coalesce((select max(occurred_at) from public.banner_events where banner_id = p_banner_id and event_type = 'CLICK'), now()) + interval '48 hours'
  )
  select e.impressions, e.unique_vendors, e.clicks,
    case when e.impressions = 0 then 0::numeric else round((e.clicks::numeric / e.impressions::numeric) * 100, 2) end,
    a.attributed_orders, a.attributed_quotes
  from event_counts e cross join attribution_counts a;
$$;

alter table public.cart_visibility_removals enable row level security;
alter table public.banner_attributions enable row level security;

drop policy if exists cart_visibility_removals_customer_access on public.cart_visibility_removals;
create policy cart_visibility_removals_customer_access on public.cart_visibility_removals for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and exists (select 1 from public.customer_users cu where cu.customer_id = c.customer_id and cu.user_id = auth.uid())));

drop policy if exists banner_attributions_read on public.banner_attributions;
create policy banner_attributions_read on public.banner_attributions for select to authenticated
  using (public.has_permission(auth.uid(), 'banner.view'));
drop policy if exists banner_attributions_manage on public.banner_attributions;
create policy banner_attributions_manage on public.banner_attributions for insert to authenticated
  with check (public.has_permission(auth.uid(), 'banner.manage'));

-- Enforce banner image size and content type through Storage metadata for banner-images.
drop policy if exists "Authenticated users upload validated media" on storage.objects;
create policy "Authenticated users upload validated media"
  on storage.objects for insert to authenticated
  with check (
    bucket_id in ('product-images', 'banner-images', 'category-images', 'brand-logos', 'claim-photos', 'voice-notes')
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and coalesce(nullif(metadata->>'size', ''), '0')::bigint <= case when bucket_id = 'banner-images' then 2097152 else 5242880 end
    and metadata->>'mimetype' in ('image/jpeg', 'image/png', 'image/webp', 'image/svg+xml', 'audio/webm', 'audio/mpeg', 'audio/wav', 'audio/mp4')
  );

-- Vendor-group writes that affect default assignment or customer scope are transactional.
create or replace function public.set_default_vendor_group(p_group_id uuid)
returns void language plpgsql security invoker set search_path = public
as $$
begin
  if not public.has_permission(auth.uid(), 'vendorgroup.manage') then
    raise exception using errcode = '42501', message = 'You do not have permission to manage VendorGroups.';
  end if;
  update public.vendor_groups set is_default = false where is_default = true;
  update public.vendor_groups set is_default = true where id = p_group_id;
  if not found then raise exception using errcode = '23503', message = 'VendorGroup was not found.'; end if;
end;
$$;

create or replace function public.assign_customers_to_vendor_group(p_group_id uuid, p_customer_ids uuid[])
returns integer language plpgsql security invoker set search_path = public
as $$
declare updated_count integer;
begin
  if not public.has_permission(auth.uid(), 'vendorgroup.manage') then
    raise exception using errcode = '42501', message = 'You do not have permission to assign customers to VendorGroups.';
  end if;
  update public.customers set vendor_group_id = p_group_id where id = any(p_customer_ids);
  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;

create or replace function public.set_catalog_visibility_rule(
  p_scope_type "VisibilityScopeType", p_scope_id uuid, p_entity_type "VisibilityEntityType", p_entity_id uuid, p_mode "VisibilityMode"
)
returns void language plpgsql security invoker set search_path = public
as $$
begin
  if not public.has_permission(auth.uid(), 'catalogvisibility.manage') then
    raise exception using errcode = '42501', message = 'You do not have permission to manage catalogue visibility.';
  end if;
  delete from public.catalog_visibility_rules
    where scope_type = p_scope_type and scope_id = p_scope_id and entity_type = p_entity_type and entity_id = p_entity_id;
  if p_mode is not null then
    insert into public.catalog_visibility_rules (scope_type, scope_id, entity_type, entity_id, mode, created_by_user_id)
    values (p_scope_type, p_scope_id, p_entity_type, p_entity_id, p_mode, auth.uid());
  end if;
end;
$$;

create or replace function public.visible_product_count_for_scope(p_scope_type "VisibilityScopeType", p_scope_id uuid)
returns bigint language sql stable security invoker set search_path = public
as $$
  with context as (
    select case when p_scope_type = 'VENDOR' then c.id else null end as customer_id,
      case when p_scope_type = 'VENDOR' then c.vendor_group_id else p_scope_id end as group_id,
      case when p_scope_type = 'VENDOR' then coalesce(vg.show_all_by_default, false) else coalesce(vg2.show_all_by_default, false) end as show_all
    from (select 1) seed
    left join public.customers c on p_scope_type = 'VENDOR' and c.id = p_scope_id
    left join public.vendor_groups vg on vg.id = c.vendor_group_id
    left join public.vendor_groups vg2 on p_scope_type = 'GROUP' and vg2.id = p_scope_id
  ), resolved as (
    select p.id, coalesce((select r.mode = 'ALLOW' from public.catalog_visibility_rules r, context x where
      ((r.scope_type = 'VENDOR' and r.scope_id = x.customer_id) or (r.scope_type = 'GROUP' and r.scope_id = x.group_id))
      and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id) or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id) or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
      order by case when r.scope_type = 'VENDOR' and r.entity_type = 'PRODUCT' then 7 when r.scope_type = 'VENDOR' and r.entity_type = 'BRAND' then 6 when r.scope_type = 'VENDOR' and r.entity_type = 'CATEGORY' then 5 when r.scope_type = 'GROUP' and r.entity_type = 'PRODUCT' then 4 when r.scope_type = 'GROUP' and r.entity_type = 'BRAND' then 3 when r.scope_type = 'GROUP' and r.entity_type = 'CATEGORY' then 2 else 0 end desc, r.created_at desc limit 1), x.show_all) as visible
    from public.products p cross join context x where p.is_active
  )
  select count(*) from resolved where visible;
$$;

create or replace function public.preview_visible_products(p_scope_type "VisibilityScopeType", p_scope_id uuid)
returns table (
  id uuid, sku text, name_en text, name_ur text, description_en text, description_ur text,
  category_id uuid, brand_id uuid, unit_of_measure text, pack_size numeric, price_pkr numeric,
  compare_at_price_pkr numeric, loyalty_points_per_unit integer, stock_quantity numeric,
  low_stock_threshold numeric, is_active boolean, is_quote_only boolean,
  created_at timestamptz, updated_at timestamptz
)
language sql stable security definer set search_path = public
as $$
  with context as (
    select case when p_scope_type = 'VENDOR' then c.id else null end as vendor_id,
      case when p_scope_type = 'VENDOR' then c.vendor_group_id else p_scope_id end as group_id,
      case when p_scope_type = 'VENDOR' then coalesce(vg.show_all_by_default, false) else coalesce(vg2.show_all_by_default, false) end as show_all
    from (select 1) seed
    left join public.customers c on p_scope_type = 'VENDOR' and c.id = p_scope_id
    left join public.vendor_groups vg on vg.id = c.vendor_group_id
    left join public.vendor_groups vg2 on p_scope_type = 'GROUP' and vg2.id = p_scope_id
  ), resolved as (
    select p.id, coalesce((select r.mode = 'ALLOW' from public.catalog_visibility_rules r, context x where
      ((r.scope_type = 'VENDOR' and r.scope_id = x.vendor_id) or (r.scope_type = 'GROUP' and r.scope_id = x.group_id))
      and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id) or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id) or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
      order by case when r.scope_type = 'VENDOR' and r.entity_type = 'PRODUCT' then 7 when r.scope_type = 'VENDOR' and r.entity_type = 'BRAND' then 6 when r.scope_type = 'VENDOR' and r.entity_type = 'CATEGORY' then 5 when r.scope_type = 'GROUP' and r.entity_type = 'PRODUCT' then 4 when r.scope_type = 'GROUP' and r.entity_type = 'BRAND' then 3 when r.scope_type = 'GROUP' and r.entity_type = 'CATEGORY' then 2 else 0 end desc, r.created_at desc limit 1), x.show_all) as visible
    from public.products p cross join context x where p.is_active
  )
  select p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur, p.category_id, p.brand_id,
    p.unit_of_measure, p.pack_size, p.price_pkr, p.compare_at_price_pkr, p.loyalty_points_per_unit,
    p.stock_quantity, p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
  from public.products p join resolved r on r.id = p.id and r.visible
  where public.has_permission(auth.uid(), 'impersonate.vendor');
$$;

-- Vendor event writes are constrained to the authenticated vendor's customer scope.
drop policy if exists banner_events_insert on public.banner_events;
create policy banner_events_insert on public.banner_events for insert to authenticated
  with check (
    exists (select 1 from public.customer_users cu where cu.customer_id = customer_id and cu.user_id = auth.uid())
    and exists (select 1 from public.resolve_visible_banners(customer_id, now()) b where b.id = banner_id)
  );

drop policy if exists banner_events_read on public.banner_events;
create policy banner_events_read on public.banner_events for select to authenticated
  using (public.has_permission(auth.uid(), 'banner.view'));

-- A matrix cell is a real category+brand rule, not two unrelated toggles.
create table if not exists public.catalog_visibility_category_brands (
  id uuid primary key default gen_random_uuid(),
  scope_type "VisibilityScopeType" not null,
  scope_id uuid not null,
  category_id uuid not null references public.categories(id) on delete cascade,
  brand_id uuid not null references public.brands(id) on delete cascade,
  mode "VisibilityMode" not null,
  created_at timestamptz not null default now(),
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  unique(scope_type, scope_id, category_id, brand_id)
);
create index if not exists catalog_visibility_category_brands_scope_idx on public.catalog_visibility_category_brands (scope_type, scope_id, category_id, brand_id);
create index if not exists catalog_visibility_category_brands_lookup_idx on public.catalog_visibility_category_brands (category_id, brand_id, mode);
alter table public.catalog_visibility_category_brands enable row level security;
drop policy if exists catalog_visibility_category_brands_manage on public.catalog_visibility_category_brands;
create policy catalog_visibility_category_brands_manage on public.catalog_visibility_category_brands for all to authenticated
  using (public.has_permission(auth.uid(), 'catalogvisibility.manage'))
  with check (public.has_permission(auth.uid(), 'catalogvisibility.manage'));

create or replace function public.set_catalog_visibility_pair(
  p_scope_type "VisibilityScopeType", p_scope_id uuid, p_category_id uuid, p_brand_id uuid, p_mode "VisibilityMode"
)
returns void language plpgsql security invoker set search_path = public
as $$
begin
  if not public.has_permission(auth.uid(), 'catalogvisibility.manage') then
    raise exception using errcode = '42501', message = 'You do not have permission to manage catalogue visibility.';
  end if;
  delete from public.catalog_visibility_category_brands where scope_type = p_scope_type and scope_id = p_scope_id and category_id = p_category_id and brand_id = p_brand_id;
  if p_mode is not null then
    insert into public.catalog_visibility_category_brands (scope_type, scope_id, category_id, brand_id, mode, created_by_user_id)
    values (p_scope_type, p_scope_id, p_category_id, p_brand_id, p_mode, auth.uid());
  end if;
end;
$$;

create or replace function public.resolve_visible_products(p_customer_id uuid)
returns table (
  id uuid, sku text, name_en text, name_ur text, description_en text, description_ur text,
  category_id uuid, brand_id uuid, unit_of_measure text, pack_size numeric, price_pkr numeric,
  compare_at_price_pkr numeric, loyalty_points_per_unit integer, stock_quantity numeric,
  low_stock_threshold numeric, is_active boolean, is_quote_only boolean,
  created_at timestamptz, updated_at timestamptz
)
language sql stable security invoker set search_path = public
as $$
  with context as (
    select c.id, c.vendor_group_id, coalesce(vg.show_all_by_default, false) as show_all
    from public.customers c left join public.vendor_groups vg on vg.id = c.vendor_group_id
    where c.id = p_customer_id and exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  ), resolved as (
    select p.id, coalesce((select candidate.mode = 'ALLOW' from (
      select r.mode, case when r.scope_type = 'VENDOR' and r.entity_type = 'PRODUCT' then 9 when r.scope_type = 'VENDOR' and r.entity_type = 'BRAND' then 7 when r.scope_type = 'VENDOR' and r.entity_type = 'CATEGORY' then 6 when r.scope_type = 'GROUP' and r.entity_type = 'PRODUCT' then 5 when r.scope_type = 'GROUP' and r.entity_type = 'BRAND' then 3 when r.scope_type = 'GROUP' and r.entity_type = 'CATEGORY' then 2 else 0 end as specificity, r.created_at
        from public.catalog_visibility_rules r, context x
        where ((r.scope_type = 'VENDOR' and r.scope_id = x.id) or (r.scope_type = 'GROUP' and r.scope_id = x.vendor_group_id))
          and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id) or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id) or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
      union all
      select cb.mode, case when cb.scope_type = 'VENDOR' then 8 else 4 end, cb.created_at
        from public.catalog_visibility_category_brands cb, context x
        where ((cb.scope_type = 'VENDOR' and cb.scope_id = x.id) or (cb.scope_type = 'GROUP' and cb.scope_id = x.vendor_group_id))
          and cb.category_id = p.category_id and cb.brand_id = p.brand_id
    ) candidate order by candidate.specificity desc, candidate.created_at desc limit 1), x.show_all) as visible
    from public.products p cross join context x where p.is_active
  )
  select p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur, p.category_id, p.brand_id, p.unit_of_measure, p.pack_size, p.price_pkr, p.compare_at_price_pkr, p.loyalty_points_per_unit, p.stock_quantity, p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
  from public.products p join resolved r on r.id = p.id and r.visible
  where public.has_permission(auth.uid(), 'product.view');
$$;

create or replace function public.visible_product_count_for_scope(p_scope_type "VisibilityScopeType", p_scope_id uuid)
returns bigint language sql stable security invoker set search_path = public
as $$
  select case when p_scope_type = 'VENDOR' then (select count(*) from public.resolve_visible_products(p_scope_id)) else (select count(*) from public.products p where p.is_active and public.has_permission(auth.uid(), 'catalogvisibility.manage')) end;
$$;
