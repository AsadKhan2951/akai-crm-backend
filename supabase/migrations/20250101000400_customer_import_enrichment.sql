-- AKAI CRM customer import and enrichment foundation.
-- New migration only; do not edit previously applied migrations.

alter table public.customers
  add column "normalized_name" text,
  add column "customer_type_suggestion" "CustomerType",
  add column "duplicate_review_required" boolean not null default false,
  add column "duplicate_review_reason" text,
  add column "import_batch_id" text,
  add column "import_source_row" integer,
  add column "import_key" text,
  add column "imported_at" timestamptz(6);

update public.customers
set "normalized_name" = upper(regexp_replace(trim(regexp_replace("business_name", '[[:space:]]+', ' ', 'g')), '[^A-Za-z0-9]+', '', 'g'))
where "normalized_name" is null;
alter table public.customers alter column "normalized_name" set not null;
update public.customers
set "import_key" = 'legacy-' || id::text
where "import_key" is null;
alter table public.customers alter column "import_key" set not null;

alter table public.customers
  add constraint "customers_import_source_row_positive_check" check ("import_source_row" is null or "import_source_row" > 0),
  add constraint "customers_imported_at_batch_check" check (("import_batch_id" is null) = ("imported_at" is null));

alter table public.customers
  add constraint "customers_area_code_fkey" foreign key ("area_code") references public.area_codes("code") on delete restrict;

create index "customers_normalized_name_idx" on public.customers ("normalized_name");
create index "customers_assigned_agent_data_complete_area_idx" on public.customers ("assigned_agent_id", "data_complete", "area_code");
create index "customers_duplicate_review_required_idx" on public.customers ("duplicate_review_required") where "duplicate_review_required" = true;
create index "customers_import_batch_id_idx" on public.customers ("import_batch_id");
create unique index "customers_import_key_key" on public.customers ("import_key");

drop policy if exists customers_business_manage on public.customers;
create policy customers_business_insert on public.customers for insert to authenticated
  with check (public.has_permission(auth.uid(), 'customer.create'));
create policy customers_business_update on public.customers for update to authenticated
  using (
    (public.has_permission(auth.uid(), 'customer.update') or public.has_permission(auth.uid(), 'customer.enrich'))
    and (public.role_scope(auth.uid()) = 'GLOBAL' or assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or exists (select 1 from public.customer_users cu where cu.customer_id = customers.id and cu.user_id = auth.uid()))
  )
  with check (
    (public.has_permission(auth.uid(), 'customer.update') or public.has_permission(auth.uid(), 'customer.enrich'))
    and (public.role_scope(auth.uid()) = 'GLOBAL' or assigned_agent_id in (select public.accessible_agent_ids(auth.uid())) or exists (select 1 from public.customer_users cu where cu.customer_id = customers.id and cu.user_id = auth.uid()))
  );
create policy customers_business_delete on public.customers for delete to authenticated
  using (public.has_permission(auth.uid(), 'customer.delete') and (public.role_scope(auth.uid()) = 'GLOBAL' or assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))));
create policy area_codes_business_manage on public.area_codes for update to authenticated
  using (public.has_permission(auth.uid(), 'settings.manage'))
  with check (public.has_permission(auth.uid(), 'settings.manage'));

-- Completion reporting must aggregate in SQL rather than fetching all customer rows.
create or replace view public.customer_enrichment_progress
with (security_invoker = true)
as
select
  sa.id as sales_agent_id,
  sa.agent_code,
  u.full_name as sales_agent_name,
  count(c.id)::integer as total_customers,
  count(c.id) filter (where c.data_complete)::integer as completed_customers,
  count(c.id) filter (where not c.data_complete)::integer as remaining_customers
from public.sales_agents sa
join public.users u on u.id = sa.user_id
left join public.customers c on c.assigned_agent_id = sa.id and not c.is_internal_account
where public.has_permission(auth.uid(), 'customer.view')
group by sa.id, sa.agent_code, u.full_name;

-- Views do not have independent RLS policies. This security-invoker view inherits
-- RLS from sales_agents, users, and customers, while the permission predicate above
-- prevents execution for users without customer.view.
