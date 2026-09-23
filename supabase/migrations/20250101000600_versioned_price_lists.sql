-- AKAI CRM 0006 versioned price lists (RECONSTRUCTED).
-- The original file was missing from the recovered source. Rebuilt from the README description, the
-- legacy Prisma schema, the contract tests and the later migrations that depend on these objects.
-- Adds price-list approval/versioning, item audits, cart snapshots and price-change notices,
-- bilingual price announcements, catalogue PDF artifacts, immutable order/quote price protections,
-- effective-price lookup and activation functions.

create type "PriceListApprovalStatus" as enum ('NOT_REQUIRED', 'PENDING', 'APPROVED', 'REJECTED');
create type "CartStatus" as enum ('ACTIVE', 'CHECKED_OUT', 'ABANDONED');
create type "PriceAnnouncementStatus" as enum ('DRAFT', 'READY', 'QUEUED', 'SENT');

-- Price list approval metadata.
alter table public.price_lists
  add column if not exists approval_required boolean not null default true,
  add column if not exists approval_status "PriceListApprovalStatus" not null default 'PENDING',
  add column if not exists approved_by_user_id uuid references public.users(id) on delete set null,
  add column if not exists approved_at timestamptz,
  add column if not exists rejection_reason text,
  add column if not exists catalogue_pdf_url text;
create index if not exists price_lists_status_effective_from_idx on public.price_lists (status, effective_from);

-- Item cost is only stored in the protected price_list_item_costs relation.
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'price_list_items' and column_name = 'cost_pkr') then
    insert into public.price_list_item_costs (price_list_item_id, cost_pkr)
      select id, cost_pkr from public.price_list_items where cost_pkr is not null
      on conflict (price_list_item_id) do nothing;
    alter table public.price_list_items drop column cost_pkr;
  end if;
end $$;

create table public.price_list_item_audits (
  id uuid primary key default gen_random_uuid(),
  price_list_item_id uuid not null references public.price_list_items(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  old_price_pkr numeric(12,2),
  new_price_pkr numeric(12,2) not null,
  changed_by_user_id uuid references public.users(id) on delete set null,
  reason text,
  created_at timestamptz not null default now()
);
create index price_list_item_audits_product_created_idx on public.price_list_item_audits (product_id, created_at);
create index price_list_item_audits_item_created_idx on public.price_list_item_audits (price_list_item_id, created_at);

create or replace function public.audit_price_list_item_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.price_pkr is distinct from old.price_pkr then
    insert into public.price_list_item_audits (price_list_item_id, product_id, old_price_pkr, new_price_pkr, changed_by_user_id)
    values (new.id, new.product_id, case when tg_op = 'UPDATE' then old.price_pkr end, new.price_pkr, auth.uid());
  end if;
  return new;
end;
$$;
drop trigger if exists price_list_items_audit on public.price_list_items;
create trigger price_list_items_audit after insert or update of price_pkr on public.price_list_items
  for each row execute function public.audit_price_list_item_change();

-- Order and quote lines remember the exact price-list version used.
alter table public.order_lines
  add column if not exists price_list_id uuid references public.price_lists(id) on delete set null,
  add column if not exists price_list_item_id uuid references public.price_list_items(id) on delete set null;
alter table public.quote_lines
  add column if not exists price_list_id uuid references public.price_lists(id) on delete set null,
  add column if not exists price_list_item_id uuid references public.price_list_items(id) on delete set null;

-- Carts and price-change notices.
create table public.carts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  status "CartStatus" not null default 'ACTIVE',
  price_list_id uuid references public.price_lists(id) on delete set null,
  requires_price_review boolean not null default false,
  last_priced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index carts_customer_status_idx on public.carts (customer_id, status);
create index carts_price_review_idx on public.carts (requires_price_review, updated_at);
create unique index carts_one_active_per_customer_idx on public.carts (customer_id) where status = 'ACTIVE';

create table public.cart_lines (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_price_pkr numeric(12,2) not null,
  price_list_id uuid references public.price_lists(id) on delete set null,
  price_list_item_id uuid references public.price_list_items(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cart_id, product_id)
);
create index cart_lines_cart_idx on public.cart_lines (cart_id);
create index cart_lines_product_idx on public.cart_lines (product_id);

create table public.cart_price_changes (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  cart_line_id uuid not null references public.cart_lines(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  old_unit_price_pkr numeric(12,2) not null,
  new_unit_price_pkr numeric(12,2) not null,
  old_price_list_id uuid references public.price_lists(id) on delete set null,
  new_price_list_id uuid references public.price_lists(id) on delete set null,
  detected_at timestamptz not null default now(),
  acknowledged_at timestamptz
);
create index cart_price_changes_cart_ack_idx on public.cart_price_changes (cart_id, acknowledged_at);
create index cart_price_changes_product_detected_idx on public.cart_price_changes (product_id, detected_at);

-- Bilingual price announcements.
create table public.price_announcements (
  id uuid primary key default gen_random_uuid(),
  price_list_id uuid not null references public.price_lists(id) on delete cascade,
  title_en text not null,
  title_ur text not null,
  body_en text not null,
  body_ur text not null,
  status "PriceAnnouncementStatus" not null default 'DRAFT',
  send_whatsapp boolean not null default false,
  send_email boolean not null default false,
  scheduled_for timestamptz,
  sent_at timestamptz,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index price_announcements_list_status_idx on public.price_announcements (price_list_id, status);
create index price_announcements_scheduled_idx on public.price_announcements (scheduled_for, status);

create table public.price_announcement_items (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.price_announcements(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  old_price_pkr numeric(12,2),
  new_price_pkr numeric(12,2) not null,
  unique (announcement_id, product_id)
);
create index price_announcement_items_product_idx on public.price_announcement_items (product_id);

-- Generated catalogue PDFs (0011 adds cache_until and vendor-scoped policies).
create table public.catalogue_pdfs (
  id uuid primary key default gen_random_uuid(),
  price_list_id uuid not null references public.price_lists(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  locale text not null check (locale in ('en', 'ur')),
  storage_path text not null,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.users(id) on delete set null,
  page_count integer not null default 0
);
create unique index catalogue_pdfs_list_customer_locale_idx on public.catalogue_pdfs (price_list_id, coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid), locale);
create index catalogue_pdfs_generated_idx on public.catalogue_pdfs (generated_at);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('catalogue-pdfs', 'catalogue-pdfs', false, 20971520, array['application/pdf'])
  on conflict (id) do nothing;

drop policy if exists catalogue_pdfs_storage_read on storage.objects;
create policy catalogue_pdfs_storage_read on storage.objects for select to authenticated
  using (bucket_id = 'catalogue-pdfs' and (public.has_permission(auth.uid(), 'pricelist.view') or public.has_permission(auth.uid(), 'product.view')));
drop policy if exists catalogue_pdfs_storage_write on storage.objects;
create policy catalogue_pdfs_storage_write on storage.objects for insert to authenticated
  with check (bucket_id = 'catalogue-pdfs' and (public.has_permission(auth.uid(), 'pricelist.view') or public.has_permission(auth.uid(), 'product.view')));

-- Row level security for the new tables.
alter table public.price_list_item_audits enable row level security;
alter table public.carts enable row level security;
alter table public.cart_lines enable row level security;
alter table public.cart_price_changes enable row level security;
alter table public.price_announcements enable row level security;
alter table public.price_announcement_items enable row level security;
alter table public.catalogue_pdfs enable row level security;

create policy price_list_item_audits_read on public.price_list_item_audits for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view'));

create or replace function public.can_access_customer_cart(p_customer_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.customer_users cu where cu.customer_id = p_customer_id and cu.user_id = auth.uid())
    or exists (select 1 from public.vendor_accounts va where va.customer_id = p_customer_id and va.user_id = auth.uid())
    or (public.has_permission(auth.uid(), 'order.view') and exists (
      select 1 from public.customers c where c.id = p_customer_id
        and (public.role_scope(auth.uid()) = 'GLOBAL' or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid())))));
$$;
grant execute on function public.can_access_customer_cart(uuid) to authenticated;

create policy carts_read on public.carts for select to authenticated using (public.can_access_customer_cart(customer_id));
create policy carts_vendor_manage on public.carts for all to authenticated
  using (public.has_permission(auth.uid(), 'order.create') and public.can_access_customer_cart(customer_id))
  with check (public.has_permission(auth.uid(), 'order.create') and public.can_access_customer_cart(customer_id));
create policy cart_lines_read on public.cart_lines for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and public.can_access_customer_cart(c.customer_id)));
create policy cart_lines_manage on public.cart_lines for all to authenticated
  using (public.has_permission(auth.uid(), 'order.create') and exists (select 1 from public.carts c where c.id = cart_id and public.can_access_customer_cart(c.customer_id)))
  with check (public.has_permission(auth.uid(), 'order.create') and exists (select 1 from public.carts c where c.id = cart_id and public.can_access_customer_cart(c.customer_id)));
create policy cart_price_changes_read on public.cart_price_changes for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and public.can_access_customer_cart(c.customer_id)));

create policy price_announcements_read on public.price_announcements for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view'));
create policy price_announcements_manage on public.price_announcements for all to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.create'))
  with check (public.has_permission(auth.uid(), 'pricelist.create'));
create policy price_announcement_items_read on public.price_announcement_items for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view'));
create policy price_announcement_items_manage on public.price_announcement_items for all to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.create'))
  with check (public.has_permission(auth.uid(), 'pricelist.create'));

create policy catalogue_pdfs_staff_read on public.catalogue_pdfs for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view'));
create policy catalogue_pdfs_staff_manage on public.catalogue_pdfs for all to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.create'))
  with check (public.has_permission(auth.uid(), 'pricelist.create'));

-- Product price is owned by the active price list. Activation sets app.price_list_activation.
create or replace function public.prevent_product_price_edit()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.price_pkr is distinct from old.price_pkr or new.compare_at_price_pkr is distinct from old.compare_at_price_pkr)
     and coalesce(current_setting('app.price_list_activation', true), 'off') <> 'on'
     and exists (
       select 1 from public.price_list_items pli join public.price_lists pl on pl.id = pli.price_list_id
       where pli.product_id = new.id and pl.status = 'ACTIVE'
     ) then
    raise exception using errcode = '42501', message = 'Product price is managed by an active price list.';
  end if;
  return new;
end;
$$;
drop trigger if exists products_prevent_price_edit on public.products;
create trigger products_prevent_price_edit before update of price_pkr, compare_at_price_pkr on public.products
  for each row execute function public.prevent_product_price_edit();

-- Historical order prices are never recomputed.
create or replace function public.prevent_order_line_price_change()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.unit_price_pkr is distinct from old.unit_price_pkr or new.line_total_pkr is distinct from old.line_total_pkr then
    raise exception using errcode = '42501', message = 'Order line price is immutable after creation.';
  end if;
  return new;
end;
$$;
drop trigger if exists order_lines_price_immutable on public.order_lines;
create trigger order_lines_price_immutable before update of unit_price_pkr, line_total_pkr on public.order_lines
  for each row execute function public.prevent_order_line_price_change();

-- A quoted price is held until the quote validity date.
create or replace function public.prevent_held_quote_price_change()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.quoted_unit_price_pkr is not null and new.quoted_unit_price_pkr is distinct from old.quoted_unit_price_pkr
     and exists (select 1 from public.quotes q where q.id = new.quote_id and q.status in ('QUOTED', 'ACCEPTED', 'CONVERTED')
                 and (q.valid_until is null or q.valid_until > now())) then
    raise exception using errcode = '42501', message = 'Quoted price is held until the quote validity date.';
  end if;
  return new;
end;
$$;
drop trigger if exists quote_lines_price_hold on public.quote_lines;
create trigger quote_lines_price_hold before update of quoted_unit_price_pkr on public.quote_lines
  for each row execute function public.prevent_held_quote_price_change();

-- Effective price of a product at a point in time (active list first, product price as fallback).
create or replace function public.effective_product_price(p_product_id uuid, p_at timestamptz default now())
returns table (price_pkr numeric, compare_at_price_pkr numeric, price_list_id uuid, price_list_item_id uuid)
language sql stable security invoker set search_path = public as $$
  with listed as (
    select pli.price_pkr, pli.compare_at_price_pkr, pl.id as price_list_id, pli.id as price_list_item_id
    from public.price_list_items pli
    join public.price_lists pl on pl.id = pli.price_list_id
    where pli.product_id = p_product_id
      and pl.status in ('ACTIVE', 'SUPERSEDED')
      and pl.effective_from <= p_at
      and (pl.effective_to is null or pl.effective_to > p_at)
    order by pl.effective_from desc
    limit 1
  )
  select price_pkr, compare_at_price_pkr, price_list_id, price_list_item_id from listed
  union all
  select p.price_pkr, p.compare_at_price_pkr, null::uuid, null::uuid from public.products p
  where p.id = p_product_id and not exists (select 1 from listed)
  limit 1;
$$;
grant execute on function public.effective_product_price(uuid, timestamptz) to authenticated;

-- Re-price one cart against the customer's current visible prices and record every change.
create or replace function public.refresh_cart_prices(p_cart_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  cart_row record;
  line record;
  current_price numeric(12,2);
  price_row record;
  changes integer := 0;
begin
  select * into cart_row from public.carts where id = p_cart_id for update;
  if not found or cart_row.status <> 'ACTIVE' then return 0; end if;
  for line in select * from public.cart_lines where cart_id = p_cart_id for update loop
    select vp.price_pkr into current_price from public.resolve_visible_products(cart_row.customer_id) vp where vp.id = line.product_id;
    if current_price is null then continue; end if;
    select * into price_row from public.effective_product_price(line.product_id, now());
    if current_price <> line.unit_price_pkr then
      insert into public.cart_price_changes (cart_id, cart_line_id, product_id, old_unit_price_pkr, new_unit_price_pkr, old_price_list_id, new_price_list_id)
        values (p_cart_id, line.id, line.product_id, line.unit_price_pkr, current_price, line.price_list_id, price_row.price_list_id);
      update public.cart_lines set unit_price_pkr = current_price, price_list_id = price_row.price_list_id,
        price_list_item_id = price_row.price_list_item_id, updated_at = now() where id = line.id;
      changes := changes + 1;
    end if;
  end loop;
  update public.carts set requires_price_review = requires_price_review or changes > 0, last_priced_at = now(), updated_at = now() where id = p_cart_id;
  return changes;
end;
$$;
revoke all on function public.refresh_cart_prices(uuid) from public;
grant execute on function public.refresh_cart_prices(uuid) to authenticated, service_role;

create or replace function public.acknowledge_cart_price_changes(target_cart_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare cart_customer uuid;
begin
  select customer_id into cart_customer from public.carts where id = target_cart_id;
  if cart_customer is null or not public.can_access_customer_cart(cart_customer) then
    raise exception using errcode = '42501', message = 'This cart is outside your account.';
  end if;
  update public.cart_price_changes set acknowledged_at = now() where cart_id = target_cart_id and acknowledged_at is null;
  update public.carts set requires_price_review = false, updated_at = now() where id = target_cart_id;
end;
$$;
grant execute on function public.acknowledge_cart_price_changes(uuid) to authenticated;

create or replace function public.assert_cart_ready_for_checkout(p_cart_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.refresh_cart_prices(p_cart_id);
  if exists (select 1 from public.carts where id = p_cart_id and requires_price_review) then
    raise exception using errcode = 'P0001', message = 'Review the price changes in this cart before checkout.';
  end if;
end;
$$;
grant execute on function public.assert_cart_ready_for_checkout(uuid) to authenticated;

-- Approve or reject a price list before it can go live.
create or replace function public.review_price_list(p_price_list_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security invoker set search_path = public as $$
begin
  if not public.has_permission(auth.uid(), 'pricelist.activate') then
    raise exception using errcode = '42501', message = 'Approving price lists is not permitted.';
  end if;
  update public.price_lists set
    approval_status = case when p_approve then 'APPROVED'::"PriceListApprovalStatus" else 'REJECTED'::"PriceListApprovalStatus" end,
    approved_by_user_id = auth.uid(), approved_at = now(),
    rejection_reason = case when p_approve then null else nullif(trim(p_reason), '') end,
    status = case when p_approve and status = 'DRAFT' then 'SCHEDULED'::"PriceListStatus" else status end
  where id = p_price_list_id and status in ('DRAFT', 'SCHEDULED');
  if not found then raise exception using errcode = 'P0002', message = 'Only draft or scheduled price lists can be reviewed.'; end if;
end;
$$;
grant execute on function public.review_price_list(uuid, boolean, text) to authenticated;

-- Activate one list: the previous active list becomes SUPERSEDED, product prices are refreshed,
-- and every active cart holding affected products is re-priced.
create or replace function public.activate_price_list_internal(p_price_list_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare cart_row record;
begin
  perform set_config('app.price_list_activation', 'on', true);
  update public.price_lists set status = 'SUPERSEDED', effective_to = coalesce(effective_to, now())
    where status = 'ACTIVE' and id <> p_price_list_id;
  update public.price_lists set status = 'ACTIVE', activated_at = now() where id = p_price_list_id;
  update public.products p set price_pkr = pli.price_pkr, compare_at_price_pkr = pli.compare_at_price_pkr, updated_at = now()
    from public.price_list_items pli where pli.price_list_id = p_price_list_id and pli.product_id = p.id;
  perform set_config('app.price_list_activation', 'off', true);
  for cart_row in
    select distinct c.id from public.carts c join public.cart_lines cl on cl.cart_id = c.id
    join public.price_list_items pli on pli.product_id = cl.product_id and pli.price_list_id = p_price_list_id
    where c.status = 'ACTIVE'
  loop
    perform public.refresh_cart_prices(cart_row.id);
  end loop;
end;
$$;
revoke all on function public.activate_price_list_internal(uuid) from public;

create or replace function public.activate_price_list(p_price_list_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin
  if not public.has_permission(auth.uid(), 'pricelist.activate') then
    raise exception using errcode = '42501', message = 'Activating price lists is not permitted.';
  end if;
  if not exists (select 1 from public.price_lists where id = p_price_list_id and status in ('DRAFT', 'SCHEDULED')
                 and (not approval_required or approval_status in ('APPROVED', 'NOT_REQUIRED'))) then
    raise exception using errcode = 'P0001', message = 'The price list must be approved before activation.';
  end if;
  perform public.activate_price_list_internal(p_price_list_id);
end;
$$;
grant execute on function public.activate_price_list(uuid) to authenticated;

-- Scheduled activation for the protected cron route. Returns the number of lists activated.
create or replace function public.activate_due_price_lists()
returns integer language plpgsql security definer set search_path = public as $$
declare list_row record; activated integer := 0;
begin
  for list_row in
    select id from public.price_lists
    where status = 'SCHEDULED' and effective_from <= now()
      and (not approval_required or approval_status in ('APPROVED', 'NOT_REQUIRED'))
    order by effective_from asc
  loop
    perform public.activate_price_list_internal(list_row.id);
    activated := activated + 1;
  end loop;
  return activated;
end;
$$;
revoke all on function public.activate_due_price_lists() from public;
grant execute on function public.activate_due_price_lists() to service_role;

-- Draft a bilingual announcement listing every price that changes in the given list.
create or replace function public.create_price_announcement(
  p_price_list_id uuid, p_title_en text, p_title_ur text, p_body_en text, p_body_ur text,
  p_send_whatsapp boolean default false, p_send_email boolean default false
)
returns uuid language plpgsql security invoker set search_path = public as $$
declare announcement_id uuid;
begin
  if not public.has_permission(auth.uid(), 'pricelist.create') then
    raise exception using errcode = '42501', message = 'Creating price announcements is not permitted.';
  end if;
  insert into public.price_announcements (price_list_id, title_en, title_ur, body_en, body_ur, send_whatsapp, send_email, created_by_user_id)
    values (p_price_list_id, trim(p_title_en), trim(p_title_ur), trim(p_body_en), trim(p_body_ur), p_send_whatsapp, p_send_email, auth.uid())
    returning id into announcement_id;
  insert into public.price_announcement_items (announcement_id, product_id, old_price_pkr, new_price_pkr)
    select announcement_id, pli.product_id, p.price_pkr, pli.price_pkr
    from public.price_list_items pli join public.products p on p.id = pli.product_id
    where pli.price_list_id = p_price_list_id and pli.price_pkr is distinct from p.price_pkr;
  return announcement_id;
end;
$$;
grant execute on function public.create_price_announcement(uuid, text, text, text, text, boolean, boolean) to authenticated;

create or replace function public.queue_price_announcement(p_announcement_id uuid, p_scheduled_for timestamptz default now())
returns void language plpgsql security invoker set search_path = public as $$
begin
  if not public.has_permission(auth.uid(), 'pricelist.create') then
    raise exception using errcode = '42501', message = 'Queueing price announcements is not permitted.';
  end if;
  update public.price_announcements set status = 'QUEUED', scheduled_for = coalesce(p_scheduled_for, now()), updated_at = now()
    where id = p_announcement_id and status in ('DRAFT', 'READY');
  if not found then raise exception using errcode = 'P0002', message = 'Only draft or ready announcements can be queued.'; end if;
end;
$$;
grant execute on function public.queue_price_announcement(uuid, timestamptz) to authenticated;
