-- AKAI CRM Phase 3 business schema.
-- New migration only: 0001_foundation and 0002_permission_access are not edited.
-- Monetary fields use numeric(12,2) or numeric(12,3); timestamps are timestamptz UTC.

create type "CustomerType" as enum ('AUTO_PARTS', 'OIL_CHANGE', 'CAR_WASH', 'DETAILING', 'PAINT_HARDWARE', 'FUEL_STATION', 'DISTRIBUTOR', 'OTHER');
create type "CustomerStatus" as enum ('ACTIVE', 'INACTIVE', 'PROSPECT', 'BLOCKED');
create type "PriceListStatus" as enum ('DRAFT', 'SCHEDULED', 'ACTIVE', 'SUPERSEDED');
create type "VisibilityScopeType" as enum ('GROUP', 'VENDOR');
create type "VisibilityEntityType" as enum ('CATEGORY', 'BRAND', 'PRODUCT');
create type "VisibilityMode" as enum ('ALLOW', 'DENY');
create type "BannerLinkType" as enum ('PRODUCT', 'CATEGORY', 'BRAND', 'COLLECTION', 'EXTERNAL_URL', 'NONE');
create type "BannerCtaType" as enum ('BUY_NOW', 'REQUEST_QUOTE', 'VIEW');
create type "BannerAudienceType" as enum ('ALL', 'GROUP', 'SPECIFIC_VENDORS');
create type "BannerEventType" as enum ('IMPRESSION', 'CLICK');
create type "PlacedVia" as enum ('VENDOR_PORTAL', 'SALES_AGENT', 'ADMIN', 'WHATSAPP', 'QUOTE_CONVERSION');
create type "OrderStatus" as enum ('DRAFT', 'PENDING_APPROVAL', 'PLACED', 'CONFIRMED', 'PICKED', 'DISPATCHED', 'DELIVERED', 'CANCELLED');
create type "QuoteStatus" as enum ('REQUESTED', 'IN_REVIEW', 'QUOTED', 'ACCEPTED', 'REJECTED', 'EXPIRED', 'CONVERTED');
create type "LeadSource" as enum ('FIELD_VISIT', 'REFERRAL', 'PHONE_IN', 'WALK_IN', 'CAMPAIGN', 'IMPORT', 'OTHER');
create type "LeadStage" as enum ('NEW', 'CONTACTED', 'QUALIFIED', 'PROPOSAL_SENT', 'NEGOTIATION', 'WON', 'LOST');
create type "ActivityType" as enum ('CALL', 'WHATSAPP', 'EMAIL', 'VISIT', 'NOTE', 'MEETING');
create type "ActivityDisposition" as enum ('CONNECTED', 'NO_ANSWER', 'BUSY', 'WRONG_NUMBER', 'CALLBACK_REQUESTED', 'NOT_INTERESTED', 'INTERESTED', 'ORDER_PLACED', 'QUOTE_REQUESTED', 'FOLLOW_UP_SCHEDULED', 'COMPLAINT', 'PAYMENT_COLLECTED');
create type "Priority" as enum ('LOW', 'MEDIUM', 'HIGH');
create type "LedgerEntryType" as enum ('INVOICE', 'PAYMENT', 'CREDIT_NOTE', 'ADJUSTMENT');
create type "RewardType" as enum ('DISCOUNT_AMOUNT', 'DISCOUNT_PERCENT', 'FREE_PRODUCT', 'GIFT');
create type "RedemptionStatus" as enum ('REQUESTED', 'APPROVED', 'FULFILLED', 'REJECTED');
create type "MessageChannel" as enum ('WHATSAPP', 'EMAIL', 'SMS');
create type "MessageDirection" as enum ('INBOUND', 'OUTBOUND');
create type "MessageStatus" as enum ('QUEUED', 'SENT', 'DELIVERED', 'READ', 'FAILED');
create type "AiSurface" as enum ('WIDGET', 'CATALOG_SEARCH', 'COMPOSE', 'ANALYTICS');
create type "AiMessageRole" as enum ('user', 'assistant');

create unique index "roles_name_key" on public.roles ("name");

-- The Phase 2 tables customers, products, orders, quotes, leads, activities,
-- follow_ups, collections, claims, and beat_visits are upgraded in place.
-- The old collections table was a temporary test-domain collection receipt table.
alter table public.collections rename to collection_receipts;

alter table public.customers
  add column "business_name" text,
  add column "business_name_urdu" text,
  add column "area_code" text,
  add column "full_address" text,
  add column "latitude" numeric(9,6),
  add column "longitude" numeric(9,6),
  add column "contact_person_name" text,
  add column "primary_phone" text,
  add column "whatsapp_phone" text,
  add column "email" text,
  add column "customer_type" "CustomerType" not null default 'OTHER',
  add column "vendor_group_id" uuid,
  add column "credit_limit_pkr" numeric(12,2) not null default 0,
  add column "current_balance_pkr" numeric(12,2) not null default 0,
  add column "loyalty_points_balance" integer not null default 0,
  add column "status" "CustomerStatus" not null default 'PROSPECT',
  add column "data_complete" boolean not null default false,
  add column "is_internal_account" boolean not null default false;
update public.customers set "business_name" = coalesce("business_name", "name") where "business_name" is null;
alter table public.customers alter column "business_name" set not null;
alter table public.customers alter column "area_code" set not null;
alter table public.customers alter column "customer_type" set not null;
alter table public.customers add constraint "customers_area_code_format_check" check (length("area_code") between 2 and 32);
alter table public.customers add constraint "customers_primary_phone_e164_check" check ("primary_phone" is null or "primary_phone" ~ '^\\+92[0-9]{10}$');
alter table public.customers add constraint "customers_whatsapp_phone_e164_check" check ("whatsapp_phone" is null or "whatsapp_phone" ~ '^\\+92[0-9]{10}$');
alter table public.customers add constraint "customers_credit_limit_nonnegative_check" check ("credit_limit_pkr" >= 0);
create index "customers_vendor_group_id_customer_status_idx" on public.customers ("vendor_group_id", "status");
create index "customers_area_code_idx" on public.customers ("area_code");
create index "customers_business_name_idx" on public.customers ("business_name");

create table public.area_codes (
  "id" uuid primary key default gen_random_uuid(),
  "code" text not null unique,
  "full_name_en" text not null,
  "full_name_ur" text not null,
  "town" text not null,
  "latitude" numeric(9,6),
  "longitude" numeric(9,6)
);
create index "area_codes_town_idx" on public.area_codes ("town");

create table public.vendor_groups (
  "id" uuid primary key default gen_random_uuid(),
  "name" text not null unique,
  "description" text,
  "is_default" boolean not null default false,
  "show_all_by_default" boolean not null default false,
  "price_multiplier" numeric(8,4) not null default 1.0,
  "created_at" timestamptz(6) not null default now(),
  constraint "vendor_groups_price_multiplier_positive_check" check ("price_multiplier" > 0)
);
create unique index "vendor_groups_one_default_idx" on public.vendor_groups ("is_default") where "is_default" = true;

alter table public.customers add constraint "customers_vendor_group_id_fkey" foreign key ("vendor_group_id") references public.vendor_groups("id") on delete set null;

create table public.vendor_accounts (
  "id" uuid primary key default gen_random_uuid(),
  "customer_id" uuid not null unique references public.customers("id") on delete cascade,
  "user_id" uuid not null unique references public.users("id") on delete cascade,
  "can_place_orders" boolean not null default true,
  "can_request_quotes" boolean not null default true
);
create index "vendor_accounts_user_id_idx" on public.vendor_accounts ("user_id");

alter table public.products
  add column "name_en" text,
  add column "name_ur" text,
  add column "description_en" text,
  add column "description_ur" text,
  add column "category_id" uuid,
  add column "brand_id" uuid,
  add column "unit_of_measure" text,
  add column "pack_size" numeric(12,3),
  add column "price_pkr" numeric(12,2),
  add column "compare_at_price_pkr" numeric(12,2),
  add column "loyalty_points_per_unit" integer not null default 0,
  add column "stock_quantity" numeric(12,3) not null default 0,
  add column "low_stock_threshold" numeric(12,3) not null default 0,
  add column "is_quote_only" boolean not null default false;
update public.products set "name_en" = coalesce("name_en", "name") where "name_en" is null;
alter table public.products alter column "name_en" set not null;
alter table public.products alter column "name_ur" set not null;
alter table public.products alter column "category_id" set not null;
alter table public.products alter column "unit_of_measure" set not null;
alter table public.products alter column "price_pkr" set not null;
alter table public.products add constraint "products_price_nonnegative_check" check ("price_pkr" >= 0);
alter table public.products add constraint "products_stock_nonnegative_check" check ("stock_quantity" >= 0);
alter table public.products add constraint "products_threshold_nonnegative_check" check ("low_stock_threshold" >= 0);
alter table public.products add constraint "products_loyalty_points_nonnegative_check" check ("loyalty_points_per_unit" >= 0);
create index "products_category_id_is_active_idx" on public.products ("category_id", "is_active");
create index "products_brand_id_is_active_idx" on public.products ("brand_id", "is_active");
create index "products_is_active_name_en_idx" on public.products ("is_active", "name_en");
create index "products_stock_quantity_low_stock_threshold_idx" on public.products ("stock_quantity", "low_stock_threshold");

create table public.brands (
  "id" uuid primary key default gen_random_uuid(),
  "name_en" text not null,
  "name_ur" text not null,
  "slug" text not null unique,
  "logo_url" text,
  "display_order" integer not null default 0,
  "is_active" boolean not null default true,
  "notes" text
);
create index "brands_is_active_display_order_idx" on public.brands ("is_active", "display_order");

create table public.categories (
  "id" uuid primary key default gen_random_uuid(),
  "name_en" text not null,
  "name_ur" text not null,
  "slug" text not null unique,
  "image_url" text,
  "display_order" integer not null default 0,
  "is_active" boolean not null default true,
  "parent_category_id" uuid,
  constraint "categories_parent_category_id_fkey" foreign key ("parent_category_id") references public.categories("id") on delete set null
);
create index "categories_is_active_display_order_idx" on public.categories ("is_active", "display_order");
create index "categories_parent_category_id_idx" on public.categories ("parent_category_id");

create table public.collections (
  "id" uuid primary key default gen_random_uuid(),
  "name_en" text not null,
  "name_ur" text not null,
  "slug" text not null unique,
  "image_url" text,
  "description" text,
  "display_order" integer not null default 0,
  "is_active" boolean not null default true,
  "starts_at" timestamptz(6),
  "ends_at" timestamptz(6),
  constraint "collections_period_check" check ("ends_at" is null or "starts_at" is null or "ends_at" >= "starts_at")
);
create index "collections_is_active_display_order_idx" on public.collections ("is_active", "display_order");
create index "collections_starts_at_ends_at_idx" on public.collections ("starts_at", "ends_at");

alter table public.products add constraint "products_category_id_fkey" foreign key ("category_id") references public.categories("id") on delete restrict;
alter table public.products add constraint "products_brand_id_fkey" foreign key ("brand_id") references public.brands("id") on delete set null;

create table public.product_images (
  "id" uuid primary key default gen_random_uuid(),
  "product_id" uuid not null references public.products("id") on delete cascade,
  "url" text not null,
  "alt_text_en" text,
  "alt_text_ur" text,
  "display_order" integer not null default 0,
  "is_primary" boolean not null default false
);
create index "product_images_product_id_display_order_idx" on public.product_images ("product_id", "display_order");
create unique index "product_images_one_primary_idx" on public.product_images ("product_id") where "is_primary" = true;

create table public.product_collections (
  "product_id" uuid not null references public.products("id") on delete cascade,
  "collection_id" uuid not null references public.collections("id") on delete cascade,
  "display_order" integer not null default 0,
  primary key ("product_id", "collection_id")
);
create index "product_collections_collection_id_display_order_idx" on public.product_collections ("collection_id", "display_order");

create table public.price_lists (
  "id" uuid primary key default gen_random_uuid(),
  "name" text not null,
  "effective_from" timestamptz(6) not null,
  "effective_to" timestamptz(6),
  "status" "PriceListStatus" not null,
  "based_on_price_list_id" uuid references public.price_lists("id") on delete set null,
  "notes" text,
  "created_by_user_id" uuid not null references public.users("id") on delete restrict,
  "activated_at" timestamptz(6),
  "created_at" timestamptz(6) not null default now(),
  constraint "price_lists_period_check" check ("effective_to" is null or "effective_to" >= "effective_from")
);
create index "price_lists_status_effective_from_idx" on public.price_lists ("status", "effective_from");
create index "price_lists_based_on_price_list_id_idx" on public.price_lists ("based_on_price_list_id");

create table public.price_list_items (
  "id" uuid primary key default gen_random_uuid(),
  "price_list_id" uuid not null references public.price_lists("id") on delete cascade,
  "product_id" uuid not null references public.products("id") on delete restrict,
  "price_pkr" numeric(12,2) not null,
  "cost_pkr" numeric(12,2),
  "compare_at_price_pkr" numeric(12,2),
  unique ("price_list_id", "product_id"),
  constraint "price_list_items_price_nonnegative_check" check ("price_pkr" >= 0)
);
create index "price_list_items_product_id_idx" on public.price_list_items ("product_id");

create table public.catalog_visibility_rules (
  "id" uuid primary key default gen_random_uuid(),
  "scope_type" "VisibilityScopeType" not null,
  "scope_id" uuid not null,
  "entity_type" "VisibilityEntityType" not null,
  "entity_id" uuid not null,
  "mode" "VisibilityMode" not null,
  "created_at" timestamptz(6) not null default now(),
  "created_by_user_id" uuid not null references public.users("id") on delete restrict
);
create index "catalog_visibility_rules_scope_entity_idx" on public.catalog_visibility_rules ("scope_type", "scope_id", "entity_type", "entity_id");
create index "catalog_visibility_rules_entity_mode_idx" on public.catalog_visibility_rules ("entity_type", "entity_id", "mode");

create table public.promo_banners (
  "id" uuid primary key default gen_random_uuid(),
  "title_en" text not null,
  "title_ur" text not null,
  "subtitle_en" text,
  "subtitle_ur" text,
  "image_url" text not null,
  "image_url_ur" text,
  "link_type" "BannerLinkType" not null,
  "link_target_id" uuid,
  "external_url" text,
  "cta_type" "BannerCtaType" not null,
  "audience_type" "BannerAudienceType" not null,
  "display_order" integer not null default 0,
  "starts_at" timestamptz(6) not null,
  "ends_at" timestamptz(6) not null,
  "is_active" boolean not null default true,
  "created_by_user_id" uuid not null references public.users("id") on delete restrict,
  "created_at" timestamptz(6) not null default now(),
  constraint "promo_banners_period_check" check ("ends_at" >= "starts_at")
);
create index "promo_banners_active_period_order_idx" on public.promo_banners ("is_active", "starts_at", "ends_at", "display_order");

create table public.promo_banner_audiences (
  "id" uuid primary key default gen_random_uuid(),
  "banner_id" uuid not null references public.promo_banners("id") on delete cascade,
  "vendor_group_id" uuid references public.vendor_groups("id") on delete cascade,
  "customer_id" uuid references public.customers("id") on delete cascade,
  constraint "promo_banner_audiences_target_check" check (("vendor_group_id" is not null) or ("customer_id" is not null))
);
create unique index "promo_banner_audiences_unique_target_idx" on public.promo_banner_audiences ("banner_id", coalesce("vendor_group_id", '00000000-0000-0000-0000-000000000000'::uuid), coalesce("customer_id", '00000000-0000-0000-0000-000000000000'::uuid));
create index "promo_banner_audiences_banner_id_idx" on public.promo_banner_audiences ("banner_id");
create index "promo_banner_audiences_vendor_group_id_idx" on public.promo_banner_audiences ("vendor_group_id");
create index "promo_banner_audiences_customer_id_idx" on public.promo_banner_audiences ("customer_id");

create table public.banner_events (
  "id" uuid primary key default gen_random_uuid(),
  "banner_id" uuid not null references public.promo_banners("id") on delete cascade,
  "customer_id" uuid not null references public.customers("id") on delete cascade,
  "event_type" "BannerEventType" not null,
  "occurred_at" timestamptz(6) not null default now()
);
create index "banner_events_banner_event_occurred_idx" on public.banner_events ("banner_id", "event_type", "occurred_at");
create index "banner_events_customer_occurred_idx" on public.banner_events ("customer_id", "occurred_at");

alter table public.orders
  add column "order_number" text,
  add column "placed_by_user_id" uuid,
  add column "placed_via" "PlacedVia" not null default 'ADMIN',
  add column "source_quote_id" uuid,
  add column "approval_required" boolean not null default false,
  add column "approved_by_user_id" uuid,
  add column "approved_at" timestamptz(6),
  add column "rejection_reason" text,
  add column "subtotal_pkr" numeric(12,2) not null default 0,
  add column "discount_pkr" numeric(12,2) not null default 0,
  add column "points_redeemed" integer not null default 0,
  add column "points_discount_pkr" numeric(12,2) not null default 0,
  add column "points_earned" integer not null default 0,
  add column "notes" text,
  add column "placed_at" timestamptz(6),
  add column "confirmed_at" timestamptz(6),
  add column "delivered_at" timestamptz(6);
update public.orders set "order_number" = 'AKAI-MIGRATED-' || id::text where "order_number" is null;
update public.orders set "placed_at" = "created_at" where "placed_at" is null;
update public.orders set "subtotal_pkr" = "total_pkr" where "subtotal_pkr" = 0 and "total_pkr" is not null;
alter table public.orders alter column "status" type "OrderStatus" using upper("status")::"OrderStatus";
alter table public.orders alter column "order_number" set not null;
alter table public.orders alter column "placed_by_user_id" set not null;
alter table public.orders alter column "placed_at" set not null;
alter table public.orders add constraint "orders_order_number_key" unique ("order_number");
alter table public.orders add constraint "orders_placed_by_user_id_fkey" foreign key ("placed_by_user_id") references public.users("id") on delete restrict;
alter table public.orders add constraint "orders_source_quote_id_fkey" foreign key ("source_quote_id") references public.quotes("id") on delete set null;
alter table public.orders add constraint "orders_subtotal_nonnegative_check" check ("subtotal_pkr" >= 0);
alter table public.orders add constraint "orders_total_nonnegative_check" check ("total_pkr" >= 0);
create index "orders_customer_id_placed_at_idx" on public.orders ("customer_id", "placed_at");
create index "orders_placed_by_user_id_placed_at_idx" on public.orders ("placed_by_user_id", "placed_at");
create index "orders_status_placed_at_idx" on public.orders ("status", "placed_at");

create table public.order_lines (
  "id" uuid primary key default gen_random_uuid(),
  "order_id" uuid not null references public.orders("id") on delete cascade,
  "product_id" uuid not null references public.products("id") on delete restrict,
  "quantity" numeric(12,3) not null,
  "unit_price_pkr" numeric(12,2) not null,
  "line_total_pkr" numeric(12,2) not null,
  "is_free_item" boolean not null default false,
  constraint "order_lines_quantity_positive_check" check ("quantity" > 0),
  constraint "order_lines_unit_price_nonnegative_check" check ("unit_price_pkr" >= 0)
);
create index "order_lines_order_id_idx" on public.order_lines ("order_id");
create index "order_lines_product_id_idx" on public.order_lines ("product_id");

alter table public.quotes
  add column "quote_number" text,
  add column "requested_by_user_id" uuid,
  add column "assigned_to_user_id" uuid,
  add column "customer_notes" text,
  add column "internal_notes" text,
  add column "valid_until" timestamptz(6),
  add column "quoted_by_user_id" uuid,
  add column "quoted_at" timestamptz(6),
  add column "responded_at" timestamptz(6),
  add column "rejection_reason" text,
  add column "converted_order_id" uuid;
update public.quotes set "quote_number" = 'AKAI-Q-MIGRATED-' || id::text where "quote_number" is null;
alter table public.quotes alter column "status" type "QuoteStatus" using upper("status")::"QuoteStatus";
alter table public.quotes alter column "quote_number" set not null;
alter table public.quotes alter column "requested_by_user_id" set not null;
alter table public.quotes add constraint "quotes_quote_number_key" unique ("quote_number");
alter table public.quotes add constraint "quotes_requested_by_user_id_fkey" foreign key ("requested_by_user_id") references public.users("id") on delete restrict;
alter table public.quotes add constraint "quotes_assigned_to_user_id_fkey" foreign key ("assigned_to_user_id") references public.users("id") on delete set null;
alter table public.quotes add constraint "quotes_quoted_by_user_id_fkey" foreign key ("quoted_by_user_id") references public.users("id") on delete set null;
alter table public.quotes add constraint "quotes_converted_order_id_fkey" foreign key ("converted_order_id") references public.orders("id") on delete set null;
create index "quotes_customer_id_created_at_business_idx" on public.quotes ("customer_id", "created_at");
create index "quotes_assigned_to_user_id_status_idx" on public.quotes ("assigned_to_user_id", "status");
create index "quotes_status_created_at_idx" on public.quotes ("status", "created_at");

create table public.quote_lines (
  "id" uuid primary key default gen_random_uuid(),
  "quote_id" uuid not null references public.quotes("id") on delete cascade,
  "product_id" uuid not null references public.products("id") on delete restrict,
  "quantity" numeric(12,3) not null,
  "requested_notes" text,
  "quoted_unit_price_pkr" numeric(12,2),
  "line_total_pkr" numeric(12,2),
  constraint "quote_lines_quantity_positive_check" check ("quantity" > 0)
);
create index "quote_lines_quote_id_idx" on public.quote_lines ("quote_id");
create index "quote_lines_product_id_idx" on public.quote_lines ("product_id");

alter table public.leads
  add column "business_name" text,
  add column "contact_name" text,
  add column "phone" text,
  add column "email" text,
  add column "area_code" text,
  add column "full_address" text,
  add column "source" "LeadSource" not null default 'OTHER',
  add column "stage" "LeadStage" not null default 'NEW',
  add column "estimated_value_pkr" numeric(12,2) not null default 0,
  add column "ai_score" numeric(5,2),
  add column "ai_score_reason" text,
  add column "lost_reason" text,
  add column "converted_customer_id" uuid,
  add column "import_batch_id" text,
  add column "updated_at" timestamptz(6) not null default now();
update public.leads set "business_name" = coalesce("business_name", "name"), "contact_name" = coalesce("contact_name", "name"), "area_code" = coalesce("area_code", 'UNKNOWN') where "business_name" is null;
alter table public.leads alter column "business_name" set not null;
alter table public.leads alter column "contact_name" set not null;
alter table public.leads alter column "phone" set not null;
alter table public.leads alter column "area_code" set not null;
alter table public.leads alter column "assigned_agent_id" set not null;
alter table public.leads add constraint "leads_converted_customer_id_fkey" foreign key ("converted_customer_id") references public.customers("id") on delete set null;
alter table public.leads add constraint "leads_estimated_value_nonnegative_check" check ("estimated_value_pkr" >= 0);
alter table public.leads add constraint "leads_ai_score_check" check ("ai_score" is null or ("ai_score" >= 0 and "ai_score" <= 100));
create index "leads_assigned_agent_id_lead_stage_idx" on public.leads ("assigned_agent_id", "stage");
create index "leads_stage_created_at_idx" on public.leads ("stage", "created_at");
create index "leads_area_code_idx" on public.leads ("area_code");

alter table public.activities rename column "assigned_agent_id" to "agent_id";
alter table public.activities
  add column "type" "ActivityType" not null default 'NOTE',
  add column "lead_id" uuid,
  add column "customer_id" uuid,
  add column "disposition" "ActivityDisposition" not null default 'CONNECTED',
  add column "notes" text not null default '',
  add column "duration_seconds" integer,
  add column "latitude" numeric(9,6),
  add column "longitude" numeric(9,6),
  add column "location_accuracy_meters" numeric(9,2),
  add column "distance_from_customer_meters" numeric(9,2),
  add column "occurred_at" timestamptz(6) not null default now();
create index "activities_agent_id_occurred_at_idx" on public.activities ("agent_id", "occurred_at");
create index "activities_customer_id_occurred_at_idx" on public.activities ("customer_id", "occurred_at");
create index "activities_lead_id_occurred_at_idx" on public.activities ("lead_id", "occurred_at");

alter table public.follow_ups rename column "assigned_agent_id" to "agent_id";
alter table public.follow_ups
  add column "activity_id" uuid,
  add column "lead_id" uuid,
  add column "customer_id" uuid,
  add column "priority" "Priority" not null default 'MEDIUM',
  add column "note" text not null default '',
  add column "is_completed" boolean not null default false,
  add column "completed_at" timestamptz(6),
  add column "calendar_event_uid" text;
create index "follow_ups_agent_id_is_completed_due_at_idx" on public.follow_ups ("agent_id", "is_completed", "due_at");
create index "follow_ups_lead_id_due_at_idx" on public.follow_ups ("lead_id", "due_at");
create index "follow_ups_customer_id_due_at_idx" on public.follow_ups ("customer_id", "due_at");

create table public.ledger_entries (
  "id" uuid primary key default gen_random_uuid(),
  "customer_id" uuid not null references public.customers("id") on delete restrict,
  "type" "LedgerEntryType" not null,
  "amount_pkr" numeric(12,2) not null,
  "reference_number" text not null,
  "description" text not null,
  "entry_date" timestamptz(6) not null,
  "recorded_by_user_id" uuid not null references public.users("id") on delete restrict
);
create index "ledger_entries_customer_id_entry_date_idx" on public.ledger_entries ("customer_id", "entry_date");
create index "ledger_entries_type_entry_date_idx" on public.ledger_entries ("type", "entry_date");

create table public.loyalty_transactions (
  "id" uuid primary key default gen_random_uuid(),
  "customer_id" uuid not null references public.customers("id") on delete restrict,
  "order_id" uuid,
  "redemption_id" uuid,
  "points" integer not null,
  "reason" text not null,
  "created_at" timestamptz(6) not null default now()
);
create index "loyalty_transactions_customer_id_created_at_idx" on public.loyalty_transactions ("customer_id", "created_at");
create index "loyalty_transactions_order_id_idx" on public.loyalty_transactions ("order_id");

create table public.rewards (
  "id" uuid primary key default gen_random_uuid(),
  "name_en" text not null,
  "name_ur" text not null,
  "description_en" text,
  "description_ur" text,
  "image_url" text,
  "reward_type" "RewardType" not null,
  "points_cost" integer not null,
  "discount_value_pkr" numeric(12,2),
  "discount_percent" numeric(5,2),
  "free_product_id" uuid,
  "free_product_quantity" numeric(12,3),
  "stock_limit" integer,
  "redeemed_count" integer not null default 0,
  "is_active" boolean not null default true,
  "starts_at" timestamptz(6),
  "ends_at" timestamptz(6),
  constraint "rewards_points_cost_nonnegative_check" check ("points_cost" >= 0),
  constraint "rewards_discount_percent_check" check ("discount_percent" is null or ("discount_percent" >= 0 and "discount_percent" <= 100))
);
create index "rewards_is_active_starts_at_ends_at_idx" on public.rewards ("is_active", "starts_at", "ends_at");

create table public.redemptions (
  "id" uuid primary key default gen_random_uuid(),
  "customer_id" uuid not null references public.customers("id") on delete restrict,
  "reward_id" uuid not null references public.rewards("id") on delete restrict,
  "order_id" uuid,
  "points_spent" integer not null,
  "status" "RedemptionStatus" not null,
  "requested_at" timestamptz(6) not null,
  "approved_by_user_id" uuid references public.users("id") on delete set null,
  "fulfilled_at" timestamptz(6),
  "notes" text
);
create index "redemptions_customer_id_requested_at_idx" on public.redemptions ("customer_id", "requested_at");
create index "redemptions_status_requested_at_idx" on public.redemptions ("status", "requested_at");

create table public.message_logs (
  "id" uuid primary key default gen_random_uuid(),
  "channel" "MessageChannel" not null,
  "direction" "MessageDirection" not null,
  "customer_id" uuid references public.customers("id") on delete set null,
  "lead_id" uuid references public.leads("id") on delete set null,
  "to_address" text not null,
  "template_name" text,
  "body" text not null,
  "status" "MessageStatus" not null,
  "provider_message_id" text,
  "error_message" text,
  "sent_at" timestamptz(6)
);
create index "message_logs_customer_id_sent_at_idx" on public.message_logs ("customer_id", "sent_at");
create index "message_logs_status_sent_at_idx" on public.message_logs ("status", "sent_at");

create table public.ai_conversations (
  "id" uuid primary key default gen_random_uuid(),
  "user_id" uuid not null references public.users("id") on delete cascade,
  "surface" "AiSurface" not null,
  "title" text not null,
  "created_at" timestamptz(6) not null default now()
);
create index "ai_conversations_user_id_created_at_idx" on public.ai_conversations ("user_id", "created_at");

create table public.ai_messages (
  "id" uuid primary key default gen_random_uuid(),
  "conversation_id" uuid not null references public.ai_conversations("id") on delete cascade,
  "role" "AiMessageRole" not null,
  "content" text not null,
  "tool_calls_json" jsonb,
  "tokens_used" integer,
  "latency_ms" integer,
  "created_at" timestamptz(6) not null default now()
);
create index "ai_messages_conversation_id_created_at_idx" on public.ai_messages ("conversation_id", "created_at");

create table public.ai_usage (
  "id" uuid primary key default gen_random_uuid(),
  "user_id" uuid not null references public.users("id") on delete cascade,
  "date" date not null,
  "input_tokens" integer not null,
  "output_tokens" integer not null,
  "request_count" integer not null,
  unique ("user_id", "date")
);
create index "ai_usage_date_idx" on public.ai_usage ("date");

create table public.settings (
  "key" text primary key,
  "value_json" jsonb not null,
  "description" text,
  "updated_by_user_id" uuid not null references public.users("id") on delete restrict,
  "updated_at" timestamptz(6) not null default now()
);

create table public.notifications (
  "id" uuid primary key default gen_random_uuid(),
  "user_id" uuid not null references public.users("id") on delete cascade,
  "type" text not null,
  "title_en" text not null,
  "title_ur" text not null,
  "body" text not null,
  "link_url" text,
  "is_read" boolean not null default false,
  "created_at" timestamptz(6) not null default now()
);
create index "notifications_user_id_is_read_created_at_idx" on public.notifications ("user_id", "is_read", "created_at");

-- Column protection: cost and margin figures live in separate tables with separate policies.
-- product_costs already exists from 0002_permission_access and is intentionally reused.
create table public.price_list_item_costs (
  "price_list_item_id" uuid primary key references public.price_list_items("id") on delete cascade,
  "cost_pkr" numeric(12,2) not null
);

-- Business-domain RLS. Every policy delegates capability decisions to the Phase 2
-- has_permission/accessibility functions; owner-scoped policies additionally use accessible_agent_ids.
alter table public.area_codes enable row level security;
alter table public.vendor_groups enable row level security;
alter table public.vendor_accounts enable row level security;
alter table public.brands enable row level security;
alter table public.categories enable row level security;
alter table public.collections enable row level security;
alter table public.product_images enable row level security;
alter table public.product_collections enable row level security;
alter table public.price_lists enable row level security;
alter table public.price_list_items enable row level security;
alter table public.product_costs enable row level security;
alter table public.price_list_item_costs enable row level security;
alter table public.catalog_visibility_rules enable row level security;
alter table public.promo_banners enable row level security;
alter table public.promo_banner_audiences enable row level security;
alter table public.banner_events enable row level security;
alter table public.order_lines enable row level security;
alter table public.quote_lines enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.loyalty_transactions enable row level security;
alter table public.rewards enable row level security;
alter table public.redemptions enable row level security;
alter table public.message_logs enable row level security;
alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;
alter table public.ai_usage enable row level security;
alter table public.settings enable row level security;
alter table public.notifications enable row level security;

create policy area_codes_read on public.area_codes for select to authenticated
  using (public.has_permission(auth.uid(), 'customer.view') or public.has_permission(auth.uid(), 'lead.view'));
create policy vendor_groups_read on public.vendor_groups for select to authenticated
  using (public.has_permission(auth.uid(), 'customer.view'));
create policy vendor_groups_manage on public.vendor_groups for all to authenticated
  using (public.has_permission(auth.uid(), 'vendorgroup.manage'))
  with check (public.has_permission(auth.uid(), 'vendorgroup.manage'));
create policy vendor_accounts_read on public.vendor_accounts for select to authenticated
  using (user_id = auth.uid() or public.has_permission(auth.uid(), 'customer.view'));
create policy vendor_accounts_manage on public.vendor_accounts for all to authenticated
  using (public.has_permission(auth.uid(), 'vendoraccount.create') or public.has_permission(auth.uid(), 'vendoraccount.deactivate'))
  with check (public.has_permission(auth.uid(), 'vendoraccount.create'));

create policy brands_read on public.brands for select to authenticated
  using (public.has_permission(auth.uid(), 'brand.view'));
create policy brands_manage on public.brands for all to authenticated
  using (public.has_permission(auth.uid(), 'brand.create') or public.has_permission(auth.uid(), 'brand.update') or public.has_permission(auth.uid(), 'brand.delete'))
  with check (public.has_permission(auth.uid(), 'brand.create') or public.has_permission(auth.uid(), 'brand.update'));
create policy categories_read on public.categories for select to authenticated
  using (public.has_permission(auth.uid(), 'category.view'));
create policy categories_manage on public.categories for all to authenticated
  using (public.has_permission(auth.uid(), 'category.create') or public.has_permission(auth.uid(), 'category.update') or public.has_permission(auth.uid(), 'category.delete'))
  with check (public.has_permission(auth.uid(), 'category.create') or public.has_permission(auth.uid(), 'category.update'));
create policy collections_read on public.collections for select to authenticated
  using (public.has_permission(auth.uid(), 'collection.view'));
create policy collections_manage on public.collections for all to authenticated
  using (public.has_permission(auth.uid(), 'collection.manage'))
  with check (public.has_permission(auth.uid(), 'collection.manage'));

create policy products_read on public.products for select to authenticated
  using (public.has_permission(auth.uid(), 'product.view'));
create policy products_manage on public.products for all to authenticated
  using (public.has_permission(auth.uid(), 'product.create') or public.has_permission(auth.uid(), 'product.update') or public.has_permission(auth.uid(), 'product.delete'))
  with check (public.has_permission(auth.uid(), 'product.create') or public.has_permission(auth.uid(), 'product.update'));
create policy product_images_read on public.product_images for select to authenticated
  using (public.has_permission(auth.uid(), 'product.view'));
create policy product_images_manage on public.product_images for all to authenticated
  using (public.has_permission(auth.uid(), 'product.manage_images'))
  with check (public.has_permission(auth.uid(), 'product.manage_images'));
create policy product_collections_read on public.product_collections for select to authenticated
  using (public.has_permission(auth.uid(), 'product.view') or public.has_permission(auth.uid(), 'collection.view'));
create policy product_collections_manage on public.product_collections for all to authenticated
  using (public.has_permission(auth.uid(), 'collection.manage'))
  with check (public.has_permission(auth.uid(), 'collection.manage'));
create policy product_costs_read on public.product_costs for select to authenticated
  using (public.has_permission(auth.uid(), 'product.view_cost'));
create policy product_costs_manage on public.product_costs for all to authenticated
  using (public.has_permission(auth.uid(), 'product.update'))
  with check (public.has_permission(auth.uid(), 'product.update') and public.has_permission(auth.uid(), 'product.view_cost'));

create policy price_lists_read on public.price_lists for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view'));
create policy price_lists_manage on public.price_lists for all to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.create') or public.has_permission(auth.uid(), 'pricelist.activate'))
  with check (public.has_permission(auth.uid(), 'pricelist.create') or public.has_permission(auth.uid(), 'pricelist.activate'));
create policy price_list_items_read on public.price_list_items for select to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.view'));
create policy price_list_items_manage on public.price_list_items for all to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.create') or public.has_permission(auth.uid(), 'pricelist.activate'))
  with check (public.has_permission(auth.uid(), 'pricelist.create') or public.has_permission(auth.uid(), 'pricelist.activate'));
create policy price_list_item_costs_read on public.price_list_item_costs for select to authenticated
  using (public.has_permission(auth.uid(), 'product.view_cost'));
create policy price_list_item_costs_manage on public.price_list_item_costs for all to authenticated
  using (public.has_permission(auth.uid(), 'pricelist.create') and public.has_permission(auth.uid(), 'product.view_cost'))
  with check (public.has_permission(auth.uid(), 'pricelist.create') and public.has_permission(auth.uid(), 'product.view_cost'));
create policy catalog_visibility_rules_read on public.catalog_visibility_rules for select to authenticated
  using (public.has_permission(auth.uid(), 'catalogvisibility.manage') or public.has_permission(auth.uid(), 'product.view'));
create policy catalog_visibility_rules_manage on public.catalog_visibility_rules for all to authenticated
  using (public.has_permission(auth.uid(), 'catalogvisibility.manage'))
  with check (public.has_permission(auth.uid(), 'catalogvisibility.manage'));

create policy promo_banners_read on public.promo_banners for select to authenticated
  using (public.has_permission(auth.uid(), 'banner.view'));
create policy promo_banners_manage on public.promo_banners for all to authenticated
  using (public.has_permission(auth.uid(), 'banner.manage'))
  with check (public.has_permission(auth.uid(), 'banner.manage'));
create policy promo_banner_audiences_read on public.promo_banner_audiences for select to authenticated
  using (public.has_permission(auth.uid(), 'banner.view'));
create policy promo_banner_audiences_manage on public.promo_banner_audiences for all to authenticated
  using (public.has_permission(auth.uid(), 'banner.manage'))
  with check (public.has_permission(auth.uid(), 'banner.manage'));
create policy banner_events_read on public.banner_events for select to authenticated
  using (public.has_permission(auth.uid(), 'banner.view') or exists (select 1 from public.customers c where c.id = customer_id and exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())));
create policy banner_events_insert on public.banner_events for insert to authenticated
  with check (exists (select 1 from public.customer_users cu where cu.customer_id = customer_id and cu.user_id = auth.uid()));

create policy customers_business_read on public.customers for select to authenticated
  using (public.has_permission(auth.uid(), 'customer.view') and (
    public.role_scope(auth.uid()) = 'GLOBAL'
    or assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    or exists (select 1 from public.customer_users cu where cu.customer_id = customers.id and cu.user_id = auth.uid())
  ));
create policy customers_business_manage on public.customers for all to authenticated
  using (public.has_permission(auth.uid(), 'customer.create') or public.has_permission(auth.uid(), 'customer.update') or public.has_permission(auth.uid(), 'customer.delete'))
  with check (public.has_permission(auth.uid(), 'customer.create') or public.has_permission(auth.uid(), 'customer.update'));
create policy customer_users_business_read on public.customer_users for select to authenticated
  using (user_id = auth.uid() or public.has_permission(auth.uid(), 'customer.view'));
create policy customer_users_business_manage on public.customer_users for all to authenticated
  using (public.has_permission(auth.uid(), 'vendoraccount.create') or public.has_permission(auth.uid(), 'customer.update'))
  with check (public.has_permission(auth.uid(), 'vendoraccount.create') or public.has_permission(auth.uid(), 'customer.update'));

create policy orders_business_read on public.orders for select to authenticated
  using (public.has_permission(auth.uid(), 'order.view') and exists (select 1 from public.customers c where c.id = customer_id and (
    public.role_scope(auth.uid()) = 'GLOBAL'
    or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  )));
create policy orders_business_manage on public.orders for all to authenticated
  using (public.has_permission(auth.uid(), 'order.create') or public.has_permission(auth.uid(), 'order.update_status') or public.has_permission(auth.uid(), 'order.approve') or public.has_permission(auth.uid(), 'order.cancel'))
  with check (public.has_permission(auth.uid(), 'order.create') or public.has_permission(auth.uid(), 'order.update_status') or public.has_permission(auth.uid(), 'order.approve'));
create policy order_lines_business_read on public.order_lines for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));
create policy order_lines_business_manage on public.order_lines for all to authenticated
  using (public.has_permission(auth.uid(), 'order.create'))
  with check (public.has_permission(auth.uid(), 'order.create'));

create policy quotes_business_read on public.quotes for select to authenticated
  using (public.has_permission(auth.uid(), 'quote.view') and exists (select 1 from public.customers c where c.id = customer_id and (
    public.role_scope(auth.uid()) = 'GLOBAL'
    or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  )));
create policy quotes_business_manage on public.quotes for all to authenticated
  using (public.has_permission(auth.uid(), 'quote.create') or public.has_permission(auth.uid(), 'quote.price') or public.has_permission(auth.uid(), 'quote.cancel'))
  with check (public.has_permission(auth.uid(), 'quote.create') or public.has_permission(auth.uid(), 'quote.price'));
create policy quote_lines_business_read on public.quote_lines for select to authenticated
  using (exists (select 1 from public.quotes q where q.id = quote_id));
create policy quote_lines_business_manage on public.quote_lines for all to authenticated
  using (public.has_permission(auth.uid(), 'quote.create') or public.has_permission(auth.uid(), 'quote.price'))
  with check (public.has_permission(auth.uid(), 'quote.create') or public.has_permission(auth.uid(), 'quote.price'));

create policy leads_business_read on public.leads for select to authenticated
  using (public.has_permission(auth.uid(), 'lead.view') and assigned_agent_id in (select public.accessible_agent_ids(auth.uid())));
create policy leads_business_manage on public.leads for all to authenticated
  using (public.has_permission(auth.uid(), 'lead.create') or public.has_permission(auth.uid(), 'lead.update') or public.has_permission(auth.uid(), 'lead.delete') or public.has_permission(auth.uid(), 'lead.reassign'))
  with check (public.has_permission(auth.uid(), 'lead.create') or public.has_permission(auth.uid(), 'lead.update') or public.has_permission(auth.uid(), 'lead.reassign'));
create policy activities_business_read on public.activities for select to authenticated
  using (public.has_permission(auth.uid(), 'activity.view') and agent_id in (select public.accessible_agent_ids(auth.uid())));
create policy activities_business_manage on public.activities for all to authenticated
  using (public.has_permission(auth.uid(), 'activity.create') and agent_id in (select public.accessible_agent_ids(auth.uid())))
  with check (public.has_permission(auth.uid(), 'activity.create') and agent_id in (select public.accessible_agent_ids(auth.uid())));
create policy follow_ups_business_read on public.follow_ups for select to authenticated
  using (public.has_permission(auth.uid(), 'followup.view') and agent_id in (select public.accessible_agent_ids(auth.uid())));
create policy follow_ups_business_manage on public.follow_ups for all to authenticated
  using (public.has_permission(auth.uid(), 'followup.manage') and agent_id in (select public.accessible_agent_ids(auth.uid())))
  with check (public.has_permission(auth.uid(), 'followup.manage') and agent_id in (select public.accessible_agent_ids(auth.uid())));

create policy ledger_entries_business_read on public.ledger_entries for select to authenticated
  using (public.has_permission(auth.uid(), 'ledger.view') and exists (select 1 from public.customers c where c.id = customer_id and (
    public.role_scope(auth.uid()) = 'GLOBAL'
    or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  )));
create policy ledger_entries_business_manage on public.ledger_entries for all to authenticated
  using (public.has_permission(auth.uid(), 'ledger.record_payment') or public.has_permission(auth.uid(), 'ledger.adjust'))
  with check (public.has_permission(auth.uid(), 'ledger.record_payment') or public.has_permission(auth.uid(), 'ledger.adjust'));
create policy loyalty_transactions_business_read on public.loyalty_transactions for select to authenticated
  using (public.has_permission(auth.uid(), 'customer.view') and exists (select 1 from public.customers c where c.id = customer_id and (
    public.role_scope(auth.uid()) = 'GLOBAL'
    or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  )));
create policy loyalty_transactions_business_manage on public.loyalty_transactions for all to authenticated
  using (public.has_permission(auth.uid(), 'loyalty.adjust'))
  with check (public.has_permission(auth.uid(), 'loyalty.adjust'));
create policy rewards_business_read on public.rewards for select to authenticated
  using (public.has_permission(auth.uid(), 'reward.manage'));
create policy rewards_business_manage on public.rewards for all to authenticated
  using (public.has_permission(auth.uid(), 'reward.manage'))
  with check (public.has_permission(auth.uid(), 'reward.manage'));
create policy redemptions_business_read on public.redemptions for select to authenticated
  using (public.has_permission(auth.uid(), 'customer.view') and exists (select 1 from public.customers c where c.id = customer_id and (
    public.role_scope(auth.uid()) = 'GLOBAL'
    or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
    or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  )));
create policy redemptions_business_manage on public.redemptions for all to authenticated
  using (public.has_permission(auth.uid(), 'redemption.approve'))
  with check (public.has_permission(auth.uid(), 'redemption.approve'));

create policy message_logs_business_read on public.message_logs for select to authenticated
  using ((public.has_permission(auth.uid(), 'message.send') or public.has_permission(auth.uid(), 'message.campaign')) and (
    customer_id is null or exists (select 1 from public.customers c where c.id = customer_id and (
      public.role_scope(auth.uid()) = 'GLOBAL'
      or c.assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))
      or exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
    ))
  ));
create policy message_logs_business_manage on public.message_logs for all to authenticated
  using (public.has_permission(auth.uid(), 'message.send') or public.has_permission(auth.uid(), 'message.campaign'))
  with check (public.has_permission(auth.uid(), 'message.send') or public.has_permission(auth.uid(), 'message.campaign'));

create policy ai_conversations_business_read on public.ai_conversations for select to authenticated
  using (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'));
create policy ai_conversations_business_manage on public.ai_conversations for all to authenticated
  using (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'))
  with check (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'));
create policy ai_messages_business_read on public.ai_messages for select to authenticated
  using (exists (select 1 from public.ai_conversations c where c.id = conversation_id and c.user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat')));
create policy ai_messages_business_manage on public.ai_messages for all to authenticated
  using (exists (select 1 from public.ai_conversations c where c.id = conversation_id and c.user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat')))
  with check (exists (select 1 from public.ai_conversations c where c.id = conversation_id and c.user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat')));
create policy ai_usage_business_read on public.ai_usage for select to authenticated
  using (user_id = auth.uid() and public.has_permission(auth.uid(), 'ai.chat'));

create policy settings_business_read on public.settings for select to authenticated
  using (public.has_permission(auth.uid(), 'settings.manage'));
create policy settings_business_manage on public.settings for all to authenticated
  using (public.has_permission(auth.uid(), 'settings.manage'))
  with check (public.has_permission(auth.uid(), 'settings.manage'));
create policy notifications_business_read on public.notifications for select to authenticated
  using (user_id = auth.uid());
create policy notifications_business_manage on public.notifications for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Force the application-facing Product projection to contain no cost column.
-- Cost is only exposed by the separate product_costs policy above.
create or replace view public.vendor_products
with (security_invoker = true)
as
select
  p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur,
  p.category_id, p.brand_id, p.unit_of_measure, p.pack_size, p.price_pkr,
  p.compare_at_price_pkr, p.loyalty_points_per_unit, p.stock_quantity,
  p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
from public.products p;

-- All business tables remain RLS-protected even if a future service adds a new query path.

create or replace function public.resolve_visible_products(p_customer_id uuid)
returns table (
  id uuid,
  sku text,
  name_en text,
  name_ur text,
  description_en text,
  description_ur text,
  category_id uuid,
  brand_id uuid,
  unit_of_measure text,
  pack_size numeric,
  price_pkr numeric,
  compare_at_price_pkr numeric,
  loyalty_points_per_unit integer,
  stock_quantity numeric,
  low_stock_threshold numeric,
  is_active boolean,
  is_quote_only boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  with customer_context as (
    select c.id, c.vendor_group_id, vg.show_all_by_default
    from public.customers c
    left join public.vendor_groups vg on vg.id = c.vendor_group_id
    where c.id = p_customer_id
      and exists (select 1 from public.customer_users cu where cu.customer_id = c.id and cu.user_id = auth.uid())
  )
  select
    p.id, p.sku, p.name_en, p.name_ur, p.description_en, p.description_ur,
    p.category_id, p.brand_id, p.unit_of_measure, p.pack_size, p.price_pkr,
    p.compare_at_price_pkr, p.loyalty_points_per_unit, p.stock_quantity,
    p.low_stock_threshold, p.is_active, p.is_quote_only, p.created_at, p.updated_at
  from public.products p
  cross join customer_context c
  where public.has_permission(auth.uid(), 'product.view')
    and p.is_active
    and not exists (
      select 1 from public.catalog_visibility_rules r
      where r.mode = 'DENY'
        and ((r.scope_type = 'GROUP' and r.scope_id = c.vendor_group_id)
          or (r.scope_type = 'VENDOR' and r.scope_id = c.id))
        and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id)
          or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id)
          or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
    )
    and (
      coalesce(c.show_all_by_default, false)
      or exists (
        select 1 from public.catalog_visibility_rules r
        where r.mode = 'ALLOW'
          and ((r.scope_type = 'GROUP' and r.scope_id = c.vendor_group_id)
            or (r.scope_type = 'VENDOR' and r.scope_id = c.id))
          and ((r.entity_type = 'PRODUCT' and r.entity_id = p.id)
            or (r.entity_type = 'CATEGORY' and r.entity_id = p.category_id)
            or (r.entity_type = 'BRAND' and r.entity_id = p.brand_id))
      )
    );
$$;
