-- AKAI CRM permission foundation migration.
-- This is a new migration; the applied 0001 foundation migration is not edited.

create type "DataScope" as enum ('GLOBAL', 'TEAM', 'OWN', 'SELF');

create table "users" (
  "id" uuid primary key references auth.users(id) on delete cascade,
  "email" text not null unique,
  "full_name" text not null,
  "phone" text,
  "role_id" text not null references "roles"("id") on delete restrict,
  "manager_id" uuid references "users"("id") on delete set null,
  "is_active" boolean not null default true,
  "preferred_locale" text not null default 'en' check ("preferred_locale" in ('en', 'ur')),
  "permission_version" integer not null default 1,
  "last_login_at" timestamptz(6),
  "created_at" timestamptz(6) not null default now(),
  "updated_at" timestamptz(6) not null default now()
);
create index "users_role_id_is_active_idx" on "users" ("role_id", "is_active");
create index "users_manager_id_is_active_idx" on "users" ("manager_id", "is_active");

alter table "roles"
  add column "data_scope" "DataScope" not null default 'GLOBAL',
  add column "portal_access" "Portal" not null default 'ADMIN',
  add column "is_system_role" boolean not null default false,
  add column "created_by_user_id" uuid,
  add constraint "roles_created_by_user_id_fkey" foreign key ("created_by_user_id") references "users"("id") on delete set null;
create index "roles_is_active_portal_access_idx" on "roles" ("is_active", "portal_access");
create index "roles_data_scope_idx" on "roles" ("data_scope");

alter table "permissions"
  rename column "code" to "key";
alter table "permissions"
  add column "module" text not null default 'SYSTEM',
  add column "label_en" text not null default '',
  add column "label_ur" text not null default '',
  add column "is_sensitive" boolean not null default false,
  add column "display_order" integer not null default 0;
create index "permissions_module_display_order_idx" on "permissions" ("module", "display_order");

create table "permission_dependencies" (
  "permission_id" text not null references "permissions"("id") on delete cascade,
  "requires_permission_id" text not null references "permissions"("id") on delete cascade,
  primary key ("permission_id", "requires_permission_id")
);
create index "permission_dependencies_requires_permission_id_idx" on "permission_dependencies" ("requires_permission_id");

create table "sales_agents" (
  "id" uuid primary key,
  "user_id" uuid not null unique references "users"("id") on delete cascade,
  "agent_code" text not null unique,
  "territory" text not null,
  "monthly_target_pkr" numeric(12,2) not null,
  "joined_at" timestamptz(6) not null
);
create index "sales_agents_territory_idx" on "sales_agents" ("territory");

create table "audit_logs" (
  "id" text primary key,
  "actor_user_id" uuid references "users"("id") on delete set null,
  "entity_type" text not null,
  "entity_id" text not null,
  "action" text not null,
  "before_data" jsonb,
  "after_data" jsonb,
  "created_at" timestamptz(6) not null default now()
);
create index "audit_logs_entity_type_entity_id_created_at_idx" on "audit_logs" ("entity_type", "entity_id", "created_at");
create index "audit_logs_actor_user_id_created_at_idx" on "audit_logs" ("actor_user_id", "created_at");

create table "products" (
  "id" uuid primary key default gen_random_uuid(),
  "sku" text not null unique,
  "name" text not null,
  "is_active" boolean not null default true,
  "created_at" timestamptz(6) not null default now(),
  "updated_at" timestamptz(6) not null default now()
);
create index "products_is_active_name_idx" on "products" ("is_active", "name");

create table "product_costs" (
  "product_id" uuid primary key references "products"("id") on delete cascade,
  "cost_pkr" numeric(12,2) not null
);

create table "customers" (
  "id" uuid primary key default gen_random_uuid(),
  "name" text not null,
  "assigned_agent_id" uuid references "sales_agents"("id") on delete set null,
  "is_active" boolean not null default true,
  "created_at" timestamptz(6) not null default now(),
  "updated_at" timestamptz(6) not null default now()
);
create index "customers_assigned_agent_id_is_active_idx" on "customers" ("assigned_agent_id", "is_active");

create table "customer_users" (
  "user_id" uuid not null references "users"("id") on delete cascade,
  "customer_id" uuid not null references "customers"("id") on delete cascade,
  primary key ("user_id", "customer_id")
);
create index "customer_users_customer_id_idx" on "customer_users" ("customer_id");

create table "orders" (
  "id" uuid primary key default gen_random_uuid(),
  "customer_id" uuid not null references "customers"("id") on delete restrict,
  "total_pkr" numeric(12,2) not null,
  "status" text not null,
  "created_at" timestamptz(6) not null default now()
);
create index "orders_customer_id_created_at_idx" on "orders" ("customer_id", "created_at");

create table "quotes" (
  "id" uuid primary key default gen_random_uuid(),
  "customer_id" uuid not null references "customers"("id") on delete restrict,
  "total_pkr" numeric(12,2) not null,
  "status" text not null,
  "created_at" timestamptz(6) not null default now()
);
create index "quotes_customer_id_created_at_idx" on "quotes" ("customer_id", "created_at");

create table "revenue_snapshots" (
  "id" uuid primary key default gen_random_uuid(),
  "period_start" timestamptz(6) not null,
  "revenue_pkr" numeric(12,2) not null,
  "created_at" timestamptz(6) not null default now()
);
create index "revenue_snapshots_period_start_idx" on "revenue_snapshots" ("period_start");

create table "margin_snapshots" (
  "id" uuid primary key default gen_random_uuid(),
  "period_start" timestamptz(6) not null,
  "margin_pkr" numeric(12,2) not null,
  "created_at" timestamptz(6) not null default now()
);
create index "margin_snapshots_period_start_idx" on "margin_snapshots" ("period_start");

create table "leads" (
  "id" uuid primary key default gen_random_uuid(),
  "assigned_agent_id" uuid references "sales_agents"("id") on delete set null,
  "name" text not null,
  "created_at" timestamptz(6) not null default now()
);
create index "leads_assigned_agent_id_created_at_idx" on "leads" ("assigned_agent_id", "created_at");

create table "activities" (
  "id" uuid primary key default gen_random_uuid(),
  "assigned_agent_id" uuid not null references "sales_agents"("id") on delete restrict,
  "created_at" timestamptz(6) not null default now()
);
create index "activities_assigned_agent_id_created_at_idx" on "activities" ("assigned_agent_id", "created_at");

create table "follow_ups" (
  "id" uuid primary key default gen_random_uuid(),
  "assigned_agent_id" uuid not null references "sales_agents"("id") on delete restrict,
  "due_at" timestamptz(6) not null
);
create index "follow_ups_assigned_agent_id_due_at_idx" on "follow_ups" ("assigned_agent_id", "due_at");

create table "collections" (
  "id" uuid primary key default gen_random_uuid(),
  "assigned_agent_id" uuid references "sales_agents"("id") on delete set null,
  "amount_pkr" numeric(12,2) not null,
  "created_at" timestamptz(6) not null default now()
);
create index "collections_assigned_agent_id_created_at_idx" on "collections" ("assigned_agent_id", "created_at");

create table "claims" (
  "id" uuid primary key default gen_random_uuid(),
  "assigned_agent_id" uuid references "sales_agents"("id") on delete set null,
  "status" text not null,
  "created_at" timestamptz(6) not null default now()
);
create index "claims_assigned_agent_id_created_at_idx" on "claims" ("assigned_agent_id", "created_at");

create table "beat_visits" (
  "id" uuid primary key default gen_random_uuid(),
  "assigned_agent_id" uuid not null references "sales_agents"("id") on delete restrict,
  "visited_at" timestamptz(6) not null
);
create index "beat_visits_assigned_agent_id_visited_at_idx" on "beat_visits" ("assigned_agent_id", "visited_at");

-- Seed-facing lookup helpers. The seed script is idempotent and marked as seed by its file location.
create or replace function public.current_user_id()
returns uuid
language sql
stable
security invoker
set search_path = public
as $$ select auth.uid() $$;

create or replace function public.role_scope(uid uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select r.data_scope::text
  from public.users u
  join public.roles r on r.id = u.role_id
  where u.id = uid and u.is_active and r.is_active
  limit 1
$$;

create or replace function public.accessible_agent_ids(uid uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with current_user_row as (
    select u.id, u.manager_id, r.data_scope
    from public.users u
    join public.roles r on r.id = u.role_id
    where u.id = uid and u.is_active and r.is_active
  )
  select sa.id
  from public.sales_agents sa
  cross join current_user_row c
  where c.data_scope = 'GLOBAL'
     or (c.data_scope = 'OWN' and sa.user_id = c.id)
     or (c.data_scope = 'TEAM' and (sa.user_id = c.id or sa.user_id in (select u.id from public.users u where u.manager_id = c.id and u.is_active)))
$$;

create or replace function public.has_permission(uid uuid, perm text)
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
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions p on p.id = rp.permission_id
    where u.id = uid and u.is_active and r.is_active and p.key = perm
  )
$$;

create or replace function public.user_permission_version(uid uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$ select permission_version from public.users where id = uid and is_active $$;

create or replace function public.permission_keys(uid uuid)
returns table(permission_key text)
language sql
stable
security definer
set search_path = public
as $$
  select p.key
  from public.users u
  join public.roles r on r.id = u.role_id
  join public.role_permissions rp on rp.role_id = r.id
  join public.permissions p on p.id = rp.permission_id
  where u.id = uid and u.is_active and r.is_active
$$;

create or replace function public.permission_prerequisites_satisfied(target_permission text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1
    from public.permission_dependencies d
    join public.permissions required on required.id = d.requires_permission_id
    join public.permissions dependent on dependent.id = d.permission_id
    where dependent.key = target_permission
      and not exists (select 1 from public.permissions p where p.key = required.key)
  )
$$;

-- Any authenticated write through the app must be made under the current user's auth.uid().
-- Seed/migration connections have auth.uid() null and are allowed to install the seed baseline.
create or replace function public.enforce_role_privilege_boundary()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  actor_role_id text;
  target_role_id text;
  target_permission_key text;
begin
  if actor is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  select role_id into actor_role_id from public.users where id = actor and is_active;
  if actor_role_id is null then
    raise exception using errcode = '42501', message = 'You do not have permission to change roles or permissions.';
  end if;
  if tg_table_name = 'roles' and tg_op = 'DELETE' and not public.has_permission(actor, 'role.delete') then
    raise exception using errcode = '42501', message = 'You do not have permission to delete roles.';
  elsif tg_table_name = 'roles' and tg_op <> 'DELETE' and not public.has_permission(actor, 'role.update') then
    raise exception using errcode = '42501', message = 'You do not have permission to update roles.';
  elsif tg_table_name = 'role_permissions' and tg_op = 'INSERT' and not (public.has_permission(actor, 'role.create') or public.has_permission(actor, 'role.update')) then
    raise exception using errcode = '42501', message = 'You do not have permission to assign role permissions.';
  elsif tg_table_name = 'role_permissions' and tg_op <> 'INSERT' and not public.has_permission(actor, 'role.update') then
    raise exception using errcode = '42501', message = 'You do not have permission to update role permissions.';
  end if;

  if tg_table_name = 'roles' then
    if tg_op = 'DELETE' then target_role_id := old.id; else target_role_id := new.id; end if;
    if old.is_system_role then
      raise exception using errcode = '42501', message = 'System roles cannot be edited or deleted.';
    end if;
  elsif tg_table_name = 'role_permissions' then
    if tg_op = 'DELETE' then
      target_role_id := old.role_id;
      select p.key into target_permission_key from public.permissions p where p.id = old.permission_id;
    else
      target_role_id := new.role_id;
      select p.key into target_permission_key from public.permissions p where p.id = new.permission_id;
    end if;
    if exists (select 1 from public.roles r where r.id = target_role_id and r.is_system_role) then
      raise exception using errcode = '42501', message = 'System role permissions cannot be edited.';
    end if;
    if target_permission_key is not null and not public.has_permission(actor, target_permission_key) then
      raise exception using errcode = '42501', message = 'You may only grant permissions you hold yourself.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create trigger roles_privilege_boundary
before update or delete on public.roles
for each row execute function public.enforce_role_privilege_boundary();

create trigger role_permissions_privilege_boundary
before insert or update or delete on public.role_permissions
for each row execute function public.enforce_role_privilege_boundary();

create or replace function public.enforce_role_dependency()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  role_to_assign text := new.role_id;
  permission_to_assign text := new.permission_id;
begin
  if auth.uid() is null or tg_op <> 'INSERT' then return new; end if;
  insert into public.role_permissions (role_id, permission_id)
  select role_to_assign, dependency.requires_permission_id
  from public.permission_dependencies dependency
  where dependency.permission_id = permission_to_assign
  on conflict do nothing;
  return new;
end;
$$;
create trigger role_permissions_dependency
before insert on public.role_permissions
for each row execute function public.enforce_role_dependency();

create or replace function public.ensure_admin_survivor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if tg_table_name = 'roles' and ((tg_op = 'DELETE') or (tg_op = 'UPDATE' and new.is_active = false)) then
    if old.is_system_role and old.name = 'Administrator' and not exists (select 1 from public.roles where name = 'Administrator' and is_active and id <> old.id) then
      raise exception using errcode = '23514', message = 'At least one active Administrator must always exist.';
    end if;
  elsif tg_table_name = 'users' and ((tg_op = 'DELETE') or (tg_op = 'UPDATE' and new.is_active = false)) then
    if old.role_id = (select id from public.roles where name = 'Administrator') and not exists (select 1 from public.users where role_id = old.role_id and is_active and id <> old.id) then
      raise exception using errcode = '23514', message = 'At least one active Administrator must always exist.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
create trigger roles_admin_survivor before update or delete on public.roles for each row execute function public.ensure_admin_survivor();
create trigger users_admin_survivor before update or delete on public.users for each row execute function public.ensure_admin_survivor();

create or replace function public.bump_permission_versions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if tg_table_name = 'role_permissions' then
    update public.users set permission_version = permission_version + 1, updated_at = now()
    where role_id = case when tg_op = 'DELETE' then old.role_id else new.role_id end;
  elsif tg_table_name = 'users' and (old.role_id is distinct from new.role_id or old.is_active is distinct from new.is_active) then
    new.permission_version := old.permission_version + 1;
  elsif tg_table_name = 'roles' and (old.is_active is distinct from new.is_active) then
    update public.users set permission_version = permission_version + 1, updated_at = now() where role_id = old.id;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
create trigger role_permissions_bump_version after insert or update or delete on public.role_permissions for each row execute function public.bump_permission_versions();
create trigger roles_bump_version before update on public.roles for each row execute function public.bump_permission_versions();
create trigger users_bump_version before update on public.users for each row execute function public.bump_permission_versions();

create or replace function public.audit_role_permission_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_logs (id, actor_user_id, entity_type, entity_id, action, before_data, after_data)
  values (
    gen_random_uuid()::text,
    auth.uid(),
    tg_table_name,
    case when tg_table_name = 'role_permissions'
         then case when tg_op = 'DELETE' then old.role_id else new.role_id end
         else case when tg_op = 'DELETE' then old.id else new.id end end,
    tg_op,
    null,
    null
  );
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
create trigger audit_roles after update or delete on public.roles for each row execute function public.audit_role_permission_change();
create trigger audit_role_permissions after insert or update or delete on public.role_permissions for each row execute function public.audit_role_permission_change();
create trigger audit_users after update on public.users for each row when (old.role_id is distinct from new.role_id or old.is_active is distinct from new.is_active) execute function public.audit_role_permission_change();

-- RLS is the security boundary. Sensitive cost and margin data are isolated in tables
-- protected by their own permission, so unauthorized API responses cannot contain them.
alter table public.users enable row level security;
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.permission_dependencies enable row level security;
alter table public.role_permissions enable row level security;
alter table public.sales_agents enable row level security;
alter table public.audit_logs enable row level security;
alter table public.products enable row level security;
alter table public.product_costs enable row level security;
alter table public.customers enable row level security;
alter table public.customer_users enable row level security;
alter table public.orders enable row level security;
alter table public.quotes enable row level security;
alter table public.revenue_snapshots enable row level security;
alter table public.margin_snapshots enable row level security;
alter table public.leads enable row level security;
alter table public.activities enable row level security;
alter table public.follow_ups enable row level security;
alter table public.collections enable row level security;
alter table public.claims enable row level security;
alter table public.beat_visits enable row level security;

create policy users_select on public.users for select to authenticated using (id = auth.uid() or public.has_permission(auth.uid(), 'user.view'));
create policy roles_select on public.roles for select to authenticated using (id = (select role_id from public.users where id = auth.uid()) or public.has_permission(auth.uid(), 'role.view'));
create policy permissions_select on public.permissions for select to authenticated using (public.has_permission(auth.uid(), 'role.view'));
create policy permission_dependencies_select on public.permission_dependencies for select to authenticated using (public.has_permission(auth.uid(), 'role.view'));
create policy role_permissions_select on public.role_permissions for select to authenticated using (public.has_permission(auth.uid(), 'role.view'));
create policy sales_agents_select on public.sales_agents for select to authenticated using (public.has_permission(auth.uid(), 'customer.view') or public.has_permission(auth.uid(), 'lead.view'));
create policy audit_logs_select on public.audit_logs for select to authenticated using (public.has_permission(auth.uid(), 'auditlog.view'));
create policy products_select on public.products for select to authenticated using (public.has_permission(auth.uid(), 'product.view'));
create policy product_costs_select on public.product_costs for select to authenticated using (public.has_permission(auth.uid(), 'product.view_cost'));
create policy customers_select on public.customers for select to authenticated using (
  public.has_permission(auth.uid(), 'customer.view') and (
    public.role_scope(auth.uid()) = 'GLOBAL' or "assigned_agent_id" in (select public.accessible_agent_ids(auth.uid())) or exists (select 1 from public.customer_users cu where cu.customer_id = customers.id and cu.user_id = auth.uid())
  )
);
create policy customer_users_select on public.customer_users for select to authenticated using (user_id = auth.uid() or public.has_permission(auth.uid(), 'customer.view'));
create policy orders_select on public.orders for select to authenticated using (
  public.has_permission(auth.uid(), 'order.view') and exists (select 1 from public.customers c where c.id = orders.customer_id)
);
create policy quotes_select on public.quotes for select to authenticated using (
  public.has_permission(auth.uid(), 'quote.view') and exists (select 1 from public.customers c where c.id = quotes.customer_id)
);
create policy revenue_snapshots_select on public.revenue_snapshots for select to authenticated using (public.has_permission(auth.uid(), 'financials.view_revenue'));
create policy margin_snapshots_select on public.margin_snapshots for select to authenticated using (public.has_permission(auth.uid(), 'financials.view_margin'));
create policy leads_select on public.leads for select to authenticated using (public.has_permission(auth.uid(), 'lead.view') and (assigned_agent_id is null or assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))));
create policy activities_select on public.activities for select to authenticated using (public.has_permission(auth.uid(), 'activity.view') and assigned_agent_id in (select public.accessible_agent_ids(auth.uid())));
create policy follow_ups_select on public.follow_ups for select to authenticated using (public.has_permission(auth.uid(), 'followup.view') and assigned_agent_id in (select public.accessible_agent_ids(auth.uid())));
create policy collections_select on public.collections for select to authenticated using (public.has_permission(auth.uid(), 'collection.view') and (assigned_agent_id is null or assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))));
create policy claims_select on public.claims for select to authenticated using (public.has_permission(auth.uid(), 'claim.view') and (assigned_agent_id is null or assigned_agent_id in (select public.accessible_agent_ids(auth.uid()))));
create policy beat_visits_select on public.beat_visits for select to authenticated using (public.has_permission(auth.uid(), 'beat.view') and assigned_agent_id in (select public.accessible_agent_ids(auth.uid())));

create policy roles_insert on public.roles for insert to authenticated
  with check (public.has_permission(auth.uid(), 'role.create'));
create policy roles_update on public.roles for update to authenticated
  using (public.has_permission(auth.uid(), 'role.update'))
  with check (public.has_permission(auth.uid(), 'role.update'));
create policy roles_delete on public.roles for delete to authenticated
  using (public.has_permission(auth.uid(), 'role.delete'));

create policy role_permissions_insert on public.role_permissions for insert to authenticated
  with check (public.has_permission(auth.uid(), 'role.create') or public.has_permission(auth.uid(), 'role.update'));
create policy role_permissions_update on public.role_permissions for update to authenticated
  using (public.has_permission(auth.uid(), 'role.update'))
  with check (public.has_permission(auth.uid(), 'role.update'));
create policy role_permissions_delete on public.role_permissions for delete to authenticated
  using (public.has_permission(auth.uid(), 'role.update'));

create policy users_update on public.users for update to authenticated
  using (public.has_permission(auth.uid(), 'user.update'))
  with check (public.has_permission(auth.uid(), 'user.update'));
create policy users_insert on public.users for insert to authenticated
  with check (public.has_permission(auth.uid(), 'user.create'));
create policy users_delete on public.users for delete to authenticated
  using (public.has_permission(auth.uid(), 'user.deactivate'));

create or replace function public.prevent_self_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  if auth.uid() = old.id and old.role_id is distinct from new.role_id then
    raise exception using errcode = '42501', message = 'You may not edit your own role assignment.';
  end if;
  if old.role_id is distinct from new.role_id and not public.has_permission(auth.uid(), 'user.update') then
    raise exception using errcode = '42501', message = 'You do not have permission to change a user role.';
  end if;
  return new;
end;
$$;
create trigger users_self_role_boundary before update on public.users for each row execute function public.prevent_self_role_change();

-- Keep direct role-builder navigation hidden from users without role.create at the UI layer,
-- while the server route guard and the RLS policies remain authoritative.

create or replace function public.revoke_dependent_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.role_permissions rp
  using public.permission_dependencies dependency
  where rp.role_id = old.role_id
    and dependency.permission_id = rp.permission_id
    and dependency.requires_permission_id = old.permission_id;
  return old;
end;
$$;
create trigger role_permissions_revoke_dependents
after delete on public.role_permissions
for each row execute function public.revoke_dependent_permissions();

-- Trigger-safe overrides: use local variables in SQL expressions instead of bare NEW/OLD
-- record references, which can otherwise be parsed as column names.
create or replace function public.enforce_role_privilege_boundary()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
  target_role_id text;
  target_permission_id text;
  target_permission_key text;
begin
  if actor is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if tg_op = 'DELETE' then
    if tg_table_name = 'roles' then target_role_id := old.id; else target_role_id := old.role_id; end if;
    if tg_table_name = 'role_permissions' then target_permission_id := old.permission_id; end if;
  else
    if tg_table_name = 'roles' then target_role_id := new.id; else target_role_id := new.role_id; end if;
    if tg_table_name = 'role_permissions' then target_permission_id := new.permission_id; end if;
  end if;
  if tg_table_name = 'roles' and tg_op = 'DELETE' and not public.has_permission(actor, 'role.delete') then
    raise exception using errcode = '42501', message = 'You do not have permission to delete roles.';
  elsif tg_table_name = 'roles' and tg_op <> 'DELETE' and not public.has_permission(actor, 'role.update') then
    raise exception using errcode = '42501', message = 'You do not have permission to update roles.';
  elsif tg_table_name = 'role_permissions' and tg_op = 'INSERT' and not (public.has_permission(actor, 'role.create') or public.has_permission(actor, 'role.update')) then
    raise exception using errcode = '42501', message = 'You do not have permission to assign role permissions.';
  elsif tg_table_name = 'role_permissions' and tg_op <> 'INSERT' and not public.has_permission(actor, 'role.update') then
    raise exception using errcode = '42501', message = 'You do not have permission to update role permissions.';
  end if;
  if tg_table_name = 'roles' and old.is_system_role then
    raise exception using errcode = '42501', message = 'System roles cannot be edited or deleted.';
  elsif tg_table_name = 'role_permissions' then
    if exists (select 1 from public.roles r where r.id = target_role_id and r.is_system_role) then
      raise exception using errcode = '42501', message = 'System role permissions cannot be edited.';
    end if;
    select p.key into target_permission_key from public.permissions p where p.id = target_permission_id;
    if target_permission_key is not null and tg_op <> 'DELETE' and not public.has_permission(actor, target_permission_key) then
      raise exception using errcode = '42501', message = 'You may only grant permissions you hold yourself.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create or replace function public.enforce_role_dependency()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  role_to_assign text := new.role_id;
  permission_to_assign text := new.permission_id;
begin
  if auth.uid() is null or tg_op <> 'INSERT' then return new; end if;
  insert into public.role_permissions (role_id, permission_id)
  select role_to_assign, dependency.requires_permission_id
  from public.permission_dependencies dependency
  where dependency.permission_id = permission_to_assign
  on conflict do nothing;
  return new;
end;
$$;

create or replace function public.ensure_admin_survivor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role_id text;
  admin_role_id text;
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  select id into admin_role_id from public.roles where name = 'Administrator' limit 1;
  if tg_table_name = 'roles' then
    target_role_id := case when tg_op = 'DELETE' then old.id else new.id end;
    if (tg_op = 'DELETE' or new.is_active = false) and old.is_system_role and old.name = 'Administrator' and not exists (select 1 from public.roles where id = admin_role_id and is_active and id <> target_role_id) then
      raise exception using errcode = '23514', message = 'At least one active Administrator must always exist.';
    end if;
  elsif tg_table_name = 'users' then
    if (tg_op = 'DELETE' or new.is_active = false) and old.role_id = admin_role_id and not exists (select 1 from public.users where role_id = admin_role_id and is_active and id <> old.id) then
      raise exception using errcode = '23514', message = 'At least one active Administrator must always exist.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create or replace function public.bump_permission_versions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  role_to_bump text;
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if tg_table_name = 'role_permissions' then
    if tg_op = 'DELETE' then role_to_bump := old.role_id; else role_to_bump := new.role_id; end if;
    update public.users set permission_version = permission_version + 1, updated_at = now() where role_id = role_to_bump;
  elsif tg_table_name = 'users' and (old.role_id is distinct from new.role_id or old.is_active is distinct from new.is_active) then
    new.permission_version := old.permission_version + 1;
  elsif tg_table_name = 'roles' and (old.is_active is distinct from new.is_active) then
    update public.users set permission_version = permission_version + 1, updated_at = now() where role_id = old.id;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create or replace function public.audit_role_permission_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  audit_entity_id text;
begin
  if tg_table_name = 'role_permissions' then
    if tg_op = 'DELETE' then audit_entity_id := old.role_id; else audit_entity_id := new.role_id; end if;
  else
    if tg_op = 'DELETE' then audit_entity_id := old.id; else audit_entity_id := new.id; end if;
  end if;
  insert into public.audit_logs (id, actor_user_id, entity_type, entity_id, action, before_data, after_data)
  values (gen_random_uuid()::text, auth.uid(), tg_table_name, audit_entity_id, tg_op, null, null);
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create or replace function public.revoke_dependent_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  role_to_revoke text := old.role_id;
  permission_to_revoke text := old.permission_id;
begin
  delete from public.role_permissions rp
  using public.permission_dependencies dependency
  where rp.role_id = role_to_revoke
    and dependency.permission_id = rp.permission_id
    and dependency.requires_permission_id = permission_to_revoke;
  return old;
end;
$$;
